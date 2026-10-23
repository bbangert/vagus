defmodule Vagus.DevicesTest do
  use ExUnit.Case, async: true

  import Vagus.DevicesFixtures

  alias Vagus.Devices

  setup do
    ctx = "devices" |> tmp_root() |> bench()
    on_exit(fn -> File.rm_rf(ctx.root) end)
    Map.put(ctx, :opts, opts(ctx))
  end

  defp dev(ctx, rel), do: Path.join(ctx.dev_root, rel)

  test "lists USB devices by port id, skipping hubs and interfaces, then header buses", ctx do
    assert Enum.map(Devices.list(ctx.opts), & &1.id) ==
             ["usb:1-1.2", "usb:1-1.3", "usb:2-1", "sys:i2c-1"]
  end

  test "a USB device carries its identity and the nodes its drivers made", ctx do
    {:ok, ftdi} = Devices.find("usb:1-1.2", ctx.opts)

    assert %{
             kind: :usb,
             vid: "0403",
             pid: "6001",
             vid_pid: "0403:6001",
             serial: "A10K1234",
             manufacturer: "FTDI",
             product: "FT232R USB UART",
             busnum: 1,
             devnum: 5,
             ifaces: [],
             hci: []
           } = ftdi

    assert ftdi.nodes == [
             %{path: dev(ctx, "bus/usb/001/005"), major: 189, minor: 4, class: :usb},
             %{path: dev(ctx, "ttyUSB0"), major: 188, minor: 0, class: :tty}
           ]
  end

  # The tty and hci sit under the hub too; they belong to the deeper device.
  test "network interfaces and Bluetooth controllers go to the device under them", ctx do
    devices = Map.new(Devices.list(ctx.opts), &{&1.id, &1})

    assert devices["usb:1-1.3"].hci == ["hci1"]
    assert devices["usb:1-1.3"].serial == nil
    assert devices["usb:2-1"].ifaces == ["eth1"]
    assert devices["usb:2-1"].vid_pid == "0b95:1790"
    refute Enum.any?(Map.values(devices), &("eth0" in &1.ifaces))
  end

  test "a header bus is a sys entry with its node", ctx do
    {:ok, i2c} = Devices.find("sys:i2c-1", ctx.opts)

    assert %{kind: :sys, vid: nil, serial: nil, ifaces: [], hci: []} = i2c
    assert i2c.nodes == [%{path: dev(ctx, "i2c-1"), major: 89, minor: 1, class: :i2c}]
  end

  test "find/2 by id, node path, serial and vid:pid all land on the same device", ctx do
    for key <- ["usb:1-1.2", dev(ctx, "ttyUSB0"), "A10K1234", "0403:6001", "0403:6001"] do
      assert {:ok, %{id: "usb:1-1.2"}} = Devices.find(key, ctx.opts), key
    end

    assert {:ok, %{id: "usb:2-1"}} = Devices.find("0B95:1790", ctx.opts)
    assert {:error, :not_found} = Devices.find("dead:beef", ctx.opts)
    assert {:error, :not_found} = Devices.find(dev(ctx, "ttyS0"), ctx.opts)
  end

  test "two identical cables are ambiguous rather than a guess", ctx do
    ftdi(ctx, "1-1.4", %{"serial" => "B20K5678", "devnum" => "7", "dev" => "189:6"}, "ttyUSB1")

    assert {:error, {:ambiguous, ["usb:1-1.2", "usb:1-1.4"]}} =
             Devices.find("0403:6001", ctx.opts)

    assert {:ok, %{id: "usb:1-1.4"}} = Devices.find("B20K5678", ctx.opts)
  end

  test "devices_args/1 passes every node", ctx do
    {:ok, ftdi} = Devices.find("A10K1234", ctx.opts)

    assert Devices.devices_args(ftdi) ==
             ["--device", dev(ctx, "bus/usb/001/005"), "--device", dev(ctx, "ttyUSB0")]

    {:ok, bt} = Devices.find("usb:1-1.3", ctx.opts)
    assert Devices.devices_args(bt) == ["--device", dev(ctx, "bus/usb/001/006")]
  end

  test "major_minor/2 answers listed nodes and any other class node", ctx do
    assert Devices.major_minor(dev(ctx, "ttyUSB0"), ctx.opts) == {:ok, {188, 0}}
    assert Devices.major_minor(dev(ctx, "bus/usb/002/002"), ctx.opts) == {:ok, {189, 129}}
    assert Devices.major_minor(dev(ctx, "ttyS0"), ctx.opts) == {:ok, {4, 64}}
    assert Devices.major_minor(dev(ctx, "nope"), ctx.opts) == {:error, :not_found}
  end

  test "usb_id/1 names devices only" do
    assert Devices.usb_id("1-1.2") == "usb:1-1.2"
    assert Devices.usb_id("3-1.4.2") == "usb:3-1.4.2"
    assert Devices.usb_id("usb1") == nil
    assert Devices.usb_id("1-1.2:1.0") == nil
  end

  test "an absent sysfs is an empty inventory" do
    assert Devices.list(sysfs_root: "/nonexistent/sys") == []
  end
end
