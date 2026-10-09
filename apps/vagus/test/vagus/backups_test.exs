defmodule Vagus.BackupsTest do
  @moduledoc """
  M4-P6-T2: `Vagus.Backups`' on-disk store (scan/index/list/get/delete) and
  the `create_partial`/`restore_partial` orchestration on top of it (§A4).

  Each test starts its own named `Vagus.Backups` instance pointed at a tmp
  dir (never touches the app's supervised singleton) but does read/write the
  real (globally-supervised) `Vagus.Addon.State` — same pattern
  `test/vagus/addon/manager_test.exs` uses. `async: false` because
  `Vagus.Addon.Backend.Fake`'s call recorder is a single global table.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Vagus.AppFixtures

  alias Vagus.Addon.{Backend, Config}
  alias Vagus.Backups

  @backend Backend.Fake

  setup do
    prev_backend = Application.fetch_env(:vagus, :addon_backend)
    Application.put_env(:vagus, :addon_backend, @backend)

    on_exit(fn ->
      case prev_backend do
        {:ok, backend} -> Application.put_env(:vagus, :addon_backend, backend)
        :error -> Application.delete_env(:vagus, :addon_backend)
      end
    end)

    # The data root is nested so the staging root beside it is this test's own.
    base = Path.join(System.tmp_dir!(), "vagus-bk-#{System.unique_integer([:positive])}")
    data_root = Path.join(base, "data")
    backup_dir = Path.join(data_root, "backup")
    server = :"backups_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Backups.start_link(name: server, dir: backup_dir, data_root: data_root)
    on_exit(fn -> File.rm_rf(base) end)
    %{data_root: data_root, backup_dir: backup_dir, server: server}
  end

  defp fixture_config(slug, overrides) do
    base = %{
      "name" => "Test Addon",
      "version" => "1.0",
      "slug" => slug,
      "description" => "d",
      "arch" => ["amd64"],
      "image" => "homeassistant/{arch}-addon-test",
      "host_network" => true
    }

    {:ok, config} = Config.parse(Map.merge(base, overrides))
    config
  end

  # Installs into the real, global app store, and creates the app's data dir
  # under `data_root`.
  defp install(slug, data_root, state \\ :started, user_options \\ %{}, overrides \\ %{}) do
    config = fixture_config(slug, overrides)
    install_app(config, state: state, options: user_options)

    data_dir = Path.join([data_root, "addons", "data", slug])
    File.mkdir_p!(data_dir)
    config
  end

  defp data_dir(data_root, slug), do: Path.join([data_root, "addons", "data", slug])

  describe "scan/index (GenServer)" do
    test "a tar written directly into the dir is picked up on reload", %{
      backup_dir: dir,
      server: server
    } do
      spec = %{
        slug: "abc12345",
        name: "Direct backup",
        addons: [],
        supervisor_version: "2026.07.3"
      }

      {:ok, tar} = Vagus.Backup.create(spec, date: "2026-01-01T00:00:00Z")
      File.write!(Path.join(dir, "abc12345.tar"), tar)

      :ok = Backups.reload(server)

      assert [%{backup: %{"slug" => "abc12345"}}] = Backups.list(server)
      assert {:ok, %{backup: %{"name" => "Direct backup"}}} = Backups.get("abc12345", server)
    end

    test "get/2 on an unknown slug is :error", %{server: server} do
      assert :error = Backups.get("nope", server)
    end

    test "put_file/2 rejects a non-tar payload", %{server: server} do
      assert {:error, _reason} = Backups.put_file("not a tar", server)
      assert Backups.list(server) == []
    end
  end

  describe "create_partial/3" do
    test "an installed hot add-on: tar written + indexed, content lists the add-on", %{
      data_root: dr,
      backup_dir: backup_dir,
      server: server
    } do
      slug = "core_hot"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "state.txt"), "hello")

      assert {:ok, backup_slug} =
               Backups.create_partial(nil, [slug],
                 server: server,
                 data_root: dr,
                 date: "2026-07-21T00:00:00Z"
               )

      assert {:ok, %{backup: b, path: path}} = Backups.get(backup_slug, server)
      assert b["name"] =~ "Partial backup"
      assert [%{"slug" => ^slug, "name" => "Test Addon", "version" => "1.0"}] = b["addons"]
      assert File.exists?(path)
      assert File.ls!(Backups.staging_root(backup_dir)) == []

      {:ok, tar} = File.read(path)
      {:ok, %{addon: addon, data: files}} = Vagus.Backup.extract_addon(tar, slug)
      assert addon["state"] == "started"
      assert Map.new(files)["state.txt"] == "hello"
    end

    test "a not-installed slug aborts before anything is written", %{
      data_root: dr,
      server: server
    } do
      assert {:error, {:not_installed, "ghost"}} =
               Backups.create_partial(nil, ["ghost"], server: server, data_root: dr)

      assert Backups.list(server) == []
    end

    test "a hot add-on runs its hooks outside a pause that spans the tar", %{
      data_root: dr,
      server: server
    } do
      slug = "core_hot_hooks"
      install(slug, dr, :started, %{}, %{"backup_pre" => "dump", "backup_post" => "undump"})
      :ok = @backend.reset_calls()

      assert {:ok, _backup_slug} =
               Backups.create_partial(nil, [slug],
                 server: server,
                 data_root: dr,
                 docker: @backend
               )

      id = "addon_" <> slug

      assert @backend.calls_for(id) ==
               [{:exec, id, "dump"}, {:pause, id}, {:unpause, id}, {:exec, id, "undump"}]
    end

    test "a cold add-on is stopped and started again by its own backup", %{
      data_root: dr,
      server: server
    } do
      slug = "core_cold"
      install(slug, dr, :started, %{}, %{"backup" => "cold"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      :ok = @backend.reset_calls()

      assert {:ok, backup_slug} =
               Backups.create_partial(nil, [slug], server: server, data_root: dr)

      ops = Enum.map(@backend.calls_for("addon_" <> slug), &elem(&1, 0))
      assert [:stop, :remove | started] = ops
      assert :start in started
      refute :pause in ops
      assert {:ok, %{state: :started}} = app_info(slug)

      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      {:ok, %{addon: addon}} = Vagus.Backup.extract_addon_file(path, slug)
      assert addon["state"] == "started"
    end

    test "a stopped cold add-on is snapshotted and left stopped", %{
      data_root: dr,
      server: server
    } do
      slug = "core_stopped"
      install(slug, dr, :stopped, %{}, %{"backup" => "cold"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      :ok = @backend.reset_calls()

      assert {:ok, backup_slug} =
               Backups.create_partial(nil, [slug],
                 server: server,
                 data_root: dr,
                 backend: __MODULE__.ExitedBackend
               )

      refute Enum.any?(@backend.calls(), &match?({op, _} when op in [:create, :start], &1))
      assert {:ok, %{state: :stopped}} = app_info(slug)
      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      {:ok, tar} = File.read(path)
      {:ok, %{addon: addon}} = Vagus.Backup.extract_addon(tar, slug)
      assert addon["state"] == "stopped"
    end

    test "a busy app fails the whole backup by name; the app before it is running again", %{
      data_root: dr,
      backup_dir: backup_dir,
      server: server
    } do
      cold = "core_busy_cold"
      busy = "core_busy_busy"
      install(cold, dr, :started, %{}, %{"backup" => "cold"})
      install(busy, dr, :started)
      stub_app_steps()

      stopping = Task.async(fn -> Vagus.App.stop(busy) end)
      assert_receive {:step, :stop, %{slug: ^busy}, held}, 5_000

      backup =
        Task.async(fn ->
          Backups.create_partial(nil, [cold, busy], server: server, data_root: dr)
        end)

      assert_receive {:step, :stop, %{slug: ^cold}, task}, 5_000
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert_receive {:step, :snapshot, %{slug: ^cold, staging_dir: staging}, task}, 5_000
      send(task, {:outcome, {:ok, Path.join(staging, cold <> ".tar.gz")}})
      assert_receive {:step, :start, %{slug: ^cold}, task}, 5_000
      send(task, {:outcome, {:ok, %{container_id: "c2"}}})

      assert {:error, {:busy, ^busy}} = Task.await(backup)
      assert {:ok, %{state: :started}} = app_info(cold)
      assert Backups.list(server) == []
      assert File.ls!(Backups.staging_root(backup_dir)) == []

      send(held, {:outcome, {:ok, %{was_running: true}}})
      assert :ok = Task.await(stopping)
    end

    # The op's reply to a dead caller is its last act, so it is the one
    # barrier the test can wait on from the app process itself.
    defp notify_reply_to(slug, caller) do
      [{app, _value}] = Registry.lookup(Vagus.App.Directory, {:slug, slug})
      test = self()

      :sys.install(
        app,
        {fn
           :watching, {:out, reply, {^caller, _tag}}, _name ->
             send(test, {:replied, reply})
             :done

           :watching, _event, _name ->
             :watching
         end, :watching}
      )
    end

    test "a backup caller killed mid-tar leaves the cold app started by its own op", %{
      data_root: dr,
      server: server
    } do
      slug = "core_orphaned"
      install(slug, dr, :started, %{}, %{"backup" => "cold"})
      stub_app_steps()

      {caller, ref} =
        spawn_monitor(fn ->
          Backups.create_partial(nil, [slug], server: server, data_root: dr)
        end)

      assert_receive {:step, :stop, %{slug: ^slug}, task}, 5_000
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert_receive {:step, :snapshot, %{slug: ^slug}, task}, 5_000
      notify_reply_to(slug, caller)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

      send(task, {:outcome, {:ok, "/gone/#{slug}.tar.gz"}})
      assert_receive {:step, :start, %{slug: ^slug}, task}, 5_000
      send(task, {:outcome, {:ok, %{container_id: "c2"}}})

      assert_receive {:replied, {:ok, "/gone/core_orphaned.tar.gz"}}, 5_000
      assert {:ok, %{state: :started}} = app_info(slug)
    end

    test "the boot sweep clears staging a crashed VM left behind", %{
      data_root: dr,
      backup_dir: backup_dir
    } do
      leftover = Path.join(Backups.staging_root(backup_dir), "backup-deadbeef-1")
      File.mkdir_p!(leftover)
      File.write!(Path.join(leftover, "core_x.tar.gz"), "partial")

      # A staged restore, the aside of a swap whose data dir is back, and the
      # aside of one halted between its renames, which holds the only copy.
      parent = Path.join([dr, "addons", "data"])
      File.mkdir_p!(Path.join(parent, ".restore-core_a-1"))
      File.mkdir_p!(Path.join(parent, "core_b"))
      File.mkdir_p!(Path.join(parent, ".restore-core_b-2.old"))
      File.mkdir_p!(Path.join(parent, ".restore-core_c-3.old"))
      File.write!(Path.join([parent, ".restore-core_c-3.old", "db"]), "kept")

      log =
        capture_log(fn -> assert :ok = Backups.sweep_stale(dir: backup_dir, data_root: dr) end)

      refute File.exists?(Backups.staging_root(backup_dir))
      assert File.ls!(parent) |> Enum.sort() == ["core_b", "core_c"]
      assert File.read!(Path.join([parent, "core_c", "db"])) == "kept"
      assert log =~ "core_c's data moved back"
    end

    # A file where the data dir goes makes the move back fail.
    test "the boot sweep keeps an aside that cannot move back to a missing data dir", %{
      data_root: dr,
      backup_dir: backup_dir
    } do
      parent = Path.join([dr, "addons", "data"])
      aside = Path.join(parent, ".restore-core_d-4.old")
      File.mkdir_p!(aside)
      File.write!(Path.join(aside, "db"), "only copy")
      File.write!(Path.join(parent, "core_d"), "in the way")

      log =
        capture_log(fn -> assert :ok = Backups.sweep_stale(dir: backup_dir, data_root: dr) end)

      assert File.read!(Path.join(aside, "db")) == "only copy"
      assert log =~ "core_d's data could not move back"
    end

    # Backup callers and app operations outlive a restart of the store.
    test "a restart of the store leaves live backup and restore staging alone", %{
      data_root: dr,
      backup_dir: backup_dir,
      server: server
    } do
      {:ok, %{staging_dir: staging}} = Backups.begin_partial("live", server: server)
      restore = Path.join([dr, "addons", "data", ".restore-core_a-1"])
      File.mkdir_p!(restore)

      :ok = GenServer.stop(server)
      {:ok, _pid} = Backups.start_link(name: server, dir: backup_dir, data_root: dr)

      assert File.dir?(staging)
      assert File.dir?(restore)
    end

    test "each backup stages in its own new root-only dir beside the data root", %{
      data_root: dr,
      backup_dir: backup_dir,
      server: server
    } do
      root = Path.join(Path.dirname(dr), "staging")
      assert Backups.staging_root(backup_dir) == root
      opts = [server: server, date: "2026-07-21T00:00:00Z"]

      assert {:ok, %{staging_dir: a, slug: slug}} = Backups.begin_partial("same", opts)
      assert {:ok, %{staging_dir: b, slug: ^slug}} = Backups.begin_partial("same", opts)
      assert a != b
      assert Path.dirname(a) == root and Path.dirname(b) == root
      assert File.dir?(a) and File.dir?(b)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(root)
      assert Bitwise.band(mode, 0o777) == 0o700

      File.mkdir!(Path.join(root, "backup-#{slug}-7"))

      assert {:error, {:staging, :eexist}} =
               Backups.begin_partial("same", [unique: 7] ++ opts)
    end
  end

  describe "restore_partial/3" do
    test "round-trip: files + user_options restored, add-on restarted (was started)", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore"
      install(slug, dr, :started, %{"greet" => "hi"})
      dd = data_dir(dr, slug)
      File.write!(Path.join(dd, "keep.txt"), "original")

      {:ok, backup_slug} =
        Backups.create_partial(nil, [slug],
          server: server,
          data_root: dr,
          date: "2026-07-21T00:00:00Z"
        )

      # Drift after the backup was taken.
      File.write!(Path.join(dd, "keep.txt"), "mutated")
      File.write!(Path.join(dd, "extra.txt"), "should be gone")
      set_app(slug, options: %{"greet" => "bye"})

      :ok = @backend.reset_calls()

      assert :ok =
               Backups.restore_partial(backup_slug, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert File.read!(Path.join(dd, "keep.txt")) == "original"
      refute File.exists?(Path.join(dd, "extra.txt"))
      assert restore_leftovers(dr) == []
      assert {:ok, %{state: :started, user_options: %{"greet" => "hi"}}} = app_info(slug)

      calls = @backend.calls()
      assert Enum.any?(calls, &match?({:stop, "addon_" <> ^slug}, &1))
      assert Enum.any?(calls, &match?({:start, _}, &1))
    end

    # Intended, not incidental: `protected` is a per-install security setting,
    # not add-on data, so a restore of the add-on's `/data` must not silently
    # re-grant (or revoke) device access the user set independently. Only
    # `POST /addons/{slug}/security` moves it; a restore sets the options alone.
    test "a restore leaves the add-on's protection mode untouched", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_protected"
      install(slug, dr, :stopped, %{"greet" => "hi"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      # Turned off AFTER the backup was taken — the restore must not roll it
      # back to the protected default the tar knows nothing about.
      set_app(slug, protected: false)

      assert :ok =
               Backups.restore_partial(backup_slug, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert {:ok, %{protected: false, user_options: %{"greet" => "hi"}}} = app_info(slug)
    end

    test "a stopped-at-backup-time add-on is not restarted on restore", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_stopped"
      install(slug, dr, :stopped)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      :ok = @backend.reset_calls()

      assert :ok =
               Backups.restore_partial(backup_slug, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      refute Enum.any?(@backend.calls(), &match?({:start, _}, &1))
      assert {:ok, %{state: :stopped}} = app_info(slug)
    end

    test "backed-up options the installed schema rejects are dropped; the data still restores",
         %{data_root: dr, server: server} do
      slug = "core_restore_schema"
      install(slug, dr, :stopped, %{"greet" => "hi"}, %{"schema" => %{"greet" => "str"}})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "backed up")
      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      install(slug, dr, :stopped, %{"greet" => 42}, %{"schema" => %{"greet" => "int"}})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "since")

      log =
        capture_log(fn ->
          assert :ok = Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)
        end)

      assert log =~ "keeping the current options"
      assert File.read!(Path.join(data_dir(dr, slug), "f.txt")) == "backed up"
      assert {:ok, %{user_options: %{"greet" => 42}}} = app_info(slug)
    end

    # Backed up while running, so the restore starts it again.
    defp backed_up_app(slug, dr, server) do
      install(slug, dr, :started, %{"greet" => "hi"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "backed up")
      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "since")
      set_app(slug, options: %{"greet" => "since"})
      stub_app_steps()
      backup_slug
    end

    defp restore_leftovers(dr),
      do:
        dr |> Path.join("addons/data") |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "."))

    test "a running app is stopped, swapped and started by its own op, in that order", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_running"
      backup_slug = backed_up_app(slug, dr, server)

      restore =
        Task.async(fn ->
          Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)
        end)

      assert_receive {:step, :stop, %{slug: ^slug}, task}, 5_000
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert_receive {:step, :swap_data, %{staging_dir: staging}, task}, 5_000
      assert Path.dirname(staging) == Path.dirname(data_dir(dr, slug))
      assert File.read!(Path.join(staging, "f.txt")) == "backed up"
      send(task, {:outcome, {:ok, data_dir(dr, slug)}})
      assert_receive {:step, :set_options, %{options: %{"greet" => "hi"} = raw}, task}, 5_000
      send(task, {:outcome, {:ok, raw}})
      assert_receive {:step, :start, %{user_options: %{"greet" => "hi"}}, task}, 5_000
      send(task, {:outcome, {:ok, %{container_id: "c2"}}})

      # The op drops the aside, last; once it replies, an uninstall may run,
      # so nothing after it may touch the data dir's siblings.
      aside = staging <> ".old"
      File.mkdir_p!(aside)
      assert_receive {:step, :drop_aside, %{staging_dir: ^staging}, task}, 5_000
      send(task, {:outcome, {:ok, :kept}})

      assert :ok = Task.await(restore)
      assert restore_leftovers(dr) == [Path.basename(aside)]
      assert {:ok, %{state: :started, user_options: %{"greet" => "hi"}}} = app_info(slug)
    end

    test "a busy app aborts the restore by name, its data untouched", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_busy"
      backup_slug = backed_up_app(slug, dr, server)
      stopping = Task.async(fn -> Vagus.App.stop(slug) end)
      assert_receive {:step, :stop, %{slug: ^slug}, held}, 5_000

      assert {:error, {:restore, ^slug, :busy}} =
               Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)

      assert File.read!(Path.join(data_dir(dr, slug), "f.txt")) == "since"
      assert restore_leftovers(dr) == []

      send(held, {:outcome, {:ok, %{was_running: true}}})
      assert :ok = Task.await(stopping)
    end

    test "a failed swap fails the restore before the options or a start", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_swap"
      backup_slug = backed_up_app(slug, dr, server)

      restore =
        Task.async(fn ->
          Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)
        end)

      assert_receive {:step, :stop, %{slug: ^slug}, task}, 5_000
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert_receive {:step, :swap_data, _input, task}, 5_000
      send(task, {:outcome, {:error, :exdev}})

      assert {:error, {:restore, ^slug, :exdev}} = Task.await(restore)
      refute_received {:step, :start, _input, _task}
      assert File.read!(Path.join(data_dir(dr, slug), "f.txt")) == "since"
      assert restore_leftovers(dr) == []
      assert {:ok, %{user_options: %{"greet" => "since"}}} = app_info(slug)
    end

    test "restore onto a not-installed slug errors", %{data_root: dr, server: server} do
      slug = "core_src"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      forget_app(slug)

      assert {:error, message} =
               Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)

      assert message =~ "is not installed"
    end

    test "restore of a slug absent from the backup errors", %{data_root: dr, server: server} do
      slug = "core_present"
      ghost = "core_ghost"
      install(slug, dr)
      install(ghost, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      assert {:error, message} =
               Backups.restore_partial(backup_slug, [ghost], server: server, data_root: dr)

      assert message =~ "not in backup"
    end

    test "restoring an unknown backup slug errors", %{data_root: dr, server: server} do
      assert {:error, _reason} =
               Backups.restore_partial("nosuchbk", ["whatever"], server: server, data_root: dr)
    end

    test "pre-flight (W2): a later slug failing means an earlier slug is never touched", %{
      data_root: dr,
      server: server
    } do
      slug = "core_preflight_ok"
      ghost = "core_preflight_missing"
      install(slug, dr)
      install(ghost, dr)
      File.write!(Path.join(data_dir(dr, slug), "keep.txt"), "original")

      {:ok, backup_slug} =
        Backups.create_partial(nil, [slug], server: server, data_root: dr)

      :ok = @backend.reset_calls()

      assert {:error, message} =
               Backups.restore_partial(backup_slug, [slug, ghost],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert message =~ "not in backup"
      # `slug` (which IS valid/installed/in-backup) must not have been
      # stopped/wiped just because `ghost` (checked second) fails pre-flight.
      assert @backend.calls() == []
      assert File.read!(Path.join(data_dir(dr, slug), "keep.txt")) == "original"
    end
  end

  # As an uploaded backup may carry it: `addon_json` verbatim beside staged data.
  defp backup_with_addon_json(slug, addon_json, server),
    do:
      backup_with_inner(
        slug,
        [{~c"./addon.json", addon_json}, {~c"./data/f.txt", "from the backup"}],
        server
      )

  defp backup_with_inner(slug, members, server) do
    inner = Path.join(System.tmp_dir!(), "vagus-inner-#{System.unique_integer([:positive])}")
    :ok = :erl_tar.create(String.to_charlist(inner), members, [:compressed])

    backup_slug = "m#{System.unique_integer([:positive])}" |> String.slice(0, 8)
    backup_json = Jason.encode!(%{"slug" => backup_slug, "name" => "upload", "type" => "partial"})
    outer = Path.join(System.tmp_dir!(), "vagus-outer-#{System.unique_integer([:positive])}")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"./backup.json", backup_json},
        {String.to_charlist("./#{slug}.tar.gz"), File.read!(inner)}
      ])

    {:ok, ^backup_slug} = Backups.put_file(File.read!(outer), server)
    File.rm!(inner)
    File.rm!(outer)
    backup_slug
  end

  describe "restore_partial/3 of a malformed backup" do
    for {label, addon_json} <- [
          {"not an object", "1"},
          {"not JSON", "{"},
          {"a non-object user", ~s({"user":"bad"})},
          {"non-object options", ~s({"user":{"options":[1]}})},
          {"a non-string state", ~s({"state":1})}
        ] do
      test "#{label} fails in pre-flight, nothing staged or touched", %{
        data_root: dr,
        server: server
      } do
        slug = "core_malformed"
        install(slug, dr)
        File.write!(Path.join(data_dir(dr, slug), "f.txt"), "since")
        backup_slug = backup_with_addon_json(slug, unquote(addon_json), server)
        :ok = @backend.reset_calls()

        assert {:error, "Addon core_malformed's backup is malformed"} =
                 Backups.restore_partial(backup_slug, [slug],
                   server: server,
                   data_root: dr,
                   backend: @backend
                 )

        assert @backend.calls() == []
        assert File.read!(Path.join(data_dir(dr, slug), "f.txt")) == "since"
        assert restore_leftovers(dr) == []
      end
    end

    for {label, members} <- [
          {"an inner tar without addon.json", [{~c"./data/f.txt", "from the backup"}]},
          {"a data member escaping the app dir",
           [{~c"./addon.json", "{}"}, {~c"./data/../../escape.txt", "out"}]}
        ] do
      test "#{label} fails in pre-flight, nothing staged or touched", %{
        data_root: dr,
        server: server
      } do
        slug = "core_malformed"
        install(slug, dr)
        File.write!(Path.join(data_dir(dr, slug), "f.txt"), "since")
        backup_slug = backup_with_inner(slug, unquote(Macro.escape(members)), server)
        :ok = @backend.reset_calls()

        assert {:error, "Addon core_malformed's backup is malformed"} =
                 Backups.restore_partial(backup_slug, [slug],
                   server: server,
                   data_root: dr,
                   backend: @backend
                 )

        assert @backend.calls() == []
        assert File.read!(Path.join(data_dir(dr, slug), "f.txt")) == "since"
        assert restore_leftovers(dr) == []
      end
    end

    test "absent user, options and state are accepted", %{
      data_root: dr,
      server: server
    } do
      slug = "core_bare"
      install(slug, dr, :stopped, %{"greet" => "kept"})
      backup_slug = backup_with_addon_json(slug, "{}", server)

      assert :ok = Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)
      assert File.read!(Path.join(data_dir(dr, slug), "f.txt")) == "from the backup"
      assert restore_leftovers(dr) == []
    end
  end

  describe "restore_partial/3 when the restore raises" do
    defmodule RaisingApp do
      @moduledoc false
      def restore(_slug, staging_dir, _options, _start?, _opts) do
        true = File.regular?(Path.join(staging_dir, "f.txt"))
        raise "restore crashed"
      end
    end

    test "the staged data is removed and the raise reaches the caller", %{
      data_root: dr,
      server: server
    } do
      slug = "core_raising"
      install(slug, dr, :stopped)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")
      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      assert_raise RuntimeError, "restore crashed", fn ->
        Backups.restore_partial(backup_slug, [slug],
          server: server,
          data_root: dr,
          app: RaisingApp
        )
      end

      assert restore_leftovers(dr) == []
    end
  end

  # The upstream restore contract, asserted on the tar directly — the schema
  # IS the contract (plan P4-T7). A restoring HAOS coerces
  # `supervisor_version` through AwesomeVersion and compares it
  # (`backups/manager.py`), and validates each `addon.json` against
  # `SCHEMA_APP_BACKUP`, whose `system` is the full add-on config schema
  # plus a REQUIRED `repository` (`apps/validate.py`). These tests pin the
  # exact fields those checks read.
  describe "upstream restore contract (audit C2/C3/C5)" do
    test "backup.json: version-shaped supervisor_version, extra round-trip, MB sizes", %{
      data_root: dr,
      server: server
    } do
      slug = "core_contract"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "hello")

      extra = %{"supervisor.backup_request_date" => "2026-07-30T00:00:00Z"}

      {:ok, backup_slug} =
        Backups.create_partial(nil, [slug], server: server, data_root: dr, extra: extra)

      {:ok, %{backup: b, path: path}} = Backups.get(backup_slug, server)

      # A real version string, not "vagus" (C2) — and the SAME version the
      # API claims, so the tar and the wire tell one story.
      assert b["supervisor_version"] == Vagus.API.StaticData.supervisor_version()
      assert b["supervisor_version"] =~ ~r/^\d{4}\.\d{2}(\.\d+)?$/

      # Core keys automatic-backup identity off extra (C5).
      assert b["extra"] == extra

      # Per-addon size is an MB float (C5) — strictly smaller than the byte
      # count could ever be for a non-empty inner tar.
      assert [%{"size" => size}] = b["addons"]
      assert is_float(size) and size > 0 and size < 1

      # And the tar's own copy agrees with the index.
      {:ok, %{backup: from_disk}} = Vagus.Backup.read_file(path)
      assert from_disk["supervisor_version"] == b["supervisor_version"]
      assert from_disk["extra"] == extra
    end

    test "addon.json's system block satisfies SCHEMA_APP_SYSTEM's requirements", %{
      data_root: dr,
      server: server
    } do
      slug = "core_system"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      {:ok, %{addon: addon}} = Vagus.Backup.extract_addon_file(path, slug)

      system = addon["system"]

      # The base add-on config schema's required keys…
      assert system["name"] == "Test Addon"
      assert system["version"] == "1.0"
      assert system["slug"] == slug
      assert system["description"] == "d"
      # …the shape-stable optionals a restore needs (availability + image)…
      assert system["arch"] == ["amd64"]
      assert system["image"] == "homeassistant/{arch}-addon-test"
      # …and SCHEMA_APP_SYSTEM's own required addition. Not in any store
      # repository here, so the detached fallback.
      assert system["repository"] == "core"

      # SCHEMA_APP_BACKUP's siblings.
      assert addon["user"]["version"] == "1.0"
      assert addon["state"] in ["started", "stopped"]
    end

    test "an old tar claiming supervisor_version \"vagus\" still indexes and lists", %{
      backup_dir: dir,
      server: server
    } do
      # Written by a pre-phase-4 Vagus — tolerated on read; it simply stays
      # HAOS-unrestorable (scratchpad decision, 2026-07-30).
      spec = %{slug: "0ldvagus", name: "Old tar", addons: [], supervisor_version: "vagus"}
      {:ok, tar} = Vagus.Backup.create(spec, date: "2026-01-01T00:00:00Z")
      File.write!(Path.join(dir, "0ldvagus.tar"), tar)

      :ok = Backups.reload(server)

      assert {:ok, %{backup: %{"supervisor_version" => "vagus"}}} =
               Backups.get("0ldvagus", server)
    end
  end

  describe "delete/2" do
    test "removes the tar file + index entry", %{data_root: dr, server: server} do
      slug = "core_del"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      assert File.exists?(path)

      assert :ok = Backups.delete(backup_slug, server)
      refute File.exists?(path)
      assert :error = Backups.get(backup_slug, server)
      assert :error = Backups.delete(backup_slug, server)
    end
  end

  defmodule ExitedBackend do
    @moduledoc false
    # The fake backend, with no container running, as an engine reports a stopped app.
    alias Vagus.Addon.Backend.Fake

    defdelegate pull(spec), to: Fake
    defdelegate create(spec), to: Fake
    defdelegate start(id), to: Fake
    defdelegate stop(id, opts), to: Fake
    defdelegate remove(id, opts), to: Fake
    def state(_id), do: {:ok, :stopped}
  end
end
