defmodule Vagus.Backend.Host.HardwareTest do
  use ExUnit.Case, async: true

  alias Vagus.Backend.Host.Hardware

  setup do
    root =
      Path.join(System.tmp_dir!(), "vagus_hardware_#{System.unique_integer([:positive])}")

    sys_class = Path.join(root, "sys/class")
    dev_root = Path.join(root, "dev")
    File.mkdir_p!(sys_class)
    File.mkdir_p!(dev_root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, sys_class: sys_class, dev_root: dev_root}
  end

  # Builds a /sys/class/<subsystem>/<name> symlink → a devices dir with the
  # given uevent contents — the same layout the kernel exports.
  defp add_device(%{root: root, sys_class: sys_class}, subsystem, name, uevent) do
    devices_dir = Path.join([root, "sys/devices/platform", subsystem, name])
    File.mkdir_p!(devices_dir)
    File.write!(Path.join(devices_dir, "uevent"), uevent)

    class_dir = Path.join(sys_class, subsystem)
    File.mkdir_p!(class_dir)
    # Relative symlink, like the real sysfs.
    relative = Path.relative_to(devices_dir, class_dir)
    File.ln_s!(relative, Path.join(class_dir, name))
    devices_dir
  end

  test "enumerates class entries with canonical sysfs, subsystem, and uevent attributes",
       ctx do
    devices_dir =
      add_device(ctx, "tty", "ttyAMA0", "MAJOR=204\nMINOR=64\nDEVNAME=ttyAMA0\n")

    %{devices: [device], drives: []} =
      Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    assert device.name == "ttyAMA0"
    assert device.subsystem == "tty"
    assert device.sysfs == devices_dir
    assert device.by_id == nil
    assert device.children == []
    assert device.attributes == %{"MAJOR" => "204", "MINOR" => "64", "DEVNAME" => "ttyAMA0"}
  end

  test "dev_path comes from DEVNAME (covers nested nodes like input/event0)", ctx do
    add_device(ctx, "input", "event0", "MAJOR=13\nMINOR=64\nDEVNAME=input/event0\n")

    %{devices: [device]} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    assert device.dev_path == Path.join(ctx.dev_root, "input/event0")
  end

  test "malformed uevent lines are dropped; well-formed ones still parse", ctx do
    add_device(
      ctx,
      "misc",
      "weird",
      "GOOD=value\nno-equals-line\nALSO_GOOD=a=b\nDEVNAME=weird\n\n"
    )

    %{devices: [device]} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    # parts: 2 keeps everything after the first "=" intact.
    assert device.attributes == %{
             "GOOD" => "value",
             "ALSO_GOOD" => "a=b",
             "DEVNAME" => "weird"
           }
  end

  test "a device without DEVNAME gets a dev_path only when the node exists", ctx do
    add_device(ctx, "net", "eth0", "INTERFACE=eth0\nIFINDEX=2\n")
    add_device(ctx, "block", "mmcblk0", "")
    File.touch!(Path.join(ctx.dev_root, "mmcblk0"))

    %{devices: devices} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)
    by_name = Map.new(devices, &{&1.name, &1})

    # eth0 has no DEVNAME and no /dev/eth0 node, so dev_path is nil — and
    # the dev_path filter drops it before it ever reaches by_name.
    refute Map.has_key?(by_name, "eth0")
    assert by_name["mmcblk0"].dev_path == Path.join(ctx.dev_root, "mmcblk0")
    # Empty/absent uevent parses to an empty attribute map, not a crash.
    assert by_name["mmcblk0"].attributes == %{}
  end

  test "a device with no DEVNAME and no /dev node is dropped", ctx do
    add_device(ctx, "platform", "orphan", "SOMETHING=else\n")

    %{devices: devices} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    refute Enum.any?(devices, &(&1.name == "orphan"))
  end

  # A virtual tty (like the udev-hidden ptmx pairs) resolves under
  # .../devices/virtual/tty/... and DOES have a real /dev node — proving
  # it's the sysfs-path filter, not the dev_path filter, dropping it.
  defp add_virtual_device(%{root: root, sys_class: sys_class}, subsystem, kind, name, uevent) do
    devices_dir = Path.join([root, "sys/devices/virtual", kind, name])
    File.mkdir_p!(devices_dir)
    File.write!(Path.join(devices_dir, "uevent"), uevent)

    class_dir = Path.join(sys_class, subsystem)
    File.mkdir_p!(class_dir)
    relative = Path.relative_to(devices_dir, class_dir)
    File.ln_s!(relative, Path.join(class_dir, name))
    devices_dir
  end

  test "a virtual tty device is dropped even though it has a /dev node", ctx do
    add_virtual_device(ctx, "tty", "tty", "tty5", "DEVNAME=tty5\n")
    File.mkdir_p!(ctx.dev_root)
    File.touch!(Path.join(ctx.dev_root, "tty5"))

    %{devices: devices} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    refute Enum.any?(devices, &(&1.name == "tty5"))
  end

  test "a virtual device outside tty|block|vc (e.g. net) is kept", ctx do
    add_virtual_device(ctx, "net", "net", "lo", "DEVNAME=lo\nINTERFACE=lo\n")
    File.mkdir_p!(ctx.dev_root)
    File.touch!(Path.join(ctx.dev_root, "lo"))

    %{devices: devices} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    assert Enum.any?(devices, &(&1.name == "lo"))
  end

  test "devices are sorted by subsystem then name; missing sys_class is empty", ctx do
    add_device(ctx, "tty", "ttyS1", "DEVNAME=ttyS1\n")
    add_device(ctx, "tty", "ttyS0", "DEVNAME=ttyS0\n")
    add_device(ctx, "block", "sda", "DEVNAME=sda\n")

    %{devices: devices} = Hardware.info(sys_class: ctx.sys_class, dev_root: ctx.dev_root)

    assert Enum.map(devices, &{&1.subsystem, &1.name}) ==
             [{"block", "sda"}, {"tty", "ttyS0"}, {"tty", "ttyS1"}]

    assert Hardware.info(sys_class: "/nonexistent/sys/class", dev_root: ctx.dev_root) ==
             %{devices: [], drives: []}
  end
end
