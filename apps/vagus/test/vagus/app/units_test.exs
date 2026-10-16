defmodule Vagus.App.UnitsTest do
  # `async: false`: installed apps are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Vagus.AppFixtures, only: [app_config: 2, install_app: 1, listening_api_port: 0]

  alias Vagus.App.{Gates, Units}
  alias Vagus.Core.EventPusher

  @arities %{
    import: 0,
    slugs: 0,
    list: 0,
    ensure: 1,
    in_flight?: 0,
    install_default: 1,
    native?: 1,
    boot_start: 2,
    running: 0,
    inspect: 1,
    halt: 1,
    core_start: 1,
    core_stop: 1,
    report: 2,
    push_complete: 0
  }

  test "every unit is a function of the arity the orchestrator calls it with" do
    units = Units.all()

    assert Map.keys(units) |> Enum.sort() ==
             Enum.sort([:gates, :stop_containers | Map.keys(@arities)])

    for {key, arity} <- @arities do
      assert is_function(Map.fetch!(units, key), arity), "#{key}/#{arity}"
    end

    assert Map.keys(units.gates) |> Enum.sort() == [:api, :engine, :network, :primary, :tree]
    assert Enum.all?(Map.values(units.gates), &is_function(&1, 0))
  end

  describe "stop_containers" do
    test "is no unit under Docker, whose halts stop each container as before" do
      assert Units.all().stop_containers == nil
    end

    test "is a unit under podman" do
      prev = Application.fetch_env(:vagus, :engine)
      Application.put_env(:vagus, :engine, Vagus.Runtime.Engine.Podman)

      on_exit(fn ->
        case prev do
          {:ok, engine} -> Application.put_env(:vagus, :engine, engine)
          :error -> Application.delete_env(:vagus, :engine)
        end
      end)

      assert is_function(Units.all().stop_containers, 2)
    end

    test "stops the group's containers in one engine call, its grace fitting the budget" do
      fake = Vagus.Runtime.Engine.Fake.start()
      opts = [engine: Vagus.Runtime.Engine.Fake, fake: fake]
      Vagus.Runtime.Engine.Fake.put_container(fake, "addon_a")
      Vagus.Runtime.Engine.Fake.put_container(fake, "addon_b")

      assert {:ok, ["addon_a", "addon_b"], []} = Units.stop_containers(["a", "b"], 33_000, opts)
      assert Vagus.Runtime.Engine.Fake.calls(fake) == [{:stop_all, [["addon_a", "addon_b"], 18]}]
      assert [{:stop_all, call_opts}] = Vagus.Runtime.Engine.Fake.call_opts(fake)
      assert call_opts[:timeout_ms] == 33_000
    end

    # podman gives a stop its grace plus its kill margin, whatever the
    # deadline: the grace is what is left of the budget after that margin.
    test "the grace plus podman's margin never outlasts the budget" do
      for budget <- [0, 1_000, 14_999, 15_000, 16_000, 33_000, 45_000, 60_000, 120_000] do
        grace = Units.grace_s(budget)
        {_args, floor} = Vagus.Runtime.Engine.Podman.grace(timeout_s: grace)
        assert grace >= 0
        assert grace <= Vagus.App.Steps.halt_timeout_s()
        assert floor <= max(budget, Vagus.Runtime.Engine.Podman.stop_margin_ms())
      end

      assert Units.grace_s(33_000) == 18
      assert Units.grace_s(45_000) == 30
      assert Units.grace_s(120_000) == 30
      assert Units.grace_s(10_000) == 0
    end
  end

  # The VM's own boot already set it; each test starts as if none had.
  defp fresh_vm(context) do
    prev = :persistent_term.get({Units, :swept}, :unset)
    :persistent_term.erase({Units, :swept})

    on_exit(fn ->
      if prev == :unset,
        do: :persistent_term.erase({Units, :swept}),
        else: :persistent_term.put({Units, :swept}, prev)
    end)

    context
  end

  describe "sweep/0" do
    setup :fresh_vm

    setup do
      base = Path.join(System.tmp_dir!(), "vagus-units-#{System.unique_integer([:positive])}")
      prev = Application.fetch_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :addon_data_root, Path.join(base, "data"))
      prev_dir = Vagus.Backups.dir()
      Vagus.Backups.set_dir(Path.join([base, "data", "backup"]))

      on_exit(fn ->
        case prev do
          {:ok, root} -> Application.put_env(:vagus, :addon_data_root, root)
          :error -> Application.delete_env(:vagus, :addon_data_root)
        end

        Vagus.Backups.set_dir(prev_dir)
        File.rm_rf(base)
      end)

      %{staging: Path.join([base, "data", ".backup-staging"])}
    end

    test "clears the backup staging in the running store's data root", %{staging: staging} do
      leftover = Path.join(staging, "backup-deadbeef-1")
      File.mkdir_p!(leftover)

      assert Units.sweep() == :ok
      refute File.exists?(leftover)
    end

    test "sweeps only on the VM's first boot, so a later boot leaves live staging alone", %{
      staging: staging
    } do
      assert Units.sweep() == :ok
      live = Path.join(staging, "backup-live-1")
      File.mkdir_p!(live)

      assert Units.sweep() == :ok
      assert File.dir?(live)
    end
  end

  test "the tree gate passes once the application is started" do
    assert Gates.tree() == :ok
  end

  # Nothing here can answer for the internet: under podman the gate is the
  # Host's preparation alone.
  test "under podman the engine gate is the Host's readiness, with no internet wait" do
    fake = Vagus.Test.FakePodman.start([])

    test_pid = self()

    # Answers only once the test is over, so the probe task ends with it.
    still_probing = fn _opts ->
      ref = Process.monitor(test_pid)
      receive do: ({:DOWN, ^ref, :process, _pid, _reason} -> {:error, :gone})
    end

    preparing = Vagus.Test.FakePodman.start_host(fake.bin, await: false, probe: still_probing)
    ready = Vagus.Test.FakePodman.start_host(fake.bin, probe: fn _ -> :ok end)
    podman = [engine: Vagus.Runtime.Engine.Podman]

    assert Gates.engine([host: preparing] ++ podman) == {:error, :unavailable}
    assert Gates.engine([host: ready] ++ podman) == :ok
    refute Enum.any?(Vagus.Test.FakePodman.calls(fake), &("pull" in &1))
  end

  test "the api gate passes while the API's port accepts, and fails once it does not" do
    socket = listening_api_port()
    assert Gates.api() == :ok

    :ok = :gen_tcp.close(socket)
    assert Gates.api() == {:error, :not_accepting}
  end

  test "an installed default app is present, and is not installed again" do
    slug = "units_#{System.unique_integer([:positive])}"
    install_app(app_config(slug, %{}))
    assert Units.install_default(slug) == :present
  end

  test "no default app is installed while a failed import left no apps directory" do
    dir = Application.fetch_env!(:vagus, :app_files_dir)
    absent = Path.join(System.tmp_dir!(), "units_apps_#{System.unique_integer([:positive])}")
    Application.put_env(:vagus, :app_files_dir, absent)
    on_exit(fn -> Application.put_env(:vagus, :app_files_dir, dir) end)

    assert Units.install_default("units_default") == {:error, :not_imported}
    refute File.exists?(absent)
  end

  test "an import that raises is logged, not raised" do
    prev = Application.fetch_env!(:vagus, :legacy_addons_json)
    dir = Application.fetch_env!(:vagus, :app_files_dir)
    blocker = Path.join(System.tmp_dir!(), "units_import_#{System.unique_integer([:positive])}")
    File.write!(blocker, "")
    Application.put_env(:vagus, :app_files_dir, Path.join(blocker, "apps"))

    on_exit(fn ->
      Application.put_env(:vagus, :app_files_dir, dir)
      Application.put_env(:vagus, :legacy_addons_json, prev)
      File.rm(blocker)
    end)

    assert capture_log(fn -> assert Units.import() == :ok end) =~ "Apps not imported"
  end

  test "native? holds only for an allowlisted native app" do
    native = %{config: %{app_config("core_mqtt", %{}) | backend: :native}}
    assert Units.native?(native)
    refute Units.native?(%{config: %{app_config("other", %{}) | backend: :native}})
    refute Units.native?(%{config: app_config("core_mqtt", %{})})
  end

  test "push_complete pushes Core the startup complete event" do
    assert Units.push_complete(self()) == :ok
    assert_received {:"$gen_cast", {:push, data}}

    assert data == %{
             "event" => "supervisor_update",
             "update_key" => "supervisor",
             "data" => %{"startup" => "complete"}
           }

    state = %{
      ready: true,
      connection_pid: self(),
      conn_mod: EventPusher.Connection,
      next_id: 7
    }

    EventPusher.handle_cast({:push, data}, state)
    assert_received {:"$gen_cast", {:request, {:text, json}}}

    assert Jason.decode!(json) == %{
             "id" => 7,
             "type" => "supervisor/event",
             "data" => data
           }
  end

  describe "what the engine says runs" do
    alias Vagus.Runtime.Engine.Fake

    defp engine(containers) do
      fake = Fake.start()
      for {name, state} <- containers, do: Fake.put_container(fake, name, state: state)
      [engine: Fake, fake: fake]
    end

    test "one listing names the apps whose container is live" do
      opts =
        engine([
          {"addon_core_ssh", :running},
          {"addon_local_p", :paused},
          {"addon_local_r", :restarting},
          {"addon_local_x", :exited},
          {"hassio_dns", :running}
        ])

      assert Units.running(opts) == {:ok, MapSet.new(["core_ssh", "local_p", "local_r"])}

      Fake.fail_next(opts[:fake], :list, {:failed, :list, "x"})
      assert {:error, {:failed, :list, "x"}} = Units.running(opts)
    end

    test "one app's container: live (running, paused, restarting), stopped, absent, or no answer" do
      for state <- [:running, :paused, :restarting] do
        assert Units.running?("core_ssh", engine([{"addon_core_ssh", state}]))
      end

      for state <- [:created, :exited] do
        refute Units.running?("core_ssh", engine([{"addon_core_ssh", state}]))
      end

      refute Units.running?("core_ssh", engine([]))

      opts = engine([{"addon_core_ssh", :running}])
      Fake.fail_next(opts[:fake], :inspect, {:failed, :inspect, "x"})
      assert :unknown == Units.running?("core_ssh", opts)
    end
  end
end
