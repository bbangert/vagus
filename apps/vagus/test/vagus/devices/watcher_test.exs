defmodule Vagus.Devices.WatcherTest do
  use ExUnit.Case, async: true

  import Vagus.DevicesFixtures

  alias Vagus.Devices.Watcher

  setup do
    ctx = "watcher" |> tmp_root() |> bench()
    remove_ftdi(ctx)
    on_exit(fn -> File.rm_rf(ctx.root) end)

    table = :"uevents_#{System.unique_integer([:positive])}"
    start_supervised!({PropertyTable, name: table})
    name = :"watcher_#{System.unique_integer([:positive])}"
    ctx = Map.merge(ctx, %{table: table, watcher: name})

    start_watcher(ctx)
    ctx
  end

  # Every settle timer is handed to the test instead of being armed, so a
  # test fires each one (or a stale one) exactly when the scenario needs it.
  defp start_watcher(ctx) do
    test = self()

    send_after = fn dest, msg, _ms ->
      send(test, {:armed, dest, msg})
      make_ref()
    end

    start_supervised!(
      {Watcher, [name: ctx.watcher, table: ctx.table, send_after: send_after] ++ opts(ctx)},
      id: :watcher
    )

    :ok = Watcher.subscribe(ctx.watcher)
  end

  defp put(ctx, path, value), do: PropertyTable.put(ctx.table, path, value)

  defp armed(path, timeout \\ 100) do
    assert_receive {:armed, dest, {:settled, ^path, _token} = msg}, timeout
    {dest, msg}
  end

  defp fire({dest, msg}), do: send(dest, msg)

  defp device_props, do: %{"subsystem" => "usb", "devtype" => "usb_device", "busnum" => "001"}

  defp hub_path, do: Enum.drop(uevent_path("1-1.2"), -1)

  defp tty_path(port), do: uevent_path(port) ++ ["#{port}:1.0", "ttyUSB0", "tty", "ttyUSB0"]

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never held")

      true ->
        receive do
        after
          20 -> eventually(fun, deadline)
        end
    end
  end

  defp registrations(ctx) do
    ctx.table
    |> PropertyTable.Supervisor.registry_name()
    |> Registry.lookup(:subscriptions)
    |> Enum.count(fn {pid, _} -> pid == Process.whereis(ctx.watcher) end)
  catch
    :error, %ArgumentError{} -> 0
  end

  test "a plug's burst of uevents is one :added once its drivers are done", ctx do
    path = uevent_path("1-1.2")
    ftdi(ctx)
    File.rm!(Path.join(ctx.sysfs_root, "class/tty/ttyUSB0"))

    put(ctx, path, device_props())
    first = armed(path)
    put(ctx, path ++ ["1-1.2:1.0"], %{"subsystem" => "usb", "devtype" => "usb_interface"})
    rearmed = armed(path)

    # The device uevent's own deadline: only the re-arm on the interface
    # keeps it from being announced without its tty.
    fire(first)
    refute_receive {:device, _, _}, 50

    ftdi_tty(ctx)
    put(ctx, tty_path("1-1.2"), %{"subsystem" => "tty"})
    fire(rearmed)
    refute_receive {:device, _, _}, 50
    fire(armed(path))

    assert_receive {:device, :added, %{id: "usb:1-1.2"} = device}
    assert Enum.map(device.nodes, & &1.class) == [:usb, :tty]

    remove_ftdi(ctx)
    PropertyTable.delete(ctx.table, tty_path("1-1.2"))
    PropertyTable.delete(ctx.table, path ++ ["1-1.2:1.0"])
    PropertyTable.delete(ctx.table, path)

    assert_receive {:device, :removed, "usb:1-1.2"}
    refute_receive {:device, _, _}, 50
  end

  test "a device behind a hub plugged with it waits for its own tty", ctx do
    hub = hub_path()
    path = uevent_path("1-1.2")
    ftdi(ctx)
    File.rm!(Path.join(ctx.sysfs_root, "class/tty/ttyUSB0"))

    put(ctx, hub, device_props())
    hub_timer = armed(hub)
    put(ctx, path, device_props())
    device_timer = armed(path)

    put(ctx, path ++ ["1-1.2:1.0"], %{"subsystem" => "usb", "devtype" => "usb_interface"})
    hub_timer2 = armed(hub)
    device_rearmed = armed(path)

    fire(hub_timer)
    fire(hub_timer2)
    fire(device_timer)
    refute_receive {:device, _, _}, 50

    ftdi_tty(ctx)
    put(ctx, tty_path("1-1.2"), %{"subsystem" => "tty"})
    fire(device_rearmed)
    refute_receive {:device, _, _}, 50
    fire(armed(path))

    assert_receive {:device, :added, %{id: "usb:1-1.2"} = device}
    assert Enum.map(device.nodes, & &1.class) == [:usb, :tty]
    refute_receive {:device, _, _}, 50
  end

  test "a device present at start is announced on removal, not again on a replay", ctx do
    ftdi(ctx)
    stop_supervised!(:watcher)
    start_watcher(ctx)

    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))
    refute_receive {:device, _, _}, 50

    PropertyTable.delete(ctx.table, uevent_path("1-1.2"))
    assert_receive {:device, :removed, "usb:1-1.2"}
  end

  test "hubs and root hubs are never announced", ctx do
    ftdi(ctx)
    put(ctx, Enum.drop(hub_path(), -1), device_props())
    put(ctx, hub_path(), device_props())
    fire(armed(hub_path()))
    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))

    # The cable behind the hub proves the hub's uevents were heard.
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}
    PropertyTable.delete(ctx.table, hub_path())
    refute_receive {:device, _, _}, 50
  end

  test "a device gone before it settled produces nothing", ctx do
    put(ctx, uevent_path("1-1.2"), device_props())
    timer = armed(uevent_path("1-1.2"))
    PropertyTable.delete(ctx.table, uevent_path("1-1.2"))
    fire(timer)
    refute_receive {:device, _, _}, 50
  end

  test "a restarted table is re-subscribed once and what changed meanwhile announced", ctx do
    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}

    remove_ftdi(ctx)
    # Killed, so its :DOWN comes before its registry partition's exit; the
    # test supervisor starts it again.
    Process.exit(GenServer.whereis(ctx.table), :kill)

    assert_receive {:device, :removed, "usb:1-1.2"}, 3_000

    # The :DOWN and the exit both say the subscription is gone; acting on
    # each would register twice.
    refute_receive {:device, _, _}, 1_200
    assert registrations(ctx) == 1

    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))
    refute_receive {:armed, _, _}, 50
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}
    refute_receive {:device, _, _}, 50
  end

  # The table keeps its contents; only the subscription goes.
  defp kill_partition(ctx) do
    registry = PropertyTable.Supervisor.registry_name(ctx.table)
    [{_, partition, _, _}] = Supervisor.which_children(registry)
    ref = Process.monitor(partition)
    Process.exit(partition, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert Process.alive?(GenServer.whereis(ctx.table))
  end

  test "a restart of the table's registry alone is re-subscribed", ctx do
    kill_partition(ctx)

    eventually(fn -> registrations(ctx) == 1 end)
    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}
  end

  test "a device re-plugged on its port while unsubscribed is removed, then added anew", ctx do
    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))
    assert_receive {:device, :added, %{id: "usb:1-1.2", devnum: 5}}

    # Same port, so the same id; the kernel numbered it and its tty anew.
    remove_ftdi(ctx)
    ftdi(ctx, "1-1.2", %{"devnum" => "6"}, "ttyUSB1")
    kill_partition(ctx)

    assert_receive {:device, :removed, "usb:1-1.2"}, 3_000
    fire(armed(uevent_path("1-1.2")))
    assert_receive {:device, :added, %{id: "usb:1-1.2", devnum: 6} = device}
    assert Enum.any?(device.nodes, &(&1.class == :tty and Path.basename(&1.path) == "ttyUSB1"))
    refute_receive {:device, _, _}, 50
  end

  test "a device that arrived while unsubscribed settles before it is announced", ctx do
    ftdi(ctx)
    File.rm!(Path.join(ctx.sysfs_root, "class/tty/ttyUSB0"))
    kill_partition(ctx)

    first = armed(uevent_path("1-1.2"), 3_000)
    refute_received {:device, _, _}

    ftdi_tty(ctx)
    put(ctx, tty_path("1-1.2"), %{"subsystem" => "tty"})
    rearmed = armed(uevent_path("1-1.2"))
    fire(first)
    refute_receive {:device, _, _}, 50

    fire(rearmed)
    assert_receive {:device, :added, %{id: "usb:1-1.2"} = device}
    assert Enum.map(device.nodes, & &1.class) == [:usb, :tty]
    refute_receive {:device, _, _}, 50
  end

  test "a settle timer firing while unsubscribed announces nothing until the resync", ctx do
    path = uevent_path("1-1.2")
    ftdi(ctx)
    File.rm!(Path.join(ctx.sysfs_root, "class/tty/ttyUSB0"))
    put(ctx, path, device_props())
    stale = armed(path)

    kill_partition(ctx)
    eventually(fn -> :sys.get_state(ctx.watcher).table_ref == nil end)
    ftdi_tty(ctx)
    fire(stale)
    refute_receive {:device, _, _}, 50

    fresh = armed(path, 3_000)
    fire(fresh)
    assert_receive {:device, :added, %{id: "usb:1-1.2"} = device}
    assert Enum.map(device.nodes, & &1.class) == [:usb, :tty]
    refute_receive {:device, _, _}, 50
  end

  test "a table found without its registry at start is retried", ctx do
    stop_supervised!(:watcher)
    stop_supervised!(ctx.table)
    # A registered name with no registry behind it, as while the table's
    # supervisor is still starting its children.
    holder = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(holder, ctx.table)

    start_watcher(ctx)
    assert :sys.get_state(ctx.watcher).table_ref == nil

    Process.exit(holder, :kill)
    eventually(fn -> Process.whereis(ctx.table) == nil end)
    start_supervised!({PropertyTable, name: ctx.table})

    eventually(fn -> registrations(ctx) == 1 end)
    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    fire(armed(uevent_path("1-1.2")))
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}
  end

  test "an exited subscriber is dropped", ctx do
    subscriber = spawn(fn -> Watcher.subscribe(ctx.watcher) end)
    ref = Process.monitor(subscriber)
    assert_receive {:DOWN, ^ref, :process, _, _}

    eventually(fn ->
      not Map.has_key?(:sys.get_state(ctx.watcher).subscribers, subscriber)
    end)
  end

  test "no uevent table means no watcher" do
    assert Watcher.start_link(name: :watcher_without_table, table: :no_such_table) == :ignore
  end
end
