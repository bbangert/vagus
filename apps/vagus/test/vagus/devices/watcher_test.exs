defmodule Vagus.Devices.WatcherTest do
  use ExUnit.Case, async: true

  import Vagus.DevicesFixtures

  alias Vagus.Devices.Watcher

  @settle_ms 200

  setup do
    ctx = "watcher" |> tmp_root() |> bench()
    remove_ftdi(ctx)
    on_exit(fn -> File.rm_rf(ctx.root) end)

    table = :"uevents_#{System.unique_integer([:positive])}"
    start_supervised!({PropertyTable, name: table})
    name = :"watcher_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Watcher, [name: name, table: table, settle_ms: @settle_ms] ++ opts(ctx)},
      id: :watcher
    )

    :ok = Watcher.subscribe(name)
    Map.merge(ctx, %{table: table, watcher: name})
  end

  defp put(ctx, path, value), do: PropertyTable.put(ctx.table, path, value)

  defp device_props, do: %{"subsystem" => "usb", "devtype" => "usb_device", "busnum" => "001"}

  test "a plug's burst of uevents is one :added once its drivers are done", ctx do
    path = uevent_path("1-1.2")
    ftdi(ctx)
    File.rm!(Path.join(ctx.sysfs_root, "class/tty/ttyUSB0"))

    put(ctx, path, device_props())
    Process.sleep(div(@settle_ms * 3, 5))
    put(ctx, path ++ ["1-1.2:1.0"], %{"subsystem" => "usb", "devtype" => "usb_interface"})
    Process.sleep(div(@settle_ms * 3, 5))

    # Past the device uevent's own deadline: only the re-arm on the interface
    # uevent keeps it from being announced without its tty.
    ftdi_tty(ctx)
    put(ctx, path ++ ["1-1.2:1.0", "ttyUSB0", "tty", "ttyUSB0"], %{"subsystem" => "tty"})

    assert_receive {:device, :added, %{id: "usb:1-1.2"} = device}, @settle_ms * 3
    assert Enum.map(device.nodes, & &1.class) == [:usb, :tty]
    refute_receive {:device, _, _}, @settle_ms * 2

    remove_ftdi(ctx)
    PropertyTable.delete(ctx.table, path ++ ["1-1.2:1.0", "ttyUSB0", "tty", "ttyUSB0"])
    PropertyTable.delete(ctx.table, path ++ ["1-1.2:1.0"])
    PropertyTable.delete(ctx.table, path)

    assert_receive {:device, :removed, "usb:1-1.2"}
    refute_receive {:device, _, _}, @settle_ms
  end

  test "a device present at start is announced on removal", ctx do
    ftdi(ctx)
    stop_supervised!(:watcher)

    start_supervised!(
      {Watcher, [name: ctx.watcher, table: ctx.table] ++ opts(ctx)},
      id: :watcher
    )

    :ok = Watcher.subscribe(ctx.watcher)
    put(ctx, uevent_path("1-1.2"), device_props())
    PropertyTable.delete(ctx.table, uevent_path("1-1.2"))

    assert_receive {:device, :removed, "usb:1-1.2"}
  end

  test "hubs and root hubs are never announced", ctx do
    put(ctx, uevent_path("1-1") |> Enum.drop(-1), device_props())
    put(ctx, uevent_path("1-1"), device_props())
    PropertyTable.delete(ctx.table, uevent_path("1-1"))
    refute_receive {:device, _, _}, @settle_ms * 2
  end

  test "a device gone before it settled produces nothing", ctx do
    put(ctx, uevent_path("1-1.2"), device_props())
    PropertyTable.delete(ctx.table, uevent_path("1-1.2"))
    refute_receive {:device, _, _}, @settle_ms * 2
  end

  test "a restarted table is re-subscribed and what changed meanwhile announced", ctx do
    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}, @settle_ms * 3

    stop_supervised!(ctx.table)
    remove_ftdi(ctx)
    start_supervised!({PropertyTable, name: ctx.table})

    assert_receive {:device, :removed, "usb:1-1.2"}, 3_000

    ftdi(ctx)
    put(ctx, uevent_path("1-1.2"), device_props())
    assert_receive {:device, :added, %{id: "usb:1-1.2"}}, @settle_ms * 3
  end

  test "an exited subscriber is dropped", ctx do
    subscriber = spawn(fn -> Watcher.subscribe(ctx.watcher) end)
    ref = Process.monitor(subscriber)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert map_size(:sys.get_state(ctx.watcher).subscribers) == 1
  end

  test "no uevent table means no watcher" do
    assert Watcher.start_link(name: :watcher_without_table, table: :no_such_table) == :ignore
  end
end
