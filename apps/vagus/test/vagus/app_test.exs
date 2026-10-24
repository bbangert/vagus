defmodule Vagus.AppTest do
  # Installs apps under the global `Vagus.App.Instances`, and briefly stops it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Vagus.AppFixtures

  alias Vagus.Addon.{Backend, Config, Store}
  alias Vagus.App
  alias Vagus.App.Directory
  alias Vagus.App.File, as: AppFile

  defp config(overrides \\ %{}) do
    slug = "app_test_#{System.unique_integer([:positive])}"

    {:ok, config} =
      %{
        "name" => "App Test",
        "version" => "1.0",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "host_network" => true
      }
      |> Map.merge(overrides)
      |> Config.parse()

    config
  end

  defp track(config, opts \\ []), do: install_app(config, opts).slug

  defp corrupt_file do
    slug = "app_test_#{System.unique_integer([:positive])}"
    path = Path.join(AppFile.dir(), slug <> ".json")
    File.mkdir_p!(AppFile.dir())
    File.write!(path, "{{{")
    on_exit(fn -> File.rm(path) end)
    slug
  end

  describe "set/2" do
    test "writes options and settings" do
      slug = track(config())

      assert :ok = App.set(slug, options: %{"a" => 1}, watchdog: true)
      assert {:ok, %{user_options: %{"a" => 1}, watchdog: true}} = app_info(slug)
    end

    test "an unknown key raises before anything is written" do
      slug = track(config())

      assert_raise ArgumentError, fn -> App.set(slug, watchdog: true, bogus: 1) end
      assert {:ok, %{watchdog: false}} = app_info(slug)
    end

    test "an untracked slug is :error" do
      assert :error = App.set("app_test_untracked", boot: "manual")
    end

    test "an untracked slug is :error even with nothing to write" do
      assert :error = App.set("app_test_untracked", [])
    end
  end

  describe "a protected app" do
    setup do
      prev = Application.get_env(:vagus, :protected_apps)
      prev_backend = Application.get_env(:vagus, :addon_backend)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      root = Path.join(System.tmp_dir!(), "app-test-#{System.unique_integer([:positive])}")
      Application.put_env(:vagus, :addon_backend, Backend.Fake)
      Application.put_env(:vagus, :addon_data_root, root)

      on_exit(fn ->
        for {key, value} <- [
              protected_apps: prev,
              addon_backend: prev_backend,
              addon_data_root: prev_root
            ] do
          if value,
            do: Application.put_env(:vagus, key, value),
            else: Application.delete_env(:vagus, key)
        end

        File.rm_rf(root)
      end)

      slug = track(config(), state: :started)
      Application.put_env(:vagus, :protected_apps, [slug])
      %{slug: slug}
    end

    test "is not stopped, restarted or uninstalled", %{slug: slug} do
      assert {:error, :protected} = App.stop(slug)
      assert {:error, :protected} = App.restart(slug)
      assert {:error, :protected} = App.uninstall(slug)
      assert {:ok, %{state: :started}} = app_info(slug)
    end

    test "keeps its boot and watchdog, and takes its other settings", %{slug: slug} do
      assert {:error, :protected} = App.set(slug, boot: "manual")
      assert {:error, :protected} = App.set(slug, options: %{"a" => 1}, watchdog: true)
      assert {:ok, %{boot: nil, watchdog: false, user_options: %{}}} = app_info(slug)

      assert :ok = App.set(slug, options: %{"a" => 1}, auto_update: true)
      assert {:ok, %{user_options: %{"a" => 1}, auto_update: true}} = app_info(slug)
    end

    test "another app is not protected", %{slug: slug} do
      other = track(config(), state: :started)
      assert App.protected?(slug)
      refute App.protected?(other)
      assert :ok = App.set(other, boot: "manual", watchdog: true)
      assert :ok = App.stop(other)
    end

    test "is not restored, which would stop it and could leave it stopped", %{slug: slug} do
      assert {:error, :protected} = App.restore(slug, "/nonexistent", nil, false)
      assert {:ok, %{state: :started}} = app_info(slug)
    end

    test "a start while it runs is :ok and leaves its container alone", %{slug: slug} do
      Backend.Fake.reset_calls()

      assert {:ok, %{slug: ^slug}} = App.start(slug)
      assert Backend.Fake.calls_for("addon_" <> slug) == []
      assert {:ok, %{state: :started}} = app_info(slug)
    end

    test "a start while it is stopped starts it" do
      stopped = track(config())
      Application.put_env(:vagus, :protected_apps, [stopped])
      Backend.Fake.reset_calls()

      assert {:ok, %{slug: ^stopped}} = App.start(stopped)
      assert {:create, "addon_" <> ^stopped} = List.keyfind(Backend.Fake.calls(), :create, 0)
      assert {:ok, %{state: :started}} = app_info(stopped)
    end

    test "another app's start while it runs replaces its container" do
      other = track(config(), state: :started)
      Backend.Fake.reset_calls()

      assert {:ok, _} = App.start(other)
      assert {:create, "addon_" <> ^other} = List.keyfind(Backend.Fake.calls(), :create, 0)
    end

    test "is not anything, nor is nil, with the key unset", %{slug: slug} do
      Application.delete_env(:vagus, :protected_apps)
      refute App.protected?(slug)
      refute App.protected?(nil)
    end

    test "nothing is protected with the key unset", %{slug: slug} do
      Application.put_env(:vagus, :protected_apps, [])
      refute App.protected?(slug)
      assert :ok = App.set(slug, boot: "manual", watchdog: true)
      assert {:ok, _} = App.restart(slug)
      assert :ok = App.stop(slug)
      assert :ok = App.uninstall(slug)
    end

    test "both agent apps are protected, and protection does not refuse an update", %{slug: slug} do
      memory = track(config(%{"backup" => "cold"}), state: :started)
      Application.put_env(:vagus, :protected_apps, [slug, memory])

      for app <- [slug, memory] do
        assert App.protected?(app)
        assert {:error, :protected} = App.stop(app)
        assert {:error, :protected} = App.restart(app)
        assert {:error, :protected} = App.uninstall(app)
        assert {:error, :protected} = App.restore(app, "/nonexistent", nil, false)
        assert {:error, :protected} = App.set(app, boot: "manual")
        assert App.update(app, []) == {:error, :not_in_store}
      end
    end

    # The guard is on requests: the backup's own stop is the app's process's.
    test "a cold backup still stops and starts it" do
      memory = track(config(%{"backup" => "cold"}), state: :started)
      Application.put_env(:vagus, :protected_apps, [memory])

      staging =
        Path.join(System.tmp_dir!(), "app-test-cold-#{System.unique_integer([:positive])}")

      File.mkdir_p!(staging)
      on_exit(fn -> File.rm_rf(staging) end)
      stub_app_steps()

      backup = Task.async(fn -> App.backup(memory, staging) end)
      answer(:stop, {:ok, %{was_running: true}})
      answer_snapshot(memory)
      answer(:start, {:ok, %{container_id: "c2"}})

      assert {:ok, path} = Task.await(backup)
      assert path == Path.join(staging, memory <> ".tar.gz")
      assert {:ok, %{state: :started}} = app_info(memory)
    end
  end

  test "install/2 refuses an unknown per-install setting before anything is written" do
    config = config()

    assert_raise ArgumentError, ~r/unknown app setting :bogus/, fn ->
      App.install(config, settings: [bogus: 1])
    end

    refute config.slug in App.slugs()
    assert App.info(config.slug) == :error
  end

  describe "identity_for_token/1" do
    setup do
      config = config()
      %{token: register_app_token(config), slug: config.slug}
    end

    test "resolves a registered token", %{token: token, slug: slug} do
      assert {:ok, %{slug: ^slug}} = App.identity_for_token(token)
      assert :error = App.identity_for_token("app-test-unknown")
    end

    test "is :error once the app's process is gone", %{token: token, slug: slug} do
      :ok = Vagus.App.Instances.stop(slug)

      assert :error = App.identity_for_token(token)
    end
  end

  describe "install/1" do
    setup do
      prev = Application.get_env(:vagus, :addon_backend)
      Application.put_env(:vagus, :addon_backend, Backend.Fake)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:vagus, :addon_backend, prev),
          else: Application.delete_env(:vagus, :addon_backend)
      end)
    end

    test "records the app as :stopped" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)

      assert :ok = App.install(config)
      assert {:ok, %{state: :stopped}} = app_info(config.slug)
    end

    test "a slug whose file does not decode is refused, not installed over" do
      slug = corrupt_file()
      Backend.Fake.reset_calls()

      assert {:error, :corrupt_file} = App.install(config(%{"slug" => slug}))
      assert Backend.Fake.calls() == []
      assert File.read!(Path.join(AppFile.dir(), slug <> ".json")) == "{{{"
    end

    test "an installed slug is refused before the pull" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      assert :ok = App.install(config)
      Backend.Fake.reset_calls()

      assert {:error, :already_installed} = App.install(config)
      refute Enum.any?(Backend.Fake.calls_for("addon_#{config.slug}"), &match?({:pull, _}, &1))
    end

    test "uninstall stops the app's process" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      :ok = App.install(config)
      [{pid, _}] = Elixir.Registry.lookup(Vagus.App.Directory, {:slug, config.slug})
      ref = Process.monitor(pid)

      assert :ok = App.uninstall(config.slug)
      # `:normal` when its own read after the delete found the entry gone.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :shutdown]
      refute App.installed?(config.slug)
    end

    test "the same slug installs again right after an uninstall" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      :ok = App.install(config)
      :ok = App.uninstall(config.slug)

      assert :ok = App.install(config)
      assert {:ok, %{state: :stopped}} = app_info(config.slug)
    end

    test "a process waiting in :new takes the install" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      {:ok, pid} = Vagus.App.Instances.ensure(config.slug)

      assert :ok = App.install(config)
      assert [{^pid, _}] = Elixir.Registry.lookup(Directory, {:slug, config.slug})
      assert {:ok, %{state: :stopped}} = app_info(config.slug)
    end

    test "with no process to run it, an install pulls nothing and records nothing" do
      stop_instances()
      config = config()
      Backend.Fake.reset_calls()

      assert {:error, :unavailable} = App.install(config)
      assert [] = Backend.Fake.calls_for("addon_#{config.slug}")
      refute config.slug in App.slugs()
    end

    test "an install issued during an uninstall is refused; once it ends the slug installs" do
      config = config()
      slug = config.slug
      on_exit(fn -> forget_app(slug) end)
      :ok = App.install(config)
      [{old, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
      old_ref = Process.monitor(old)

      stub_app_steps()
      uninstall = Task.async(fn -> App.uninstall(slug) end)
      assert_receive {:step, :stop, _input, stopping}, 5_000

      assert {:error, :already_installed} = App.install(config)
      send(stopping, {:outcome, {:ok, %{was_running: false}}})
      assert_receive {:step, :remove_app, _input, removing}, 5_000
      send(removing, {:outcome, {:ok, :ok}})
      assert :ok = Task.await(uninstall)
      assert_receive {:DOWN, ^old_ref, :process, ^old, :normal}

      install = Task.async(fn -> App.install(config) end)
      assert_receive {:step, :pull, _input, pulling}, 5_000
      send(pulling, {:outcome, {:ok, "x/y:1.0"}})
      assert :ok = Task.await(install)
      assert {:ok, %{state: :stopped, config: %{slug: ^slug}}} = App.info(slug)
    end

    test "concurrent installs of one slug pull once" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      Backend.Fake.reset_calls()

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> App.install(config) end) end)
        |> Task.await_many()

      assert Enum.sort(results) ==
               Enum.sort([:ok | List.duplicate({:error, :already_installed}, 3)])

      pulls = Enum.filter(Backend.Fake.calls_for("addon_#{config.slug}"), &match?({:pull, _}, &1))
      assert length(pulls) == 1
    end

    test "a refused install records nothing" do
      config = %{config() | slug: "vagus"}

      assert {:error, {:reserved_slug, "vagus"}} = App.install(config)
      assert :error = app_info("vagus")
    end

    # Saved by an earlier release, before `privileged:` was checked. The file
    # no longer loads, so only an uninstall gets the user out, and it must
    # leave nothing for a reinstall to trip over.
    @tag :tmp_dir
    test "a refused app uninstalls like any other, and its slug installs again", %{tmp_dir: tmp} do
      previous = Application.fetch_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :addon_data_root, tmp)

      on_exit(fn ->
        case previous do
          {:ok, root} -> Application.put_env(:vagus, :addon_data_root, root)
          :error -> Application.delete_env(:vagus, :addon_data_root)
        end
      end)

      valid = config()
      slug = valid.slug
      on_exit(fn -> forget_app(slug) end)
      path = Path.join(AppFile.dir(), slug <> ".json")
      raw = valid |> Config.to_persistable() |> Map.put("privileged", ["ALL"])
      File.mkdir_p!(AppFile.dir())
      File.write!(path, Jason.encode!(%{"config" => raw, "wanted" => "started"}))
      data_dir = Path.join([tmp, "addons", "data", slug])
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "state"), "kept by the app")
      Backend.Fake.reset_calls()

      capture_log(fn -> assert {:ok, pid} = Vagus.App.Instances.ensure(slug) end)
      [{pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
      ref = Process.monitor(pid)
      assert [%{state: :unknown}] = Enum.filter(App.list(), &(&1.config.slug == slug))
      assert :ok = App.boot_start(slug, false)
      assert {:error, :corrupt_file} = App.install(valid)
      assert Backend.Fake.calls_for("addon_#{slug}") == []

      assert :ok = App.uninstall(slug)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute File.exists?(path)
      refute File.exists?(data_dir)
      calls = Backend.Fake.calls()
      assert {:stop, "addon_#{slug}"} in calls
      assert {:remove, "addon_#{slug}"} in calls
      assert {:remove_image, "x/y:1.0"} in calls
      refute Enum.any?(App.list(), &(&1.config.slug == slug))

      assert :ok = App.install(valid)
      assert {:ok, %{state: :stopped, config: %{privileged: []}}} = app_info(slug)
    end

    @tag :tmp_dir
    test "an app the legacy import kept as it was is listed, never started, and uninstalls",
         %{tmp_dir: tmp} do
      valid = config()
      slug = valid.slug
      on_exit(fn -> forget_app(slug) end)
      raw = valid |> Config.to_persistable() |> Map.put("privileged", ["ALL"])
      legacy = Path.join(tmp, "addons.json")
      entry = %{"config" => raw, "state" => "started"}
      File.write!(legacy, Jason.encode!(%{"version" => 1, "addons" => %{slug => entry}}))

      capture_log(fn -> assert {:ok, 1} = AppFile.import_once(Path.join(tmp, "apps"), legacy) end)
      File.mkdir_p!(AppFile.dir())

      File.cp!(
        Path.join([tmp, "apps", slug <> ".json"]),
        Path.join(AppFile.dir(), slug <> ".json")
      )

      Backend.Fake.reset_calls()

      capture_log(fn -> assert {:ok, _pid} = Vagus.App.Instances.ensure(slug) end)
      assert [%{state: :unknown}] = Enum.filter(App.list(), &(&1.config.slug == slug))
      assert {:error, :refused} = App.start(slug)
      assert :ok = App.boot_start(slug, false)
      refute Enum.any?(Backend.Fake.calls_for("addon_#{slug}"), &match?({:create, _}, &1))

      assert :ok = App.uninstall(slug)
      assert {:remove, "addon_#{slug}"} in Backend.Fake.calls()
      refute slug in App.slugs()
    end

    # The stub of a corrupt file cannot say the app was native, so nothing
    # but the allowlist tells the uninstall a broker may still be running.
    @tag :tmp_dir
    test "a refused allowlisted native app's running broker is stopped by its uninstall",
         %{tmp_dir: tmp} do
      slug = corrupt_file()
      on_exit(fn -> forget_app(slug) end)

      for {key, value} <- [native_addon_slugs: [slug], addon_data_root: tmp] do
        previous = Application.fetch_env(:vagus, key)
        Application.put_env(:vagus, key, value)

        on_exit(fn ->
          case previous do
            {:ok, old} -> Application.put_env(:vagus, key, old)
            :error -> Application.delete_env(:vagus, key)
          end
        end)
      end

      name = Backend.Native.broker_name("addon_" <> slug)

      {:ok, broker} =
        DynamicSupervisor.start_child(
          Backend.Native.Supervisor,
          %{id: name, start: {Agent, :start_link, [fn -> nil end, [name: name]]}}
        )

      ref = Process.monitor(broker)
      data_dir = Path.join([tmp, "addons", "data", slug])
      File.mkdir_p!(data_dir)
      capture_log(fn -> assert {:ok, _pid} = Vagus.App.Instances.ensure(slug) end)

      assert :ok = App.uninstall(slug)
      assert_receive {:DOWN, ^ref, :process, ^broker, _reason}
      refute File.exists?(Path.join(AppFile.dir(), slug <> ".json"))
      refute File.exists?(data_dir)
    end

    test "an app whose file is corrupt uninstalls too" do
      slug = corrupt_file()
      on_exit(fn -> forget_app(slug) end)
      capture_log(fn -> assert {:ok, _pid} = Vagus.App.Instances.ensure(slug) end)

      assert :ok = App.uninstall(slug)
      refute slug in App.slugs()
      assert :ok = App.install(config(%{"slug" => slug}))
    end
  end

  describe "update/2 of a default app no store lists" do
    setup do
      prev_backend = Application.get_env(:vagus, :addon_backend)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      root = Path.join(System.tmp_dir!(), "app-test-#{System.unique_integer([:positive])}")
      Application.put_env(:vagus, :addon_backend, Backend.Fake)
      Application.put_env(:vagus, :addon_data_root, root)

      on_exit(fn ->
        for {key, value} <- [addon_backend: prev_backend, addon_data_root: prev_root] do
          if value,
            do: Application.put_env(:vagus, key, value),
            else: Application.delete_env(:vagus, key)
        end

        File.rm_rf(root)
      end)
    end

    test "installs the embedded config" do
      {:ok, builtin} = Vagus.App.Units.builtin_config("agent_orchestrator")
      assert Store.get("agent_orchestrator") == :error
      install_app(%{builtin | version: "0.0.9"}, state: :started)

      assert {:ok, %{from: "0.0.9", to: to}} = App.update("agent_orchestrator", [])
      assert to == builtin.version
      assert {:ok, %{config: %{version: ^to}, state: :started}} = app_info("agent_orchestrator")
    end

    test "a slug neither the store nor the builtins know is not in the store" do
      slug = track(config())
      assert App.update(slug, []) == {:error, :not_in_store}
    end
  end

  describe "update/2 with a backup" do
    setup do
      # Nested, so the staging root beside its data root is this test's own.
      base = Path.join(System.tmp_dir!(), "vagus-app-bk-#{System.unique_integer([:positive])}")
      dir = Path.join([base, "data", "backup"])
      prev_dir = Vagus.Backups.dir()
      :ok = Vagus.Backups.set_dir(dir)

      on_exit(fn ->
        Vagus.Backups.set_dir(prev_dir)
        File.rm_rf(base)
      end)

      config = config()
      slug = track(config, state: :started)
      seed_store(%{config | version: "2.0"})
      stub_app_steps()
      %{slug: slug, dir: dir}
    end

    defp seed_store(%Config{slug: slug} = config) do
      catalog = Map.put(Store.catalog(), slug, %{config: config, repository: "core"})
      :ok = GenServer.call(Store, {:put_catalog, catalog})
      on_exit(fn -> GenServer.call(Store, {:put_catalog, Map.delete(Store.catalog(), slug)}) end)
    end

    defp answer(name, outcome) do
      assert_receive {:step, ^name, input, task}, 5_000
      send(task, {:outcome, outcome})
      input
    end

    # Stands in for the snapshot step: writes a real inner tar where it would,
    # whatever outcome it then reports.
    defp answer_snapshot(slug, outcome \\ :ok) do
      assert_receive {:step, :snapshot, %{staging_dir: staging}, task}, 5_000
      addon = %{slug: slug, name: "App Test", version: "1.0", data_dir: "/nonexistent"}
      path = Path.join(staging, slug <> ".tar.gz")
      :ok = Vagus.Backup.write_addon_tar(Map.put(addon, :system, %{"name" => "App Test"}), path)
      send(task, {:outcome, if(outcome == :ok, do: {:ok, path}, else: outcome)})
    end

    test "the snapshot inside the update is kept even when the update rolls back", ctx do
      update = Task.async(fn -> App.update(ctx.slug, backup: true) end)
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})
      answer_snapshot(ctx.slug)
      answer(:start, {:error, :boom})
      answer(:start, {:ok, %{container_id: "c2"}})

      assert {:error, {:rolled_back, :boom}} = Task.await(update)
      assert [%{backup: backup}] = Vagus.Backups.list()
      assert backup["name"] == "addon_#{ctx.slug}_1.0"
      assert [%{"slug" => slug, "version" => "1.0"}] = backup["addons"]
      assert slug == ctx.slug
      assert File.ls!(Vagus.Backups.staging_root(ctx.dir)) == []
    end

    test "a failed snapshot fails the update and stores nothing", ctx do
      update = Task.async(fn -> App.update(ctx.slug, backup: true) end)
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})
      answer_snapshot(ctx.slug, {:error, :enospc})
      answer(:start, {:ok, %{container_id: "c2"}})

      assert {:error, {:backup_failed, :enospc}} = Task.await(update)
      assert Vagus.Backups.list() == []
      assert File.ls!(Vagus.Backups.staging_root(ctx.dir)) == []
    end

    # A snapshot that reports a file it never wrote leaves nothing to store.
    test "an update done whose backup is not stored is the backup's error", ctx do
      update = Task.async(fn -> App.update(ctx.slug, backup: true) end)
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})
      answer(:snapshot, {:ok, "/nowhere/#{ctx.slug}.tar.gz"})
      answer(:start, {:ok, %{container_id: "c2"}})
      answer(:reclaim_image, {:ok, :ok})

      assert {:error, {:backup_not_stored, {:not_staged, slug}}} = Task.await(update)
      assert slug == ctx.slug
      assert {:ok, %{config: %{version: "2.0"}}} = app_info(ctx.slug)
      assert Vagus.Backups.list() == []
    end

    test "an update that fails is its own error, whatever became of its backup", ctx do
      update = Task.async(fn -> App.update(ctx.slug, backup: true) end)
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})
      answer(:snapshot, {:ok, "/nowhere/#{ctx.slug}.tar.gz"})
      answer(:start, {:error, :boom})
      answer(:start, {:ok, %{container_id: "c2"}})

      assert {:error, {:rolled_back, :boom}} = Task.await(update)
      assert Vagus.Backups.list() == []
    end

    test "an update that fails before its snapshot stores nothing", ctx do
      update = Task.async(fn -> App.update(ctx.slug, backup: true) end)
      answer(:pull, {:error, :unreachable})

      assert {:error, {:pull, :unreachable}} = Task.await(update)
      assert Vagus.Backups.list() == []
      assert File.ls!(Vagus.Backups.staging_root(ctx.dir)) == []
    end
  end

  describe "restore/5" do
    setup do
      stub_app_steps()
      :ok
    end

    test "stops, swaps the data in and starts with the restored options" do
      slug = track(config(), state: :started, options: %{"a" => 1})
      restore = Task.async(fn -> App.restore(slug, "/staging", %{"a" => 2}, true) end)

      answer(:stop, {:ok, %{was_running: true}})
      assert %{staging_dir: "/staging"} = answer(:swap_data, {:ok, "/data"})
      assert %{options: %{"a" => 2}} = answer(:set_options, {:ok, %{"a" => 2}})
      assert %{user_options: %{"a" => 2}} = answer(:start, {:ok, %{container_id: "c2"}})

      assert :ok = Task.await(restore)

      assert {:ok, %{state: :started, wanted: :started, user_options: %{"a" => 2}}} =
               app_info(slug)

      assert {:ok, %{user_options: %{"a" => 2}}} = AppFile.read(slug)
    end

    test "a backup of a stopped app leaves it stopped, and nil options keep the current ones" do
      slug = track(config(), state: :started, options: %{"a" => 1})
      restore = Task.async(fn -> App.restore(slug, "/staging", nil, false) end)

      answer(:stop, {:ok, %{was_running: true}})
      answer(:swap_data, {:ok, "/data"})

      assert :ok = Task.await(restore)
      refute_received {:step, :start, _input, _task}

      assert {:ok, %{state: :stopped, wanted: :stopped, user_options: %{"a" => 1}}} =
               app_info(slug)
    end

    test "a failed swap fails the restore before the options or a start" do
      slug = track(config(), state: :started, options: %{"a" => 1})
      restore = Task.async(fn -> App.restore(slug, "/staging", %{"a" => 2}, true) end)

      answer(:stop, {:ok, %{was_running: true}})
      answer(:swap_data, {:error, :exdev})

      assert {:error, :exdev} = Task.await(restore)
      refute_received {:step, :start, _input, _task}
      assert {:ok, %{user_options: %{"a" => 1}}} = app_info(slug)
    end

    test "a busy app refuses it, and an uninstall is refused mid-restore" do
      slug = track(config(), state: :started)
      restore = Task.async(fn -> App.restore(slug, "/staging", nil, false) end)
      assert_receive {:step, :stop, _input, stopping}, 5_000

      assert {:error, :busy} = App.restore(slug, "/other", nil, false)
      assert {:error, :busy} = App.uninstall(slug)

      send(stopping, {:outcome, {:ok, %{was_running: true}}})
      assert_receive {:step, :swap_data, _input, swapping}, 5_000
      assert {:error, :busy} = App.uninstall(slug)
      send(swapping, {:outcome, {:ok, "/data"}})
      assert :ok = Task.await(restore)
      assert App.installed?(slug)
    end
  end

  describe "boot_start/2" do
    defp boot_unsaved(slug) do
      blocker = Path.join(AppFile.dir(), slug <> ".json.tmp")
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)

      capture_log(fn ->
        boot = Task.async(fn -> App.boot_start(slug, false) end)
        assert_receive {:step, :start, _input, starting}, 5_000
        send(starting, {:outcome, {:ok, %{container_id: "c1"}}})
        assert :ok = Task.await(boot)
      end)
    end

    # The orchestrator's boot report would show a running app as failed.
    test "a start whose state cannot be saved still boots" do
      slug = track(config(), state: :started)
      stub_app_steps()
      boot_unsaved(slug)
    end

    test "a resume whose state cannot be saved still boots" do
      slug = track(config(), state: :started)
      stub_app_steps()
      halt = Task.async(fn -> App.halt(slug) end)
      assert_receive {:step, :halt_stop, _input, halting}, 5_000
      send(halting, {:outcome, {:ok, :stopped}})
      assert :ok = Task.await(halt)
      boot_unsaved(slug)
    end
  end

  describe "ingress_target/1" do
    # A host-network app is reached without an engine inspect.
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      on_exit(fn -> :gen_tcp.close(listen) end)
      {:ok, port} = :inet.port(listen)
      %{port: port}
    end

    test "the config's static port", %{port: port} do
      slug = track(config(%{"ingress" => true, "ingress_port" => port}))
      assert {:ok, {"127.0.0.1", ^port, false}} = App.ingress_target(slug)
    end

    test "the allocated port wins over the 0 sentinel", %{port: port} do
      slug = track(config(%{"ingress" => true, "ingress_port" => 0}), ingress_port: port)

      assert {:ok, {"127.0.0.1", ^port, false}} = App.ingress_target(slug)
    end

    test "the 0 sentinel with nothing allocated has no target" do
      slug = track(config(%{"ingress" => true, "ingress_port" => 0}))
      assert {:error, :no_ingress_port} = App.ingress_target(slug)
    end

    test "carries ingress_stream", %{port: port} do
      slug =
        track(config(%{"ingress" => true, "ingress_port" => port, "ingress_stream" => true}))

      assert {:ok, {_ip, ^port, true}} = App.ingress_target(slug)
    end

    test "an untracked slug is not found" do
      assert {:error, :not_found} = App.ingress_target("app_test_untracked")
    end
  end

  describe "ask/3" do
    test "no process for the slug is :absent" do
      assert :absent = App.ask("app_test_nobody", :info)
    end

    test "a process that stopped is :absent" do
      slug = track(config())
      [{pid, _}] = Elixir.Registry.lookup(Vagus.App.Directory, {:slug, slug})
      :ok = :gen_statem.stop(pid)

      assert :absent = App.ask(slug, :info)
    end

    test "a process that does not answer in time is :absent" do
      slug = track(config())
      [{pid, _}] = Elixir.Registry.lookup(Vagus.App.Directory, {:slug, slug})
      :ok = :sys.suspend(pid)
      on_exit(fn -> :sys.resume(pid) end)

      assert :absent = App.ask(slug, :info, 50)
    end
  end

  describe "installed?/1" do
    test "a process in :new is not an installed app" do
      slug = config().slug
      {:ok, _pid} = Vagus.App.Instances.ensure(slug)
      on_exit(fn -> forget_app(slug) end)

      refute App.installed?(slug)
    end

    test "a command to a process with no app installed is not found" do
      slug = config().slug
      {:ok, _pid} = Vagus.App.Instances.ensure(slug)
      on_exit(fn -> forget_app(slug) end)

      assert {:error, :not_found} = App.start(slug)
      assert {:error, :not_found} = App.uninstall(slug)
    end

    test "a saved app with no process is installed, and gets its process back" do
      slug = track(config(), process: false)

      assert App.installed?(slug)
      assert [{_pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
    end
  end

  describe "Instances.ensure/1" do
    test "is {:error, :unavailable} while the app supervisor is down" do
      stop_instances()
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      install_app(config, process: false)

      assert {:error, :unavailable} = Vagus.App.Instances.ensure(config.slug)
    end
  end

  describe "list/0" do
    test "apps that do not answer share one deadline and are listed :unknown" do
      answering = track(config(), state: :started)
      stuck = for _ <- 1..3, do: track(config(), state: :started)
      Enum.each(stuck, &suspend/1)

      started = System.monotonic_time(:millisecond)
      listed = Map.new(App.list(), &{&1.config.slug, &1.state})
      elapsed = System.monotonic_time(:millisecond) - started

      assert listed[answering] == :started
      for slug <- stuck, do: assert(listed[slug] == :unknown)
      assert elapsed < 2 * 1_000
    end

    test "an entry with no process is listed :unknown and info/1 brings it back" do
      slug =
        track(config(), state: :started, process: false, options: %{"a" => 1}, watchdog: true)

      assert [] = Elixir.Registry.lookup(Directory, {:slug, slug})

      assert [%{state: :unknown}] = Enum.filter(App.list(), &(&1.config.slug == slug))

      # Until the engine reports the container, a restarted process knows only
      # what its file says the app should be.
      assert {:ok, %{wanted: :started, config: %{slug: ^slug}}} = App.info(slug)
      assert [{pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
      assert Process.alive?(pid)
    end

    test "an app whose file does not decode is still listed, :unknown" do
      slug = corrupt_file()

      assert [%{state: :unknown, config: %{slug: ^slug}}] =
               Enum.filter(App.list(), &(&1.config.slug == slug))
    end

    test "gather/2 answers every app under one deadline" do
      answering = track(config())
      stuck = for _ <- 1..3, do: track(config())
      pids = Enum.map(stuck, &suspend/1)

      started = System.monotonic_time(:millisecond)
      answers = Map.new(App.gather(:installed?, 1_000))
      elapsed = System.monotonic_time(:millisecond) - started

      assert answers[answering] == {:ok, true}
      for slug <- stuck, do: assert(answers[slug] == :absent)
      assert elapsed < 2 * 1_000

      # The stuck apps answer once resumed; the abandoned requests' replies
      # must not land in the caller's mailbox. `get_state` returns only after
      # the queued call has been handled.
      for pid <- pids, do: :ok = :sys.resume(pid)
      for pid <- pids, do: _ = :sys.get_state(pid)
      refute_received _late_reply
    end
  end

  describe "services and discovery" do
    test "a provided service is found by name, with its provider" do
      slug = track(config())
      name = "svc_#{slug}"

      assert :ok = App.provide_service(slug, name, %{"host" => "h"})
      assert {:ok, ^slug, %{"host" => "h"}} = App.service(name)
      assert {name, slug} in App.services()
      assert :error = App.service("none_#{slug}")
    end

    test "a provide from an app whose process is missing starts it and lands" do
      slug = track(config(), process: false)
      name = "svc_#{slug}"

      assert :ok = App.provide_service(slug, name, %{})
      assert {:ok, ^slug, %{}} = App.service(name)
    end

    test "a provide or a discovery from an app that is not installed is unavailable" do
      slug = "core_app_ghost_#{System.unique_integer([:positive])}"

      assert {:error, :unavailable} = App.provide_service(slug, "svc_#{slug}", %{})
      assert {:error, :unavailable} = App.add_discovery(slug, "mqtt", %{})
      assert [] = Elixir.Registry.lookup(Directory, {:slug, slug})
    end

    test "only the provider withdraws its service" do
      owner = track(config())
      other = track(config())
      name = "svc_#{owner}"
      :ok = App.provide_service(owner, name, %{})

      assert {:error, :not_found} = App.withdraw_service(other, name)
      assert {:ok, ^owner, _payload} = App.service(name)
      assert :ok = App.withdraw_service(owner, name)
      assert :error = App.service(name)
    end

    test "only the owner deletes its discovery message" do
      owner = track(config())
      other = track(config())
      {:ok, %{uuid: uuid} = message, :new} = App.add_discovery(owner, "mqtt", %{})

      assert {:ok, ^message} = App.discovery(uuid)
      assert {:error, :not_owner} = App.delete_discovery(other, uuid)
      assert {:ok, ^message} = App.delete_discovery(owner, uuid)
      assert {:error, :not_found} = App.delete_discovery(owner, uuid)
      assert :error = App.discovery(uuid)
    end

    test "discoveries/0 gathers every app's messages and leaves out, and logs, those that do not answer" do
      a = track(config())
      b = track(config())
      stuck = for _ <- 1..2, do: track(config())
      {:ok, %{uuid: ua}, :new} = App.add_discovery(a, "mqtt", %{})
      {:ok, %{uuid: ub}, :new} = App.add_discovery(b, "mqtt", %{})
      stuck_uuids = for slug <- stuck, do: elem(App.add_discovery(slug, "mqtt", %{}), 1).uuid
      pids = Enum.map(stuck, &suspend/1)

      {{uuids, elapsed}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          started = System.monotonic_time(:millisecond)
          uuids = Enum.map(App.discoveries(), & &1.uuid)
          {uuids, System.monotonic_time(:millisecond) - started}
        end)

      assert ua in uuids and ub in uuids
      for uuid <- stuck_uuids, do: refute(uuid in uuids)
      assert elapsed < 2 * 1_000
      for slug <- stuck, do: assert(log =~ slug)

      for pid <- pids, do: :ok = :sys.resume(pid)
      for pid <- pids, do: _ = :sys.get_state(pid)
      refute_received _late_reply
    end
  end

  # A child stopped through `terminate_child/2` stays down until restarted;
  # every app process goes with it.
  defp stop_instances do
    :ok = Supervisor.terminate_child(Vagus.App.Supervisor, Vagus.App.Instances)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Vagus.App.Supervisor, Vagus.App.Instances)
    end)
  end

  defp suspend(slug) do
    [{pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
    :ok = :sys.suspend(pid)
    on_exit(fn -> :sys.resume(pid) end)
    pid
  end
end
