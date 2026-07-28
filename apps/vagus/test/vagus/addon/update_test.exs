defmodule Vagus.Addon.UpdateTest do
  @moduledoc """
  P2-A P3: `Vagus.Addon.Update` — the add-on counterpart of
  `Vagus.Core.Lifecycle.update/2`.

  The properties worth protecting are the *ordering* ones, because they are
  what makes a failed update survivable: nothing is stopped before the new
  image is on disk, and a failed start puts the old version back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Addon.{Config, Manager, State, Store, Update}

  # A backend that records every call in the CALLER's process dictionary and
  # fails whichever calls the test asked it to. Caller-process state is sound
  # here (and keeps this file from needing a global fake) because `Update`,
  # `Manager` and this backend all run in the test process — none of them
  # spawn.
  defmodule ScriptedBackend do
    @behaviour Vagus.Addon.Backend

    def script(failures) when is_list(failures) do
      Process.put(:backend_failures, failures)
      Process.put(:backend_calls, [])
      :ok
    end

    def calls, do: Enum.reverse(Process.get(:backend_calls, []))

    # Each scripted failure is consumed when it fires, so `[:start]` fails the
    # FIRST start only. That distinction matters: the rollback issues a second
    # start, and a backend that failed every start would make every rollback
    # test a `:rollback_failed` test. `[:start, :start]` fails both.
    defp record(call) do
      Process.put(:backend_calls, [call | Process.get(:backend_calls, [])])
      failures = Process.get(:backend_failures, [])

      if call in failures do
        Process.put(:backend_failures, List.delete(failures, call))
        {:error, {:scripted_failure, call}}
      else
        :ok
      end
    end

    @impl true
    def pull(_spec), do: record(:pull)

    @impl true
    def create(spec) do
      case record(:create) do
        :ok -> {:ok, "id-#{spec.name}"}
        error -> error
      end
    end

    @impl true
    def start(_id), do: record(:start)

    @impl true
    def stop(_id, _opts \\ []), do: record(:stop)

    @impl true
    def remove(_id, _opts \\ []), do: record(:remove)

    @impl true
    def state(_id), do: {:ok, :running}

    @impl true
    def remove_image(image, _opts \\ []) do
      Process.put(:removed_images, [image | Process.get(:removed_images, [])])
      record(:remove_image)
    end

    def removed_images, do: Enum.reverse(Process.get(:removed_images, []))
  end

  defmodule FailingBackups do
    def create_partial(_name, _slugs, _opts), do: {:error, :disk_full}
  end

  defmodule RecordingBackups do
    def create_partial(name, slugs, _opts) do
      send(self(), {:backup_taken, name, slugs})
      {:ok, "backup_slug"}
    end
  end

  @slug "core_updatable"

  defp config(version, extra \\ %{}) do
    {:ok, config} =
      Config.parse(
        Map.merge(
          %{
            "name" => "Updatable",
            "version" => version,
            "slug" => @slug,
            "description" => "d",
            "arch" => ["amd64"],
            "image" => "example/{arch}-addon-updatable",
            "options" => %{"greeting" => "hi"},
            "schema" => %{"greeting" => "str"}
          },
          extra
        )
      )

    config
  end

  setup context do
    data_root = Path.join(System.tmp_dir!(), "vagus-update-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data_root) end)

    # `Manager` resolves `Vagus.Addon.State` by name, so these have to be the
    # real, globally-named processes — an injected server would desync from
    # the one `Manager.start/2` writes to. Same approach as
    # `addon_lifecycle_router_test.exs`; hence `async: false` and explicit
    # cleanup.
    :ok = ScriptedBackend.script(context[:fail] || [])

    installed = config(context[:installed_version] || "1.0.0")
    :ok = State.put(installed, context[:installed_state] || :started)
    on_exit(fn -> State.delete(@slug) end)

    unless context[:detached] do
      seed_store(config(context[:store_version] || "2.0.0"))
    end

    opts = [backend: ScriptedBackend, data_root: data_root]

    %{opts: opts, installed: installed}
  end

  defp seed_store(config) do
    # The catalog keys by store slug; the entry's own config carries the bare
    # slug — the shape `Store.build_catalog/3` produces.
    entry = %{config: %{config | slug: "updatable"}, repository: "core", assets: %{}}
    catalog = Map.put(Store.catalog(), @slug, entry)
    :ok = GenServer.call(Store, {:put_catalog, catalog})

    on_exit(fn ->
      :ok = GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), @slug)})
    end)
  end

  defp installed_entry, do: State.get(@slug) |> elem(1)

  describe "the happy path" do
    test "a running add-on is stopped, committed and started again", ctx do
      assert {:ok, %{slug: @slug, from: "1.0.0", to: "2.0.0"}} = Update.update(@slug, ctx.opts)

      entry = installed_entry()
      assert entry.config.version == "2.0.0"
      assert entry.state == :started

      # Pull happens BEFORE the stop — the ordering that keeps a failed pull
      # from taking a working add-on offline.
      calls = ScriptedBackend.calls()
      assert Enum.find_index(calls, &(&1 == :pull)) < Enum.find_index(calls, &(&1 == :stop))
      assert :create in calls
      assert :start in calls
    end

    @tag installed_state: :stopped
    test "a stopped add-on is committed but NOT started", ctx do
      assert {:ok, %{to: "2.0.0"}} = Update.update(@slug, ctx.opts)

      entry = installed_entry()
      assert entry.config.version == "2.0.0"
      assert entry.state == :stopped

      calls = ScriptedBackend.calls()
      assert :pull in calls
      refute :start in calls
      refute :stop in calls
    end

    test "user options are preserved across the update", ctx do
      :ok = State.put_options(@slug, %{"greeting" => "custom"})

      assert {:ok, _} = Update.update(@slug, ctx.opts)
      assert installed_entry().user_options == %{"greeting" => "custom"}
    end

    test "the ingress token, port and panel survive", ctx do
      before = installed_entry()
      :ok = State.put_setting(@slug, :ingress_port, 8099)
      :ok = State.put_setting(@slug, :ingress_panel, true)

      assert {:ok, _} = Update.update(@slug, ctx.opts)

      entry = installed_entry()
      assert entry.ingress_port == 8099
      assert entry.ingress_panel == true
      # Regenerating this would silently break every existing ingress URL.
      assert entry.ingress_token == before.ingress_token
    end
  end

  describe "refusals that touch nothing" do
    @tag store_version: "1.0.0"
    test "equal versions", ctx do
      assert {:error, :no_update_available} = Update.update(@slug, ctx.opts)
      assert ScriptedBackend.calls() == []
    end

    @tag detached: true
    test "no store entry (detached)", ctx do
      assert {:error, :not_in_store} = Update.update(@slug, ctx.opts)
      assert ScriptedBackend.calls() == []
    end

    test "not installed", ctx do
      assert {:error, :not_installed} = Update.update("core_ghost", ctx.opts)
      assert ScriptedBackend.calls() == []
    end

    test "options that the new schema rejects", ctx do
      :ok = State.put_options(@slug, %{"greeting" => 42})

      assert {:error, {:invalid_options, _reason}} = Update.update(@slug, ctx.opts)

      # The whole point of validating before mutating.
      assert ScriptedBackend.calls() == []
      assert installed_entry().config.version == "1.0.0"
    end
  end

  describe "failure paths" do
    @tag fail: [:pull]
    test "a failed pull leaves the install completely untouched", ctx do
      assert {:error, {:pull, _}} = Update.update(@slug, ctx.opts)

      entry = installed_entry()
      assert entry.config.version == "1.0.0"
      assert entry.state == :started
      refute :stop in ScriptedBackend.calls()
    end

    @tag fail: [:start]
    test "a failed start rolls back to the old version", ctx do
      log = capture_log(fn -> send(self(), {:result, Update.update(@slug, ctx.opts)}) end)
      assert_received {:result, result}

      assert {:error, {:rolled_back, _cause}} = result
      assert log =~ "rolled back to 1.0.0"

      # Rollback means the *persisted* version goes back too, otherwise the
      # store would advertise an update that already "happened".
      assert installed_entry().config.version == "1.0.0"
    end

    @tag fail: [:start, :start]
    test "a rollback that itself fails is reported as such", ctx do
      # Both the new start and the rollback's start fail. The distinction
      # matters to whoever reads the error: `:rolled_back` means the add-on is
      # running its old version, `:rollback_failed` means it is stopped and
      # needs a human.
      log = capture_log(fn -> send(self(), {:result, Update.update(@slug, ctx.opts)}) end)
      assert_received {:result, result}

      assert {:error, {:rollback_failed, _reason}} = result
      assert log =~ "AND the rollback"
    end

    @tag fail: [:stop]
    test "a backend stop failure is tolerated, matching Manager.stop/2", ctx do
      # Not the behaviour I first assumed: `Manager.stop/2` deliberately
      # swallows backend errors ("an already-stopped/absent container is
      # logged and tolerated"), so only an unknown slug surfaces as an error.
      # The update therefore proceeds — asserting a `{:stop, _}` error here
      # would be asserting a path that cannot happen.
      assert {:ok, %{to: "2.0.0"}} = Update.update(@slug, ctx.opts)
      assert installed_entry().config.version == "2.0.0"
    end
  end

  describe "backup: true" do
    test "takes the backup before pulling", ctx do
      Application.put_env(:vagus, :backups_module, RecordingBackups)
      on_exit(fn -> Application.delete_env(:vagus, :backups_module) end)

      assert {:ok, _} = Update.update(@slug, Keyword.put(ctx.opts, :backup, true))

      # Named for the version being replaced, so the archive says what it is.
      assert_received {:backup_taken, "addon_core_updatable_1.0.0", [@slug]}
    end

    test "a failed backup aborts before anything is mutated", ctx do
      Application.put_env(:vagus, :backups_module, FailingBackups)
      on_exit(fn -> Application.delete_env(:vagus, :backups_module) end)

      assert {:error, {:backup_failed, :disk_full}} =
               Update.update(@slug, Keyword.put(ctx.opts, :backup, true))

      assert ScriptedBackend.calls() == []
      assert installed_entry().config.version == "1.0.0"
    end

    test "no backup is taken unless asked", ctx do
      Application.put_env(:vagus, :backups_module, RecordingBackups)
      on_exit(fn -> Application.delete_env(:vagus, :backups_module) end)

      assert {:ok, _} = Update.update(@slug, ctx.opts)
      refute_received {:backup_taken, _, _}
    end
  end

  describe "reclaiming the superseded image" do
    test "the old image is removed once the new version is running", ctx do
      assert {:ok, _} = Update.update(@slug, ctx.opts)

      # Only the OLD ref — removing the new one would delete what is running.
      assert ["example/amd64-addon-updatable:1.0.0"] = ScriptedBackend.removed_images()
    end

    @tag installed_state: :stopped
    test "also reclaimed when the add-on was not running", ctx do
      assert {:ok, _} = Update.update(@slug, ctx.opts)
      assert ["example/amd64-addon-updatable:1.0.0"] = ScriptedBackend.removed_images()
    end

    @tag fail: [:start]
    test "nothing is reclaimed when the update rolled back", ctx do
      # The old image is what the add-on was just restored onto — deleting it
      # would turn a survivable failure into a broken add-on.
      capture_log(fn -> Update.update(@slug, ctx.opts) end)
      assert ScriptedBackend.removed_images() == []
    end

    @tag fail: [:remove_image]
    test "a failed reclaim does not fail the update", ctx do
      # Expected whenever another container still references the image; the
      # update has already succeeded by this point.
      log = capture_log(fn -> send(self(), {:result, Update.update(@slug, ctx.opts)}) end)
      assert_received {:result, {:ok, _}}
      assert log =~ "kept example/amd64-addon-updatable:1.0.0"
    end

    test "a native add-on has no image to reclaim", ctx do
      # `Manager.image_ref/2` returns nil for `backend: :native`, which is the
      # case the nil-guard exists for. (A *tag* that doesn't change is not
      # reachable: the ref always ends in `:#{version}`, so a version bump
      # always moves it.)
      native = %{ctx.installed | backend: :native}
      :ok = State.put(native, :started)

      catalog_entry = %{
        config: %{native | version: "2.0.0", slug: "updatable"},
        repository: "core",
        assets: %{}
      }

      :ok = GenServer.call(Store, {:put_catalog, Map.put(Store.catalog(), @slug, catalog_entry)})

      assert {:ok, _} = Update.update(@slug, ctx.opts)
      assert ScriptedBackend.removed_images() == []
    end
  end

  describe "serialization" do
    test "Manager's holding-lock entry points really do skip the lock" do
      # This is the property the whole design rests on. `Update` takes the
      # per-slug lock ONCE and then calls `Manager.stop_holding_lock/2` /
      # `start_holding_lock/2`. If those ever went back to acquiring it
      # themselves, the nested release would drop `Update`'s lock mid-swap —
      # `:global` locks are not counted, so a nested acquire is a no-op and
      # the nested release deletes the resource outright.
      #
      # NOT a simulation of the race: the exposed window is a single
      # `State.put` and `:global`'s blocking acquire is a retry-with-sleep
      # loop, so a contender essentially never lands inside it. Driving the
      # update and hoping to observe interleaving produces a test that passes
      # against the broken code — verified. This pins the invariant directly
      # instead.
      parent = self()

      holder =
        spawn(fn ->
          :global.trans(
            {{:addon_lifecycle, @slug}, self()},
            fn ->
              send(parent, :held)
              receive do: (:release -> :ok)
            end,
            [node()]
          )
        end)

      on_exit(fn -> send(holder, :release) end)
      assert_receive :held, 2_000

      # A different requester holds the lock. The unlocked entry point must
      # still proceed; the locking one must not.
      unlocked = Task.async(fn -> Manager.stop_holding_lock(@slug, backend: ScriptedBackend) end)
      assert :ok = Task.await(unlocked, 2_000)

      locked = Task.async(fn -> Manager.stop(@slug, backend: ScriptedBackend) end)
      assert Task.yield(locked, 500) == nil, "Manager.stop/2 should have blocked on the held lock"
      Task.shutdown(locked, :brutal_kill)
    end

    test "a concurrent update on the same slug is refused, not queued", ctx do
      # The lock is per-slug and non-blocking, matching Core: a second caller
      # gets :busy immediately rather than pinning a Bandit worker for the
      # length of a multi-minute update.
      parent = self()

      holder =
        spawn_link(fn ->
          :global.trans(
            {{:addon_lifecycle, @slug}, self()},
            fn ->
              send(parent, :locked)

              receive do
                :release -> :ok
              end
            end,
            [node()]
          )
        end)

      # Released via on_exit, not inline: if the assertion below fails — the
      # exact case this test guards — an inline release never runs and the
      # holder keeps `{:addon_lifecycle, @slug}` for the rest of the file,
      # turning one failure into a cascade of spurious `:busy` failures.
      on_exit(fn -> send(holder, :release) end)

      assert_receive :locked, 2_000
      assert {:error, :busy} = Update.update(@slug, ctx.opts)
    end
  end
end
