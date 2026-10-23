defmodule Vagus.USBIPTest do
  use ExUnit.Case, async: true

  alias Vagus.{DevicesFixtures, USBIP}
  alias Vagus.Test.FakePodman

  @run_argv [
    "run",
    "-d",
    "--rm",
    "--replace",
    "--name",
    "vagus-usbipd",
    "--privileged",
    "--network=host",
    "--entrypoint",
    "usbipd",
    "img:test"
  ]
  @stop_argv ["stop", "-t", "5", "--ignore", "vagus-usbipd"]

  setup do
    ctx = DevicesFixtures.tmp_root("usbip")
    on_exit(fn -> File.rm_rf!(ctx.root) end)
    DevicesFixtures.ftdi(ctx, "1-1.4", %{"serial" => "S14"}, "ttyUSB4")
    DevicesFixtures.ftdi(ctx, "1-1.5", %{"serial" => "S15"}, "ttyUSB5")

    for {driver, attrs} <- [
          {"usb", ["bind", "unbind"]},
          {"usbip-host", ["match_busid", "bind", "unbind", "rebind"]}
        ],
        attr <- attrs do
      File.mkdir_p!(sysfs(ctx, "bus/usb/drivers/#{driver}"))
      File.write!(sysfs(ctx, "bus/usb/drivers/#{driver}/#{attr}"), "")
    end

    File.write!(sysfs(ctx, "bus/usb/drivers_probe"), "")
    bind_driver(ctx, "1-1.4", "usb")
    bind_driver(ctx, "1-1.5", "usb")

    {:ok, ctx}
  end

  defp sysfs(ctx, rel), do: Path.join(ctx.sysfs_root, rel)
  defp read(ctx, rel), do: File.read!(sysfs(ctx, rel))

  # The kernel's side of a bind: the device's `driver` link.
  defp bind_driver(ctx, busid, driver) do
    link = sysfs(ctx, "bus/usb/devices/#{busid}/driver")
    File.rm(link)
    File.ln_s!(sysfs(ctx, "bus/usb/drivers/#{driver}"), link)
  end

  defp start(ctx, opts \\ []) do
    test = self()
    {podman_rules, opts} = Keyword.pop(opts, :podman_rules, [])

    fake =
      FakePodman.start(podman_rules ++ [{"run *", [{0, "cid\n"}]}, {"stop *", [{0, ""}]}])

    {cmd_result, opts} = Keyword.pop(opts, :modprobe, {"", 0})
    name = :"usbip_#{System.unique_integer([:positive])}"

    base = [
      name: name,
      enabled: true,
      sysfs_root: ctx.sysfs_root,
      image: "img:test",
      podman: [podman_bin: fake.bin],
      cmd: fn bin, args ->
        send(test, {:cmd, bin, args})
        cmd_result
      end,
      watcher: :"watcher_#{name}",
      subscribe: fn server -> send(test, {:subscribed, server}) end
    ]

    Process.register(self(), :"watcher_#{name}")
    pid = start_supervised!({USBIP, Keyword.merge(base, opts)})
    %{server: name, pid: pid, fake: fake}
  end

  test "share binds the device the way usbip bind does and starts usbipd", ctx do
    s = start(ctx)
    assert_receive {:subscribed, _}

    assert USBIP.share("usb:1-1.4", server: s.server) == :ok
    assert_received {:cmd, "modprobe", ["usbip-host"]}

    assert read(ctx, "bus/usb/drivers/usb/unbind") == "1-1.4"
    assert read(ctx, "bus/usb/drivers/usbip-host/match_busid") == "add 1-1.4"
    assert read(ctx, "bus/usb/drivers/usbip-host/bind") == "1-1.4"
    assert read(ctx, "bus/usb/drivers_probe") == ""
    assert FakePodman.verbs(s.fake) == [@run_argv]

    assert USBIP.shared(server: s.server) == [
             %{id: "usb:1-1.4", busid: "1-1.4", vid_pid: "0403:6001"}
           ]
  end

  test "a busid or any Devices key resolves; a second share is refused", ctx do
    s = start(ctx)
    assert USBIP.share("1-1.4", server: s.server) == :ok
    assert USBIP.share("usb:1-1.4", server: s.server) == {:error, :already_shared}
    assert USBIP.share("S15", server: s.server) == :ok

    assert USBIP.share("0403:6001", server: s.server) ==
             {:error, {:ambiguous, ["usb:1-1.4", "usb:1-1.5"]}}

    assert Enum.map(USBIP.shared(server: s.server), & &1.busid) == ["1-1.4", "1-1.5"]
    assert FakePodman.verbs(s.fake) == [@run_argv]
  end

  test "a device already on usbip-host is refused", ctx do
    bind_driver(ctx, "1-1.4", "usbip-host")
    s = start(ctx)
    assert USBIP.share("usb:1-1.4", server: s.server) == {:error, :already_shared}
  end

  test "unshare reverses it the way usbip unbind does; the last one stops usbipd", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    :ok = USBIP.share("usb:1-1.5", server: s.server)
    bind_driver(ctx, "1-1.4", "usbip-host")
    bind_driver(ctx, "1-1.5", "usbip-host")

    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok
    assert read(ctx, "bus/usb/drivers/usbip-host/unbind") == "1-1.4"
    assert read(ctx, "bus/usb/drivers/usbip-host/match_busid") == "del 1-1.4"
    assert read(ctx, "bus/usb/drivers/usbip-host/rebind") == "1-1.4"
    assert FakePodman.verbs(s.fake) == [@run_argv]

    assert USBIP.unshare("1-1.5", server: s.server) == :ok
    assert read(ctx, "bus/usb/drivers/usbip-host/rebind") == "1-1.5"
    assert FakePodman.verbs(s.fake) == [@run_argv, @stop_argv]
    assert USBIP.shared(server: s.server) == []

    bind_driver(ctx, "1-1.4", "usb")
    assert USBIP.unshare("usb:1-1.4", server: s.server) == {:error, :not_shared}
  end

  test "an unplugged device is forgotten and its match_busid entry dropped", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)

    send(s.pid, {:device, :removed, "usb:1-1.4"})
    assert USBIP.shared(server: s.server) == []
    assert read(ctx, "bus/usb/drivers/usbip-host/match_busid") == "del 1-1.4"
    assert FakePodman.verbs(s.fake) == [@run_argv, @stop_argv]
  end

  test "a failed bind rolls back match_busid, re-probes, and stops usbipd", ctx do
    bind = sysfs(ctx, "bus/usb/drivers/usbip-host/bind")
    File.rm!(bind)
    File.mkdir!(bind)
    s = start(ctx)

    assert USBIP.share("usb:1-1.4", server: s.server) == {:error, {:sysfs, bind, :enoent}}
    assert read(ctx, "bus/usb/drivers/usb/unbind") == "1-1.4"
    assert read(ctx, "bus/usb/drivers/usbip-host/match_busid") == "del 1-1.4"
    assert read(ctx, "bus/usb/drivers_probe") == "1-1.4"
    assert FakePodman.verbs(s.fake) == [@run_argv, @stop_argv]
    assert USBIP.shared(server: s.server) == []
  end

  test "a failed match_busid write re-probes the released device", ctx do
    File.rm!(sysfs(ctx, "bus/usb/drivers/usbip-host/match_busid"))
    s = start(ctx)

    assert {:error, {:sysfs, _, :enoent}} = USBIP.share("usb:1-1.4", server: s.server)
    assert read(ctx, "bus/usb/drivers/usb/unbind") == "1-1.4"
    assert read(ctx, "bus/usb/drivers/usbip-host/bind") == ""
    assert read(ctx, "bus/usb/drivers_probe") == "1-1.4"
  end

  test "an unknown device touches nothing", ctx do
    s = start(ctx)
    assert USBIP.share("usb:9-9", server: s.server) == {:error, :not_found}
    assert USBIP.share("nope", server: s.server) == {:error, :not_found}
    refute_received {:cmd, _, _}
    assert FakePodman.verbs(s.fake) == []
  end

  test "a busid that is not a port path is refused before any sysfs path is built", ctx do
    s = start(ctx)
    assert USBIP.share("../../etc", server: s.server) == {:error, :invalid_busid}
    assert USBIP.share("usb:../1-1.4", server: s.server) == {:error, :invalid_busid}
    assert USBIP.unshare("../../etc", server: s.server) == {:error, :invalid_busid}
    refute_received {:cmd, _, _}
    assert FakePodman.verbs(s.fake) == []

    for attr <- ["usb/unbind", "usbip-host/match_busid", "usbip-host/bind", "usbip-host/unbind"],
        do: assert(read(ctx, "bus/usb/drivers/#{attr}") == "")
  end

  test "a driver link that is not one plain segment is refused", ctx do
    link = sysfs(ctx, "bus/usb/devices/1-1.4/driver")
    File.rm!(link)
    File.ln_s!("..", link)
    s = start(ctx)

    assert USBIP.share("usb:1-1.4", server: s.server) == {:error, :invalid_driver}
    assert read(ctx, "bus/usb/drivers/usbip-host/match_busid") == ""
  end

  test "a failed modprobe or podman run leaves sysfs alone", ctx do
    s = start(ctx, modprobe: {"modprobe: FATAL: Module usbip-host not found\n", 1})

    assert USBIP.share("usb:1-1.4", server: s.server) ==
             {:error, {:cmd, "modprobe", 1, "modprobe: FATAL: Module usbip-host not found"}}

    assert FakePodman.verbs(s.fake) == []

    stop_supervised!(USBIP)
    Process.unregister(:"watcher_#{s.server}")
    s = start(ctx, podman_rules: [{"run *", [{125, "Error: no image\n"}]}])

    assert USBIP.share("usb:1-1.4", server: s.server) ==
             {:error, {:podman, {125, "Error: no image"}}}

    assert read(ctx, "bus/usb/drivers/usb/unbind") == ""
    assert read(ctx, "bus/usb/drivers/usbip-host/match_busid") == ""
  end

  test "devices left on usbip-host by an earlier server are adopted", ctx do
    bind_driver(ctx, "1-1.4", "usbip-host")

    File.ln_s!(
      sysfs(ctx, "bus/usb/devices/1-1.4"),
      sysfs(ctx, "bus/usb/drivers/usbip-host/1-1.4")
    )

    s = start(ctx)

    assert USBIP.shared(server: s.server) == [
             %{id: "usb:1-1.4", busid: "1-1.4", vid_pid: "0403:6001"}
           ]

    assert FakePodman.verbs(s.fake) == [@run_argv]
    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok
    assert FakePodman.verbs(s.fake) == [@run_argv, @stop_argv]
  end

  test "disabled is :ignore, and a missing server answers rather than exits" do
    assert USBIP.start_link(enabled: false) == :ignore
    assert USBIP.share("usb:1-1.4", server: :no_such_usbip) == {:error, :unavailable}
    assert USBIP.shared(server: :no_such_usbip) == {:error, :unavailable}
  end
end
