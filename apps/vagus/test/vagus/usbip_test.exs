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
    "--user",
    "root",
    "--entrypoint",
    "usbipd",
    "img:test"
  ]
  @stop_argv ["stop", "-t", "5", "--ignore", "vagus-usbipd"]
  @inspect_argv ["container", "inspect", "-f", "{{.State.Running}}", "vagus-usbipd"]
  @drv "bus/usb/drivers"
  # Generous: under a loaded full suite the server can be slow to subscribe.
  @receive_ms 2_000

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

  # The kernel's side of a bind: the device's `driver` link.
  defp bind_driver(ctx, busid, driver) do
    link = sysfs(ctx, "bus/usb/devices/#{busid}/driver")
    File.rm(link)
    File.ln_s!(sysfs(ctx, "bus/usb/drivers/#{driver}"), link)
  end

  # Every sysfs write so far, in the order the server made them. The sysfs
  # files keep only the last value, so sequences are only visible here.
  defp writes do
    receive do
      {:sysfs_write, path, value} -> [{path, value} | writes()]
    after
      0 -> []
    end
  end

  defp captured(ctx, busid) do
    bind_driver(ctx, busid, "usbip-host")

    File.ln_s!(
      sysfs(ctx, "bus/usb/devices/#{busid}"),
      sysfs(ctx, "bus/usb/drivers/usbip-host/#{busid}")
    )
  end

  defp start(ctx, opts \\ []) do
    test = self()
    {podman_rules, opts} = Keyword.pop(opts, :podman_rules, [])

    fake =
      FakePodman.start(
        podman_rules ++
          [
            {"run *", [{0, "cid\n"}]},
            {"stop *", [{0, ""}]},
            {"container inspect *", [{0, "true\n"}]}
          ]
      )

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
      trace: test,
      # The grace timer fires only when a test delivers it.
      send_after: fn pid, msg, ms ->
        send(test, {:send_after, pid, msg, ms})
        make_ref()
      end,
      subscribe: fn server -> send(test, {:subscribed, server}) end
    ]

    Process.register(self(), :"watcher_#{name}")
    pid = start_supervised!({USBIP, Keyword.merge(base, opts)})
    %{server: name, pid: pid, fake: fake}
  end

  test "share binds the device the way usbip bind does and starts usbipd as root", ctx do
    s = start(ctx)
    assert_receive {:subscribed, _}, @receive_ms

    assert USBIP.share("usb:1-1.4", server: s.server) == :ok
    assert_received {:cmd, "modprobe", ["usbip-host"]}

    assert writes() == [
             {"#{@drv}/usb/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "add 1-1.4"},
             {"#{@drv}/usbip-host/bind", "1-1.4"}
           ]

    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv]
    assert ["--user", "root"] in Enum.chunk_every(@run_argv, 2, 1)

    assert USBIP.shared(server: s.server) == [
             %{
               id: "usb:1-1.4",
               busid: "1-1.4",
               vid_pid: "0403:6001",
               serial: "S14",
               state: :attached
             }
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
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @inspect_argv]
  end

  test "a usbipd found dead is started again on the next share", ctx do
    s = start(ctx, podman_rules: [{"container inspect *", [{125, "Error: no such container\n"}]}])
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    :ok = USBIP.share("usb:1-1.5", server: s.server)
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @inspect_argv, @run_argv]

    stop_supervised!(USBIP)
    Process.unregister(:"watcher_#{s.server}")
    s = start(ctx, podman_rules: [{"container inspect *", [{0, "false\n"}]}])
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    :ok = USBIP.share("usb:1-1.5", server: s.server)
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @inspect_argv, @run_argv]
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
    _ = writes()

    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok

    assert writes() == [
             {"#{@drv}/usbip-host/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"#{@drv}/usbip-host/rebind", "1-1.4"}
           ]

    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @inspect_argv]

    assert USBIP.unshare("1-1.5", server: s.server) == :ok
    assert {"#{@drv}/usbip-host/rebind", "1-1.5"} in writes()
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @inspect_argv, @stop_argv]
    assert USBIP.shared(server: s.server) == []

    bind_driver(ctx, "1-1.4", "usb")
    assert USBIP.unshare("usb:1-1.4", server: s.server) == {:error, :not_shared}
  end

  test "a failed del still rebinds, and its error is the result", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    bind_driver(ctx, "1-1.4", "usbip-host")
    match = sysfs(ctx, "bus/usb/drivers/usbip-host/match_busid")
    File.rm!(match)
    File.mkdir!(match)
    _ = writes()

    assert USBIP.unshare("usb:1-1.4", server: s.server) == {:error, {:sysfs, match, :enoent}}

    assert writes() == [
             {"#{@drv}/usbip-host/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"#{@drv}/usbip-host/rebind", "1-1.4"}
           ]

    assert USBIP.shared(server: s.server) == []
  end

  test "a failed rebind falls back to drivers_probe", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    bind_driver(ctx, "1-1.4", "usbip-host")
    rebind = sysfs(ctx, "bus/usb/drivers/usbip-host/rebind")
    File.rm!(rebind)
    _ = writes()

    assert USBIP.unshare("usb:1-1.4", server: s.server) == {:error, {:sysfs, rebind, :enoent}}

    assert writes() == [
             {"#{@drv}/usbip-host/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"#{@drv}/usbip-host/rebind", "1-1.4"},
             {"bus/usb/drivers_probe", "1-1.4"}
           ]
  end

  defp detach(s, busid) do
    send(s.pid, {:device, :removed, "usb:" <> busid})
    assert_receive {:send_after, _, {:reattach_timeout, ^busid, _} = timeout, 5_000}, @receive_ms
    timeout
  end

  defp states(s), do: Enum.map(USBIP.shared(server: s.server), &{&1.busid, &1.state})

  test "a share that re-enumerates onto usbip-host within the grace is kept", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    _ = writes()

    timeout = detach(s, "1-1.4")
    assert states(s) == [{"1-1.4", :detached}]

    captured(ctx, "1-1.4")
    send(s.pid, {:device, :added, %{id: "usb:1-1.4"}})
    assert states(s) == [{"1-1.4", :attached}]

    # The timer of the finished detach is stale.
    send(s.pid, timeout)
    assert states(s) == [{"1-1.4", :attached}]
    assert writes() == []
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv]
  end

  test "a share that comes back on its own driver is bound again", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    _ = writes()

    detach(s, "1-1.4")
    send(s.pid, {:device, :added, %{id: "usb:1-1.4"}})
    assert states(s) == [{"1-1.4", :attached}]

    assert writes() == [
             {"#{@drv}/usb/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "add 1-1.4"},
             {"#{@drv}/usbip-host/bind", "1-1.4"}
           ]

    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv]
  end

  test "a share whose rebind fails after coming back is forgotten", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    bind = sysfs(ctx, "bus/usb/drivers/usbip-host/bind")
    File.rm!(bind)
    _ = writes()

    detach(s, "1-1.4")
    send(s.pid, {:device, :added, %{id: "usb:1-1.4"}})
    assert states(s) == []

    assert writes() == [
             {"#{@drv}/usb/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "add 1-1.4"},
             {"#{@drv}/usbip-host/bind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"bus/usb/drivers_probe", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"}
           ]

    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]
  end

  test "an unplugged device is forgotten when the grace runs out", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    _ = writes()

    timeout = detach(s, "1-1.4")
    File.rm_rf!(sysfs(ctx, "bus/usb/devices/1-1.4"))
    assert writes() == []
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv]

    send(s.pid, timeout)
    assert USBIP.shared(server: s.server) == []
    assert writes() == [{"#{@drv}/usbip-host/match_busid", "del 1-1.4"}]
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]
  end

  test "a device its port captures after being forgotten is released", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    send(s.pid, detach(s, "1-1.4"))
    assert USBIP.shared(server: s.server) == []
    _ = writes()

    captured(ctx, "1-1.4")
    send(s.pid, {:device, :added, %{id: "usb:1-1.4"}})
    assert USBIP.shared(server: s.server) == []

    assert writes() == [
             {"#{@drv}/usbip-host/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"#{@drv}/usbip-host/rebind", "1-1.4"}
           ]

    send(s.pid, {:device, :added, %{id: "usb:1-1.5"}})
    assert USBIP.shared(server: s.server) == []
    assert writes() == []
  end

  test "unsharing a detached share that is gone writes only the del", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    timeout = detach(s, "1-1.4")
    File.rm_rf!(sysfs(ctx, "bus/usb/devices/1-1.4"))
    _ = writes()

    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok
    assert writes() == [{"#{@drv}/usbip-host/match_busid", "del 1-1.4"}]
    assert USBIP.shared(server: s.server) == []
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]

    send(s.pid, timeout)
    assert USBIP.shared(server: s.server) == []
    assert writes() == []
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]
  end

  test "unsharing a detached share whose device is back releases it", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    detach(s, "1-1.4")
    bind_driver(ctx, "1-1.4", "usbip-host")
    _ = writes()

    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok

    assert writes() == [
             {"#{@drv}/usbip-host/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"#{@drv}/usbip-host/rebind", "1-1.4"}
           ]

    assert USBIP.shared(server: s.server) == []
  end

  test "a resubscribe during the grace neither releases nor forgets a detached share", ctx do
    s = start(ctx)
    assert_receive {:subscribed, _}, @receive_ms
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    :ok = USBIP.share("usb:1-1.5", server: s.server)
    detach(s, "1-1.4")
    detach(s, "1-1.5")
    # 1-1.4 is back on usbip-host with its :added missed; 1-1.5 is still gone.
    captured(ctx, "1-1.4")
    File.rm_rf!(sysfs(ctx, "bus/usb/devices/1-1.5"))
    _ = writes()

    send(s.pid, :resubscribe)
    assert_receive {:subscribed, _}, @receive_ms
    assert states(s) == [{"1-1.4", :attached}, {"1-1.5", :detached}]
    assert writes() == []
  end

  test "a resubscribe forgets shares whose device left meanwhile", ctx do
    s = start(ctx)
    assert_receive {:subscribed, _}, @receive_ms
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    :ok = USBIP.share("usb:1-1.5", server: s.server)
    File.rm_rf!(sysfs(ctx, "bus/usb/devices/1-1.4"))
    _ = writes()

    # What the Watcher's :DOWN arms; the monitor here is on the test process.
    send(s.pid, :resubscribe)
    assert_receive {:subscribed, _}, @receive_ms
    assert Enum.map(USBIP.shared(server: s.server), & &1.busid) == ["1-1.5"]
    assert writes() == [{"#{@drv}/usbip-host/match_busid", "del 1-1.4"}]
  end

  # Another device on the same port, as the kernel's armed entry captures it.
  defp swap(ctx, busid, tty) do
    DevicesFixtures.remove_ftdi(ctx, busid, tty)
    DevicesFixtures.ftdi(ctx, busid, %{"idProduct" => "6015", "serial" => "OTHER"}, tty)
    captured(ctx, busid)
  end

  @released [
    {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
    {"#{@drv}/usbip-host/unbind", "1-1.4"},
    {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
    {"#{@drv}/usbip-host/rebind", "1-1.4"}
  ]

  test "a different device back on a detached share's port is released, not lent", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    detach(s, "1-1.4")
    swap(ctx, "1-1.4", "ttyUSB4")
    _ = writes()

    send(s.pid, {:device, :added, %{id: "usb:1-1.4"}})
    assert USBIP.shared(server: s.server) == []
    assert writes() == @released
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]
  end

  test "a resubscribe forgets a share whose port now holds a different device", ctx do
    s = start(ctx)
    assert_receive {:subscribed, _}, @receive_ms
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    :ok = USBIP.share("usb:1-1.5", server: s.server)
    # Swapped while the Watcher was down: no :removed or :added was sent.
    swap(ctx, "1-1.4", "ttyUSB4")
    _ = writes()

    send(s.pid, :resubscribe)
    assert_receive {:subscribed, _}, @receive_ms
    assert states(s) == [{"1-1.5", :attached}]
    assert writes() == @released
  end

  test "unsharing a device unplugged before its :removed arrived never writes rebind", ctx do
    s = start(ctx)
    :ok = USBIP.share("usb:1-1.4", server: s.server)
    File.rm_rf!(sysfs(ctx, "bus/usb/devices/1-1.4"))
    _ = writes()

    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok
    assert writes() == [{"#{@drv}/usbip-host/match_busid", "del 1-1.4"}]
    assert USBIP.shared(server: s.server) == []
    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]
  end

  test "a Watcher missing at start is retried until it is back", ctx do
    watcher = :"absent_watcher_#{System.unique_integer([:positive])}"
    s = start(ctx, watcher: watcher, watcher_expected?: true)
    # A call is served only after handle_continue's subscribe has failed.
    assert USBIP.shared(server: s.server) == []
    refute_received {:subscribed, _}

    pid = spawn_link(fn -> Process.sleep(:infinity) end)
    Process.register(pid, watcher)
    # Resubscribe's retry runs every second.
    assert_receive {:subscribed, ^watcher}, 3_000
  end

  test "a failed bind rolls back match_busid, re-probes, and stops usbipd", ctx do
    bind = sysfs(ctx, "bus/usb/drivers/usbip-host/bind")
    File.rm!(bind)
    File.mkdir!(bind)
    s = start(ctx)

    assert USBIP.share("usb:1-1.4", server: s.server) == {:error, {:sysfs, bind, :enoent}}

    assert writes() == [
             {"#{@drv}/usb/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "add 1-1.4"},
             {"#{@drv}/usbip-host/bind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "del 1-1.4"},
             {"bus/usb/drivers_probe", "1-1.4"}
           ]

    assert FakePodman.verbs(s.fake) == [@stop_argv, @run_argv, @stop_argv]
    assert USBIP.shared(server: s.server) == []
  end

  test "a failed match_busid write re-probes the released device", ctx do
    File.rm!(sysfs(ctx, "bus/usb/drivers/usbip-host/match_busid"))
    s = start(ctx)

    assert {:error, {:sysfs, _, :enoent}} = USBIP.share("usb:1-1.4", server: s.server)

    assert writes() == [
             {"#{@drv}/usb/unbind", "1-1.4"},
             {"#{@drv}/usbip-host/match_busid", "add 1-1.4"},
             {"bus/usb/drivers_probe", "1-1.4"}
           ]
  end

  test "an unknown device touches nothing", ctx do
    s = start(ctx)
    assert USBIP.share("usb:9-9", server: s.server) == {:error, :not_found}
    assert USBIP.share("nope", server: s.server) == {:error, :not_found}
    refute_received {:cmd, _, _}
    assert FakePodman.verbs(s.fake) == [@stop_argv]
    assert writes() == []
  end

  test "a busid that is not a port path is refused before any sysfs path is built", ctx do
    s = start(ctx)
    assert USBIP.share("../../etc", server: s.server) == {:error, :invalid_busid}
    assert USBIP.share("usb:../1-1.4", server: s.server) == {:error, :invalid_busid}
    assert USBIP.unshare("../../etc", server: s.server) == {:error, :invalid_busid}
    assert USBIP.share(:"1-1.4", server: s.server) == {:error, :invalid_busid}
    assert USBIP.unshare(~c"1-1.4", server: s.server) == {:error, :invalid_busid}
    refute_received {:cmd, _, _}
    assert FakePodman.verbs(s.fake) == [@stop_argv]
    assert writes() == []
  end

  test "a driver link that is not one plain segment is refused", ctx do
    link = sysfs(ctx, "bus/usb/devices/1-1.4/driver")
    File.rm!(link)
    File.ln_s!("..", link)
    s = start(ctx)

    assert USBIP.share("usb:1-1.4", server: s.server) == {:error, :invalid_driver}
    assert writes() == []
  end

  test "a failed modprobe or podman run leaves sysfs alone", ctx do
    s = start(ctx, modprobe: {"modprobe: FATAL: Module usbip-host not found\n", 1})

    assert USBIP.share("usb:1-1.4", server: s.server) ==
             {:error, {:cmd, "modprobe", 1, "modprobe: FATAL: Module usbip-host not found"}}

    assert FakePodman.verbs(s.fake) == [@stop_argv]

    stop_supervised!(USBIP)
    Process.unregister(:"watcher_#{s.server}")
    s = start(ctx, podman_rules: [{"run *", [{125, "Error: no image\n"}]}])

    assert USBIP.share("usb:1-1.4", server: s.server) ==
             {:error, {:podman, {125, "Error: no image"}}}

    assert writes() == []
  end

  test "devices left on usbip-host by an earlier server are adopted", ctx do
    captured(ctx, "1-1.4")
    s = start(ctx)

    assert USBIP.shared(server: s.server) == [
             %{
               id: "usb:1-1.4",
               busid: "1-1.4",
               vid_pid: "0403:6001",
               serial: "S14",
               state: :attached
             }
           ]

    assert FakePodman.verbs(s.fake) == [@run_argv]
    assert USBIP.unshare("usb:1-1.4", server: s.server) == :ok
    assert FakePodman.verbs(s.fake) == [@run_argv, @stop_argv]
  end

  test "usbipd that failed to start at adoption is started by the next share", ctx do
    captured(ctx, "1-1.4")
    s = start(ctx, podman_rules: [{"run *", [{125, "Error: boom\n"}, {0, "cid\n"}]}])

    assert Enum.map(USBIP.shared(server: s.server), & &1.busid) == ["1-1.4"]
    assert USBIP.share("usb:1-1.5", server: s.server) == :ok
    assert FakePodman.verbs(s.fake) == [@run_argv, @run_argv]
  end

  test "disabled is :ignore, and a missing server answers rather than exits" do
    assert USBIP.start_link(enabled: false) == :ignore
    assert USBIP.share("usb:1-1.4", server: :no_such_usbip) == {:error, :not_running}
    assert USBIP.unshare("usb:1-1.4", server: :no_such_usbip) == {:error, :not_running}
    assert USBIP.shared(server: :no_such_usbip) == {:error, :not_running}
  end
end
