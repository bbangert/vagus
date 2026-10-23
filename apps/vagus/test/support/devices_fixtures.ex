defmodule Vagus.DevicesFixtures do
  @moduledoc """
  A fake sysfs laid out the way the kernel exports it: devices under
  `devices/`, reached through relative symlinks from `bus/usb/devices` and
  `class/<subsystem>`.

  `bench/1` builds a board with a hub on bus 1 carrying an FTDI cable
  (`1-1.2`, ttyUSB0) and a Bluetooth dongle (`1-1.3`, hci1), an AX88179 on
  bus 2 (`2-1`, eth1), an onboard UART and NIC no USB device owns, and
  `i2c-1` on the SoC.
  """

  @xhci "devices/platform/soc/xhci"

  def tmp_root(tag) do
    root = Path.join(System.tmp_dir!(), "vagus_#{tag}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sys"))
    File.mkdir_p!(Path.join(root, "dev"))
    %{root: root, sysfs_root: Path.join(root, "sys"), dev_root: Path.join(root, "dev")}
  end

  def opts(%{sysfs_root: sysfs_root, dev_root: dev_root}),
    do: [sysfs_root: sysfs_root, dev_root: dev_root]

  def bench(ctx) do
    usb(ctx, "usb1", "#{@xhci}/usb1", %{"bDeviceClass" => "09", "busnum" => "1", "devnum" => "1"})
    usb(ctx, "usb2", "#{@xhci}/usb2", %{"bDeviceClass" => "09", "busnum" => "2", "devnum" => "1"})

    usb(ctx, "1-1", "#{@xhci}/usb1/1-1", %{
      "bDeviceClass" => "09",
      "idVendor" => "05e3",
      "idProduct" => "0610",
      "busnum" => "1",
      "devnum" => "2",
      "dev" => "189:1"
    })

    ftdi(ctx)

    usb(ctx, "1-1.3", "#{@xhci}/usb1/1-1/1-1.3", %{
      "bDeviceClass" => "e0",
      "idVendor" => "0a12",
      "idProduct" => "0001",
      "busnum" => "1",
      "devnum" => "6",
      "dev" => "189:5"
    })

    class(ctx, "bluetooth", "hci1", "#{@xhci}/usb1/1-1/1-1.3/1-1.3:1.0/bluetooth/hci1", %{})

    usb(ctx, "2-1", "#{@xhci}/usb2/2-1", %{
      "bDeviceClass" => "ff",
      "idVendor" => "0B95",
      "idProduct" => "1790",
      "serial" => "0000249B",
      "manufacturer" => "ASIX",
      "product" => "AX88179",
      "busnum" => "2",
      "devnum" => "2",
      "dev" => "189:129"
    })

    class(ctx, "net", "eth1", "#{@xhci}/usb2/2-1/2-1:1.0/net/eth1", %{})
    class(ctx, "net", "eth0", "devices/platform/soc/ethernet/net/eth0", %{})
    class(ctx, "tty", "ttyS0", "devices/platform/soc/serial/tty/ttyS0", %{"dev" => "4:64"})

    class(ctx, "i2c-dev", "i2c-1", "devices/platform/soc/fe804000.i2c/i2c-1/i2c-dev/i2c-1", %{
      "dev" => "89:1"
    })

    ctx
  end

  def ftdi(ctx, port \\ "1-1.2", attrs \\ %{}, tty \\ "ttyUSB0") do
    dir = "#{@xhci}/usb1/1-1/#{port}"

    usb(
      ctx,
      port,
      dir,
      Map.merge(
        %{
          "bDeviceClass" => "00",
          "idVendor" => "0403",
          "idProduct" => "6001",
          "serial" => "A10K1234",
          "manufacturer" => "FTDI",
          "product" => "FT232R USB UART",
          "busnum" => "1",
          "devnum" => "5",
          "dev" => "189:4"
        },
        attrs
      )
    )

    interface(ctx, "#{port}:1.0", "#{dir}/#{port}:1.0")
    ftdi_tty(ctx, port, tty)
  end

  def ftdi_tty(ctx, port \\ "1-1.2", tty \\ "ttyUSB0") do
    class(ctx, "tty", tty, "#{@xhci}/usb1/1-1/#{port}/#{port}:1.0/#{tty}/tty/#{tty}", %{
      "dev" => "188:0"
    })
  end

  def remove_ftdi(%{sysfs_root: sysfs_root}, port \\ "1-1.2", tty \\ "ttyUSB0") do
    File.rm_rf!(Path.join(sysfs_root, "#{@xhci}/usb1/1-1/#{port}"))
    File.rm!(Path.join(sysfs_root, "bus/usb/devices/#{port}"))
    File.rm!(Path.join(sysfs_root, "bus/usb/devices/#{port}:1.0"))
    File.rm!(Path.join(sysfs_root, "class/tty/#{tty}"))
  end

  # The uevent path NervesUEvent reports for a device under the hub.
  def uevent_path(port), do: String.split("#{@xhci}/usb1/1-1/#{port}", "/")

  defp usb(ctx, name, dir, attrs) do
    path = device_dir(ctx, dir, attrs)
    link(ctx, "bus/usb/devices", name, path)
  end

  defp interface(ctx, name, dir) do
    path = device_dir(ctx, dir, %{"bInterfaceClass" => "ff"})
    link(ctx, "bus/usb/devices", name, path)
  end

  defp class(ctx, subsystem, name, dir, attrs) do
    uevent = if Map.has_key?(attrs, "dev"), do: "DEVNAME=#{name}\n", else: "INTERFACE=#{name}\n"
    path = device_dir(ctx, dir, Map.put(attrs, "uevent", uevent))
    link(ctx, "class/#{subsystem}", name, path)
  end

  defp device_dir(%{sysfs_root: sysfs_root}, dir, attrs) do
    path = Path.join(sysfs_root, dir)
    File.mkdir_p!(path)
    for {file, value} <- attrs, do: File.write!(Path.join(path, file), value <> "\n")
    path
  end

  defp link(%{sysfs_root: sysfs_root}, dir, name, target) do
    from = Path.join(sysfs_root, dir)
    File.mkdir_p!(from)
    File.ln_s!(Path.relative_to(target, from, force: true), Path.join(from, name))
  end
end
