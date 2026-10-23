defmodule Vagus.BluetoothTest.Harness do
  @moduledoc false
  # A real Vagus.Bluetooth tree whose Stack holds Recorder children under the
  # real child ids, so the tests see the order the supervisors used.

  import ExUnit.Assertions
  import ExUnit.Callbacks

  defmodule Recorder do
    @moduledoc false
    # Traps exits so its shutdown is reported, and answers `:os_pid` the way
    # MuonTrap.Daemon does, so stop/1's default os_pid_fun runs for real.
    use GenServer

    def start_link({id, test}), do: GenServer.start_link(__MODULE__, {id, test})

    @impl GenServer
    def init({id, test}) do
      Process.flag(:trap_exit, true)
      send(test, {:started, id})
      {:ok, {id, test}}
    end

    @impl GenServer
    def handle_call(:os_pid, _from, {id, _test} = state),
      do: {:reply, Vagus.BluetoothTest.Harness.fake_os_pid(id), state}

    @impl GenServer
    def terminate(_reason, {id, test}), do: send(test, {:stopped, id})
  end

  def daemon_ids, do: [:signal_handler, :dbus_daemon, Bluez.BusReady, :bluetoothd]
  def improv_ids, do: [Improv.Supervisor, Vagus.Improv.Reaper]
  def all_ids, do: daemon_ids() ++ improv_ids()

  def fake_os_pid(id), do: 1_000_000 + :erlang.phash2(id, 1_000_000)

  def stack_name(name), do: Module.concat(name, "Stack")

  # `on_prepare` runs inside the Stack's init, before `:prepared` is sent.
  def start_tree(ctx, ids \\ all_ids(), on_prepare \\ fn -> :ok end) do
    name = Module.concat([ctx.module, "Sup#{System.unique_integer([:positive])}"])
    test = self()

    start_supervised!(
      {Vagus.Bluetooth,
       name: name,
       dbus_daemon_path: __ENV__.file,
       bluetoothd_path: __ENV__.file,
       prepare_runtime: fn ->
         on_prepare.()
         send(test, :prepared)
       end,
       children: Enum.map(ids, &%{id: &1, start: {Recorder, :start_link, [{&1, test}]}})}
    )

    assert received() == [:prepared | Enum.map(ids, &{:started, &1})]
    name
  end

  # Every message is sent before the call under test returns (init/1 and
  # terminate/2 run inside the supervisor's synchronous calls); the timeout
  # only ends collection.
  def received do
    receive do
      {kind, id} when kind in [:started, :stopped] -> [{kind, id} | received()]
      :prepared -> [:prepared | received()]
    after
      50 -> []
    end
  end

  def app(slug, host_dbus, state, alive? \\ false),
    do: %{
      alive?: alive?,
      config: %Vagus.Addon.Config{
        slug: slug,
        name: slug,
        version: "1",
        description: "",
        arch: [],
        host_dbus: host_dbus
      },
      state: state
    }

  def toggle_opts(name, tmp, overrides \\ []) do
    Keyword.merge(
      [
        server: name,
        socket_path: Path.join(tmp, "system_bus_socket"),
        apps_fun: fn -> [] end,
        proc_alive_fun: fn _os_pid -> false end,
        live_daemons_fun: fn -> [] end
      ],
      overrides
    )
  end
end

defmodule Vagus.BluetoothTest do
  use ExUnit.Case, async: true

  import Vagus.BluetoothTest.Harness

  alias Vagus.Bluetooth

  # Child-order/slice tests against the pure `Bluez.children/1` list — no
  # daemons, no D-Bus. Guards the load-bearing cut: everything up to and
  # including :bluetoothd, none of the client/audio stack (which would
  # compete with HA Core for the radio — see the moduledoc).
  describe "daemon_children/1" do
    test "ends at the :bluetoothd spec and includes the daemon prerequisites" do
      children = Bluetooth.daemon_children()

      assert %{id: :bluetoothd} = List.last(children)
      assert Enum.any?(children, &match?(%{id: :dbus_daemon}, &1))
      # The socket gate between the two daemons.
      assert Bluez.BusReady in children
      # The rebus runtime the BusReady gate rides on.
      assert Enum.any?(children, &match?({Bluez.Rebus.SignalHandler, _}, &1))
    end

    test "excludes every client and audio child" do
      children = Bluetooth.daemon_children()

      for excluded <- [Bluez.Client, Bluez.Agent, Bluez.Gatt, Bluez.BlueAlsa] do
        refute Enum.any?(children, fn
                 {mod, _opts} -> mod == excluded
                 %{id: id} -> id == excluded
                 mod -> mod == excluded
               end),
               "expected #{inspect(excluded)} to be sliced off"
      end

      refute Enum.any?(children, &match?(%{id: :bluealsad}, &1))
    end
  end

  describe "children/1" do
    test "appends the Improv group + reaper after the daemon slice" do
      children = Bluetooth.children()

      assert children ==
               Bluetooth.daemon_children() ++
                 [Vagus.Improv.supervisor_child(), Vagus.Improv.Reaper]

      # Mounting contract: Improv rides LAST under :rest_for_one so a
      # bluetoothd restart rebuilds it, never the other way around.
      assert [{Improv.Supervisor, _opts}, Vagus.Improv.Reaper] = Enum.take(children, -2)
    end

    test "improv: false yields the bare daemon slice" do
      assert Bluetooth.children(improv: false) == Bluetooth.daemon_children(improv: false)
    end

    test "the Recorder tail ids are the real Improv child ids" do
      assert Supervisor.child_spec(Vagus.Improv.supervisor_child(), []).id == Improv.Supervisor
      assert Supervisor.child_spec(Vagus.Improv.Reaper, []).id == Vagus.Improv.Reaper
    end
  end

  describe "start_link/1" do
    import ExUnit.CaptureLog

    test "returns :ignore when the daemon binaries are missing" do
      log =
        capture_log(fn ->
          assert :ignore =
                   Bluetooth.start_link(
                     dbus_daemon_path: "/nonexistent/dbus-daemon",
                     bluetoothd_path: "/nonexistent/bluetoothd"
                   )
        end)

      assert log =~ "/nonexistent/dbus-daemon"
    end

    test "the production name registers the stack where the Reaper looks" do
      assert Vagus.Bluetooth.stack_name(Vagus.Bluetooth) == Vagus.Bluetooth.Stack
    end

    test "nests the stack as the single child", ctx do
      name = start_tree(ctx)

      assert [{Vagus.Bluetooth.Stack, stack, :supervisor, _}] = Supervisor.which_children(name)
      assert stack == Process.whereis(stack_name(name))
      assert stack == Process.whereis(Module.concat(name, "Stack"))

      assert stack |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) ==
               Enum.reverse(all_ids())
    end
  end

  describe "stop/1" do
    @describetag :tmp_dir

    test "takes the stack down newest-first, waits for both daemons' OS processes, then drops the socket",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      socket = Path.join(tmp, "system_bus_socket")
      File.write!(socket, "")
      test = self()
      polls = :counters.new(1, [])

      # Both "alive" for three polls; the socket must survive until they go.
      alive = fn os_pid ->
        :counters.add(polls, 1, 1)
        send(test, {:polled, os_pid, File.exists?(socket)})
        :counters.get(polls, 1) <= 6
      end

      assert :ok = Bluetooth.stop(toggle_opts(name, tmp, proc_alive_fun: alive))

      assert received() == all_ids() |> Enum.reverse() |> Enum.map(&{:stopped, &1})
      assert :counters.get(polls, 1) > 6

      polled = polled()

      assert polled |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort([fake_os_pid(:dbus_daemon), fake_os_pid(:bluetoothd)])

      assert Enum.all?(polled, &elem(&1, 1))
      refute File.exists?(socket)
      assert Bluetooth.status(server: name) == :stopped
    end

    test "a daemon that never exits is reported and keeps its socket", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      opts = toggle_opts(name, tmp, proc_alive_fun: fn _ -> true end, os_exit_timeout_ms: 150)
      File.write!(opts[:socket_path], "")

      assert {:error, {:still_running, id}} = Bluetooth.stop(opts)
      assert id in [:dbus_daemon, :bluetoothd]
      assert File.exists?(opts[:socket_path])
    end

    test "a retry after a timed-out wait still waits, and drops the socket only once the daemon is gone",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      up = :atomics.new(1, [])
      :atomics.put(up, 1, 1)

      opts =
        toggle_opts(name, tmp,
          proc_alive_fun: fn _ -> true end,
          live_daemons_fun: fn -> if :atomics.get(up, 1) == 1, do: [:bluetoothd], else: [] end,
          os_exit_timeout_ms: 100
        )

      File.write!(opts[:socket_path], "")

      assert {:error, {:still_running, _}} = Bluetooth.stop(opts)
      assert Bluetooth.status(server: name) == :stopped

      assert {:error, {:still_running, :bluetoothd}} = Bluetooth.stop(opts)
      assert File.exists?(opts[:socket_path])

      :atomics.put(up, 1, 0)
      assert :ok = Bluetooth.stop(opts)
      refute File.exists?(opts[:socket_path])
    end

    test "the default scan finds a daemon this VM spawned, by name and ancestry",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      :ok = Bluetooth.stop(toggle_opts(name, tmp))
      fake = Path.join(tmp, "bluetoothd")
      # A script, since coreutils' multicall `sleep` refuses a renamed argv[0];
      # the kernel names the process after the script file.
      File.write!(fake, "#!/bin/sh\nwhile :; do sleep 1; done\n")
      File.chmod!(fake, 0o755)

      # Orphaned by its exiting shell, so outside this VM's tree, as a
      # container's bluetoothd is.
      {orphan, 0} = System.cmd("sh", ["-c", "#{fake} >/dev/null 2>&1 & echo $!"])
      orphan = String.trim(orphan)
      port = Port.open({:spawn_executable, fake}, [])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("kill", ["-9", orphan, "#{os_pid}"], stderr_to_stdout: true)
      end)

      opts =
        name |> toggle_opts(tmp, os_exit_timeout_ms: 100) |> Keyword.delete(:live_daemons_fun)

      File.write!(opts[:socket_path], "")
      {_, 0} = System.cmd("kill", ["-0", orphan])

      assert {:error, {:still_running, :bluetoothd}} = Bluetooth.stop(opts)
      assert File.exists?(opts[:socket_path])

      {_, 0} = System.cmd("kill", ["-9", "#{os_pid}"])
      assert :ok = Bluetooth.stop(Keyword.put(opts, :os_exit_timeout_ms, 2_000))
      refute File.exists?(opts[:socket_path])
      {_, 0} = System.cmd("kill", ["-0", orphan])
    end

    test "a start during the exit wait is refused, so the stop never unlinks its socket",
         %{tmp_dir: tmp} = ctx do
      socket = Path.join(tmp, "system_bus_socket")
      name = start_tree(ctx, all_ids(), fn -> File.write!(socket, "") end)
      test = self()
      up = :atomics.new(1, [])
      :atomics.put(up, 1, 1)

      alive = fn _os_pid ->
        send(test, :waiting)
        :atomics.get(up, 1) == 1
      end

      stopper =
        Task.async(fn -> Bluetooth.stop(toggle_opts(name, tmp, proc_alive_fun: alive)) end)

      assert_receive :waiting
      _ = received()

      assert {:error, :busy} =
               Task.async(fn -> Bluetooth.start(server: name, lock_retries: 0) end)
               |> Task.await()

      refute_received :prepared
      :atomics.put(up, 1, 0)
      assert :ok = Task.await(stopper)
      refute File.exists?(socket)

      assert :ok = Bluetooth.start(server: name)
      assert_received :prepared
      assert File.exists?(socket)
    end

    test "is idempotent", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      opts = toggle_opts(name, tmp)

      :ok = Bluetooth.stop(opts)
      _ = received()
      assert :ok = Bluetooth.stop(opts)
      assert received() == []
    end

    test "lists every started, starting or unanswering host_dbus app, sorted, and stops nothing",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)

      apps = [
        app("core_matter_server", true, :started),
        app("ssh", true, :unknown),
        app("booting", true, :startup),
        app("no_bus", false, :started)
      ]

      assert {:error, {:in_use, ["booting", "core_matter_server", "ssh"]}} =
               Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> apps end))

      assert received() == []
      assert Bluetooth.status(server: name) == :running
    end

    test "an error-state host_dbus app whose container still runs blocks",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      apps = [app("probe_failed", true, :error, true), app("exited", true, :error)]

      assert {:error, {:in_use, ["probe_failed"]}} =
               Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> apps end))

      assert Bluetooth.status(server: name) == :running
    end

    test "a stopped or crashed host_dbus app does not block", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      apps = [app("core_matter_server", true, :stopped), app("crashed", true, :error)]

      assert :ok = Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> apps end))
      assert Bluetooth.status(server: name) == :stopped
    end

    test "an already-stopped stack answers :ok even while a host_dbus app runs",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      :ok = Bluetooth.stop(toggle_opts(name, tmp))
      _ = received()
      apps = [app("core_matter_server", true, :started)]

      assert :ok = Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> apps end))
    end

    test "a failing app listing is an error, not a crash, and stops nothing",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)

      assert {:error, {:apps, %RuntimeError{}}} =
               Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> raise "boom" end))

      assert {:error, {:apps, :timeout}} =
               Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> exit(:timeout) end))

      assert received() == []
      assert Bluetooth.status(server: name) == :running
    end

    test "an already-reaped Improv tail does not block it", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      :ok = Vagus.Improv.Reaper.reap(stack_name(name))
      _ = received()

      assert :ok = Bluetooth.stop(toggle_opts(name, tmp))

      # The Recorder Reaper does not stop itself after reaping as the real one does.
      assert received() ==
               (daemon_ids() ++ [Vagus.Improv.Reaper])
               |> Enum.reverse()
               |> Enum.map(&{:stopped, &1})
    end
  end

  describe "start/1" do
    @describetag :tmp_dir

    test "restores the stack in boot order, Improv tail included, preparing the runtime first",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      opts = toggle_opts(name, tmp)
      :ok = Vagus.Improv.Reaper.reap(stack_name(name))
      :ok = Bluetooth.stop(opts)
      _ = received()

      assert :ok = Bluetooth.start(opts)
      assert received() == [:prepared | Enum.map(all_ids(), &{:started, &1})]
      assert Bluetooth.status(server: name) == :running
    end

    test "is idempotent and leaves a running stack's runtime alone", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx)
      opts = toggle_opts(name, tmp)

      assert :ok = Bluetooth.start(opts)
      assert received() == []

      :ok = Bluetooth.stop(opts)
      :ok = Bluetooth.start(opts)
      _ = received()
      assert :ok = Bluetooth.start(opts)
      assert received() == []
    end
  end

  describe "a stack the supervisor is retrying" do
    defmodule RestartingSupervisor do
      @moduledoc false
      # Answers the supervisor protocol as a parent whose Stack restart failed
      # and is being retried — not reachable deterministically with a real one.
      use GenServer

      def start_link(_), do: GenServer.start_link(__MODULE__, nil)

      @impl GenServer
      def init(nil), do: {:ok, nil}

      @impl GenServer
      def handle_call(:which_children, _from, state),
        do:
          {:reply, [{Vagus.Bluetooth.Stack, :restarting, :supervisor, [Vagus.Bluetooth.Stack]}],
           state}

      def handle_call({:restart_child, Vagus.Bluetooth.Stack}, _from, state),
        do: {:reply, {:error, :restarting}, state}
    end

    test "reads as running and refuses start as busy" do
      server = start_supervised!(RestartingSupervisor)

      assert Bluetooth.status(server: server) == :running
      assert {:error, :busy} = Bluetooth.start(server: server)
    end
  end

  describe "without a supervisor" do
    @describetag :tmp_dir

    test "every call is :absent", %{tmp_dir: tmp} do
      opts = toggle_opts(Module.concat(__MODULE__, NotStarted), tmp)

      assert Bluetooth.status(opts) == :absent
      assert {:error, :absent} = Bluetooth.stop(opts)
      assert {:error, :absent} = Bluetooth.start(opts)
    end
  end

  defp polled do
    receive do
      {:polled, os_pid, socket?} -> [{os_pid, socket?} | polled()]
    after
      0 -> []
    end
  end
end

defmodule Vagus.BluetoothOrchestratorTest do
  # async: false — sets the global `:orchestrator_app` env.
  use ExUnit.Case, async: false

  import Vagus.BluetoothTest.Harness

  @moduletag :tmp_dir

  setup do
    prev = Application.get_env(:vagus, :orchestrator_app)
    Application.put_env(:vagus, :orchestrator_app, "agent_orchestrator")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:vagus, :orchestrator_app, prev),
        else: Application.delete_env(:vagus, :orchestrator_app)
    end)
  end

  test "the orchestrator's own host_dbus bind does not block stop", %{tmp_dir: tmp} = ctx do
    name = start_tree(ctx)
    apps = [app("agent_orchestrator", true, :started)]

    assert :ok = Vagus.Bluetooth.stop(toggle_opts(name, tmp, apps_fun: fn -> apps end))
    assert Vagus.Bluetooth.status(server: name) == :stopped
  end
end
