defmodule Vagus.BluetoothTest do
  # async: false — the orchestrator-exemption test sets the global
  # `:orchestrator_app` env.
  use ExUnit.Case, async: false

  # Child-order/slice tests against the pure `Bluez.children/1` list — no
  # daemons, no D-Bus. Guards the load-bearing cut: everything up to and
  # including :bluetoothd, none of the client/audio stack (which would
  # compete with HA Core for the radio — see the moduledoc).
  describe "daemon_children/1" do
    test "ends at the :bluetoothd spec and includes the daemon prerequisites" do
      children = Vagus.Bluetooth.daemon_children()

      assert %{id: :bluetoothd} = List.last(children)
      assert Enum.any?(children, &match?(%{id: :dbus_daemon}, &1))
      # The socket gate between the two daemons.
      assert Bluez.BusReady in children
      # The rebus runtime the BusReady gate rides on.
      assert Enum.any?(children, &match?({Bluez.Rebus.SignalHandler, _}, &1))
    end

    test "excludes every client and audio child" do
      children = Vagus.Bluetooth.daemon_children()

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
      children = Vagus.Bluetooth.children()

      assert children ==
               Vagus.Bluetooth.daemon_children() ++
                 [Vagus.Improv.supervisor_child(), Vagus.Improv.Reaper]

      # Mounting contract: Improv rides LAST under :rest_for_one so a
      # bluetoothd restart rebuilds it, never the other way around.
      assert [{Improv.Supervisor, _opts}, Vagus.Improv.Reaper] = Enum.take(children, -2)
    end

    test "improv: false yields the bare daemon slice" do
      assert Vagus.Bluetooth.children(improv: false) ==
               Vagus.Bluetooth.daemon_children(improv: false)
    end
  end

  describe "start_link/1" do
    import ExUnit.CaptureLog

    test "returns :ignore when the daemon binaries are missing" do
      # capture_log contains the expected warning so it can't pollute a
      # concurrent test's log assertions (see the CaptureLog note in
      # the project memory: capture is process-wide under async tests).
      log =
        capture_log(fn ->
          assert :ignore =
                   Vagus.Bluetooth.start_link(
                     dbus_daemon_path: "/nonexistent/dbus-daemon",
                     bluetoothd_path: "/nonexistent/bluetoothd"
                   )
        end)

      assert log =~ "/nonexistent/dbus-daemon"
    end
  end

  defmodule Recorder do
    @moduledoc false
    # Stands in for a daemon/Improv child: reports its start and its
    # (trapped) shutdown so the tests see the order the supervisor used.
    use GenServer

    def start_link({id, test}), do: GenServer.start_link(__MODULE__, {id, test})

    @impl GenServer
    def init({id, test}) do
      Process.flag(:trap_exit, true)
      send(test, {:started, id})
      {:ok, {id, test}}
    end

    @impl GenServer
    def terminate(_reason, {id, test}), do: send(test, {:stopped, id})
  end

  @daemon_ids [:signal_handler, :dbus_daemon, Bluez.BusReady, :bluetoothd]
  @improv_ids [Improv.Supervisor, Vagus.Improv.Reaper]

  defp spec(id), do: %{id: id, start: {Recorder, :start_link, [{id, self()}]}}

  defp start_tree(ctx, ids) do
    name = Module.concat(__MODULE__, "Sup#{ctx.test |> :erlang.phash2()}")
    test = self()

    start_supervised!(
      {Vagus.Bluetooth,
       name: name,
       dbus_daemon_path: __ENV__.file,
       bluetoothd_path: __ENV__.file,
       prepare_runtime: fn -> send(test, :prepared) end,
       children: Enum.map(ids, &spec/1)}
    )

    for id <- ids, do: assert_receive({:started, ^id})
    assert_receive :prepared
    name
  end

  defp received do
    receive do
      {kind, id} when kind in [:started, :stopped] -> [{kind, id} | received()]
      :prepared -> [:prepared | received()]
    after
      50 -> []
    end
  end

  defp app(slug, host_dbus, state),
    do: %{
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

  defp toggle_opts(name, tmp, apps \\ []) do
    [
      server: name,
      socket_path: Path.join(tmp, "system_bus_socket"),
      apps_fun: fn -> apps end,
      prepare_runtime: fn -> send(self(), :prepared) end
    ]
  end

  describe "stop/1, start/1, status/1" do
    @describetag :tmp_dir

    test "stop drops the Improv tail then the daemons newest-first, removing the socket",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx, @daemon_ids ++ @improv_ids)
      opts = toggle_opts(name, tmp)
      File.write!(opts[:socket_path], "")
      assert Vagus.Bluetooth.status(server: name) == :running

      assert :ok = Vagus.Bluetooth.stop(opts)

      assert received() ==
               (@daemon_ids ++ @improv_ids) |> Enum.reverse() |> Enum.map(&{:stopped, &1})

      refute File.exists?(opts[:socket_path])
      assert Vagus.Bluetooth.status(server: name) == :stopped
      ids = name |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(ids) == Enum.sort(@daemon_ids)
    end

    test "start restores the daemon slice in order and positions, without Improv",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx, @daemon_ids ++ @improv_ids)
      opts = toggle_opts(name, tmp)
      :ok = Vagus.Bluetooth.stop(opts)
      _ = received()

      assert :ok = Vagus.Bluetooth.start(opts)
      assert received() == [:prepared | Enum.map(@daemon_ids, &{:started, &1})]
      assert Vagus.Bluetooth.status(server: name) == :running

      # Original positions, so :rest_for_one still cascades from dbus.
      ids = name |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
      assert ids == Enum.reverse(@daemon_ids)
    end

    test "double stop and double start are no-ops", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx, @daemon_ids ++ @improv_ids)
      opts = toggle_opts(name, tmp)

      assert :ok = Vagus.Bluetooth.start(opts)
      assert received() == []

      :ok = Vagus.Bluetooth.stop(opts)
      _ = received()
      assert :ok = Vagus.Bluetooth.stop(opts)
      assert received() == []

      :ok = Vagus.Bluetooth.start(opts)
      _ = received()
      assert :ok = Vagus.Bluetooth.start(opts)
      assert received() == []
    end

    test "an already-reaped Improv tail does not block stop", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx, @daemon_ids ++ @improv_ids)
      :ok = Vagus.Improv.Reaper.reap(name)
      _ = received()

      assert :ok = Vagus.Bluetooth.stop(toggle_opts(name, tmp))
      assert Vagus.Bluetooth.status(server: name) == :stopped
    end

    test "every call is :absent without a supervisor", %{tmp_dir: tmp} do
      opts = toggle_opts(Module.concat(__MODULE__, NotStarted), tmp)

      assert Vagus.Bluetooth.status(opts) == :absent
      assert {:error, :absent} = Vagus.Bluetooth.stop(opts)
      assert {:error, :absent} = Vagus.Bluetooth.start(opts)
    end
  end

  describe "stop/1 refusal" do
    @describetag :tmp_dir

    setup do
      prev = Application.get_env(:vagus, :orchestrator_app)
      Application.put_env(:vagus, :orchestrator_app, "agent_orchestrator")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:vagus, :orchestrator_app, prev),
          else: Application.delete_env(:vagus, :orchestrator_app)
      end)
    end

    test "lists every started or unanswering host_dbus app and stops nothing",
         %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx, @daemon_ids)

      apps = [
        app("core_matter_server", true, :started),
        app("ssh", true, :unknown),
        app("booting", true, :startup),
        app("no_bus", false, :started)
      ]

      assert {:error, {:in_use, ["booting", "core_matter_server", "ssh"]}} =
               Vagus.Bluetooth.stop(toggle_opts(name, tmp, apps))

      assert received() == []
      assert Vagus.Bluetooth.status(server: name) == :running
    end

    test "neither the orchestrator nor a stopped host_dbus app blocks", %{tmp_dir: tmp} = ctx do
      name = start_tree(ctx, @daemon_ids)

      apps = [
        app("agent_orchestrator", true, :started),
        app("core_matter_server", true, :stopped),
        app("crashed", true, :error)
      ]

      assert :ok = Vagus.Bluetooth.stop(toggle_opts(name, tmp, apps))
      assert Vagus.Bluetooth.status(server: name) == :stopped
    end
  end
end
