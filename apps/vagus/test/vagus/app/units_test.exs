defmodule Vagus.App.UnitsTest do
  # `async: false`: installed apps are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  import Vagus.AppFixtures,
    only: [
      app_config: 2,
      app_info: 1,
      forget_app: 1,
      install_app: 1,
      install_app: 2,
      listening_api_port: 0
    ]

  alias Vagus.App.{Gates, Units}
  alias Vagus.Core.EventPusher

  @arities %{
    import: 0,
    slugs: 0,
    list: 0,
    ensure: 1,
    in_flight?: 0,
    install_default: 1,
    builtin_native?: 1,
    native?: 1,
    boot_start: 2,
    start: 1,
    running: 0,
    inspect: 1,
    halt: 1,
    core_start: 1,
    core_stop: 1,
    report: 2,
    push_complete: 0,
    agent?: 0
  }

  test "every unit is a function of the arity the orchestrator calls it with" do
    units = Units.all()

    assert Map.keys(units) |> Enum.sort() ==
             Enum.sort([:gates, :stop_containers | Map.keys(@arities)])

    for {key, arity} <- @arities do
      assert is_function(Map.fetch!(units, key), arity), "#{key}/#{arity}"
    end

    assert Map.keys(units.gates) |> Enum.sort() == [
             :api,
             :dist,
             :engine,
             :network,
             :patches,
             :primary,
             :tree
           ]

    assert Enum.all?(Map.values(units.gates), &is_function(&1, 0))
  end

  describe "stop_containers" do
    test "is a unit" do
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

  describe "builtin default apps" do
    test "the agent orchestrator parses as a host-network container app" do
      assert {:ok, config} = Units.builtin_config("agent_orchestrator")

      assert %{
               slug: "agent_orchestrator",
               name: "Agent orchestrator",
               image: "ghcr.io/bbangert/vagus-agent-orchestrator",
               version: "0.3.0",
               backend: :container,
               startup: "application",
               boot: "auto",
               init: false,
               host_network: true,
               host_dbus: true,
               arch: ["aarch64"],
               map: []
             } = config

      refute Units.builtin_native?("agent_orchestrator")
    end

    test "the agent memory parses as a cold-backup bridged container app" do
      assert {:ok, config} = Units.builtin_config("agent_memory")

      assert %{
               slug: "agent_memory",
               image: "docker.io/pgvector/pgvector",
               version: "pg17",
               backend: :container,
               startup: "application",
               boot: "auto",
               init: false,
               host_network: false,
               backup: "cold",
               watchdog: "tcp://[HOST]:5432",
               arch: ["aarch64"],
               ports: %{}
             } = config

      assert Vagus.App.Steps.build_spec(config, arch: "aarch64").image ==
               "docker.io/pgvector/pgvector:pg17"

      refute Units.builtin_native?("agent_memory")
    end

    test "the memory server is native only where the allowlist names it" do
      assert {:ok, %{slug: "vagus_memory", backend: :native, boot: "auto", version: "1.0.0"}} =
               Units.builtin_config("vagus_memory")

      refute Units.builtin_native?("vagus_memory")

      Application.put_env(:vagus, :native_addon_slugs, ["core_mqtt", "vagus_memory"])
      on_exit(fn -> Application.delete_env(:vagus, :native_addon_slugs) end)

      assert Units.builtin_native?("vagus_memory")
    end

    test "the broker is native under its installed slug, and anything else has no builtin" do
      assert {:ok, %{slug: "core_mqtt", backend: :native}} = Units.builtin_config("core_mqtt")
      assert Units.builtin_native?("core_mqtt")
      assert Units.builtin_config("other") == {:error, :no_builtin}
      refute Units.builtin_native?("other")
    end
  end

  describe "installing the agent apps" do
    setup do
      prev = Application.get_env(:vagus, :protected_apps)
      prev_memory = Application.get_env(:vagus, :memory_app)
      prev_backend = Application.get_env(:vagus, :addon_backend)
      # The memory app is bridged, so its start ensures agentnet.
      Vagus.Runtime.Engine.Fake.start_global()
      Application.put_env(:vagus, :addon_backend, Vagus.Addon.Backend.Fake)
      Application.put_env(:vagus, :protected_apps, ["agent_orchestrator", "agent_memory"])
      Application.put_env(:vagus, :memory_app, "agent_memory")

      on_exit(fn ->
        forget_app("agent_orchestrator")
        forget_app("agent_memory")

        for {key, value} <- [
              protected_apps: prev,
              memory_app: prev_memory,
              addon_backend: prev_backend
            ] do
          if value,
            do: Application.put_env(:vagus, key, value),
            else: Application.delete_env(:vagus, key)
        end
      end)
    end

    test "records each booting and revived after a crash, which no request then changes" do
      for slug <- ["agent_orchestrator", "agent_memory"] do
        assert Units.install_default(slug) == :installed
        assert {:ok, %{boot: "auto", watchdog: true, wanted: :started}} = app_info(slug)

        assert {:error, :protected} = Vagus.App.set(slug, watchdog: false)
        assert {:error, :protected} = Vagus.App.set(slug, boot: "manual")
        assert {:ok, %{boot: "auto", watchdog: true}} = app_info(slug)

        {:ok, saved} = Vagus.App.File.read(slug)
        data = Vagus.App.Policy.init_data(slug, saved)
        assert Vagus.App.Policy.restart?(data, false)
      end
    end

    test "one already installed without its protected settings gets them back" do
      for slug <- ["agent_orchestrator", "agent_memory"] do
        {:ok, config} = Units.builtin_config(slug)
        install_app(config, boot: "manual", watchdog: false)

        assert Units.install_default(slug) == :present
        assert {:ok, %{boot: "auto", watchdog: true}} = app_info(slug)
      end
    end
  end

  describe "the patches gate" do
    setup do
      n = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "units_patches_#{n}")
      # unique_integer repeats across VMs, and a VM killed mid-run leaves its roots.
      File.rm_rf!(root)

      on_exit(fn ->
        :persistent_term.erase({Vagus.Patches, :boot_done, root})
        File.rm_rf(root)
      end)

      %{root: root, server: :"units_patches_#{n}", n: n}
    end

    defp patch(root, name, source) do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "NOTES.md"), "")
      File.write!(Path.join(dir, "x.ex"), source)
      File.touch!(Path.join(dir, "enabled"))
    end

    defp start_patches(root, server),
      do: start_supervised!({Vagus.Patches, name: server, enabled: true, root: root})

    defp gate_until_ok(server, tries \\ 400) do
      case Gates.patches(server: server) do
        :ok -> :ok
        _loading when tries > 0 -> Process.sleep(5) && gate_until_ok(server, tries - 1)
        other -> flunk("gate never passed: #{inspect(other)}")
      end
    end

    test "passes at once with nothing enabled", %{root: root, server: server} do
      start_patches(root, server)
      assert Gates.patches(server: server) == :ok
      assert %{"good" => true} = root |> Path.join(".boot") |> File.read!() |> Jason.decode!()
    end

    test "answers loading until the load is done", %{root: root, server: server, n: n} do
      test_pid = ~c"#{:erlang.pid_to_list(self())}"

      # The module body runs at compile time: it holds the load open.
      patch(root, "slow", """
      defmodule Vagus.UnitsPatch.Slow#{n} do
        send(:erlang.list_to_pid(#{inspect(test_pid)}), {:compiling, self()})
        receive do: (:go -> :ok)
      end
      """)

      start_patches(root, server)
      assert Gates.patches(server: server) == {:error, :loading}
      assert_receive {:compiling, compiler}, 1_000
      assert Gates.patches(server: server) == {:error, :loading}
      assert Vagus.Patches.boot_status(server: server) == :running

      send(compiler, :go)
      gate_until_ok(server)
      assert Vagus.Patches.boot_status(server: server) == {:done, %{"slow" => :ok}}
    end

    test "passes when patches failed, which are their own results", %{root: root, server: server} do
      patch(root, "broken", "defmodule")
      start_patches(root, server)

      gate_until_ok(server)
      assert {:done, %{"broken" => {:error, _}}} = Vagus.Patches.boot_status(server: server)
    end

    test "passes when the breaker skipped the patches", %{root: root, server: server} do
      patch(root, "p", "defmodule")
      File.write!(Path.join(root, ".boot"), Jason.encode!(%{"good" => false, "patches" => ["p"]}))
      start_patches(root, server)

      assert Gates.patches(server: server) == :ok
      assert {:skipped, _reason} = Vagus.Patches.boot_status(server: server)
    end

    test "retries a server that is not running", %{server: server} do
      assert Gates.patches(server: server) == {:error, :not_running}
    end
  end

  describe "the dist gate" do
    setup do
      dir = Path.join(System.tmp_dir!(), "units_dist_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {gid, 0} = System.cmd("id", ["-g"])
      %{dir: dir, gid: String.to_integer(String.trim(gid))}
    end

    test "retries an exit, which a raise or a throw is not", %{dir: dir} do
      assert Gates.dist(enable: fn -> exit(:table_restarting) end, dir: dir) ==
               {:error, {:exit, :table_restarting}}
    end

    @session %{node: :"vagus@192.168.2.58", cookie: String.duplicate("ab", 32), ports: 9100..9105}

    test "passes once the session is exported", %{dir: dir, gid: gid} do
      assert Gates.dist(enable: fn -> {:ok, @session} end, dir: dir, gid: gid) == :ok
      assert %{"cookie" => _} = dir |> Path.join("node.json") |> File.read!() |> Jason.decode!()
    end

    test "retries a claim in flight and a missing address", %{dir: dir} do
      for reason <- [:starting, :no_address] do
        assert Gates.dist(enable: fn -> {:error, reason} end, dir: dir) == {:error, reason}
      end

      refute File.exists?(dir)
    end

    test "any other failure, a raise or an unwritable export is fatal", %{dir: dir} do
      assert Gates.dist(enable: fn -> {:error, :node_gone} end, dir: dir) ==
               {:fatal, :node_gone}

      assert {:fatal, {:error, %RuntimeError{}}} =
               Gates.dist(enable: fn -> raise "bring-up failed" end, dir: dir)

      assert {:fatal, {:throw, :stuck}} = Gates.dist(enable: fn -> throw(:stuck) end, dir: dir)

      File.write!(dir, "")

      assert {:fatal, {:export, _reason}} =
               Gates.dist(enable: fn -> {:ok, @session} end, dir: dir)
    end
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
