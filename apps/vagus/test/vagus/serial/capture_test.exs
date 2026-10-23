defmodule Vagus.Serial.CaptureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.DevicesFixtures
  alias Vagus.Serial.Capture
  alias Vagus.Test.FakeUART

  @moduletag :capture_log

  @receive_ms 2_000

  @ts ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \z/

  setup do
    sup = :"capture_#{System.unique_integer([:positive])}"
    start_supervised!({Capture, name: sup})
    root = Path.join(System.tmp_dir!(), "vagus-serial-#{System.unique_integer([:positive])}")
    proc = Path.join(root, "proc")
    File.mkdir_p!(proc)
    on_exit(fn -> File.rm_rf!(root) end)
    logs = Path.join(root, "serial")
    # No USB devices, so labels default to the node's basename.
    sysfs = Path.join(root, "sys")

    start = fn node, opts ->
      defaults = [supervisor: sup, root: logs, proc_root: proc, sysfs_root: sysfs]
      Capture.start(node, defaults |> Keyword.put(:uart_mod, FakeUART) |> Keyword.merge(opts))
    end

    %{sup: sup, logs: logs, proc: proc, root: root, start: start}
  end

  defp feed(pid, data) do
    :ok = FakeUART.deliver(:sys.get_state(pid).uart, data)
    # A call after the delivery orders it: the worker has handled the data.
    _ = :sys.get_state(pid)
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  defp split_ts(line) do
    <<ts::binary-size(25), rest::binary>> = line
    assert ts =~ @ts
    rest
  end

  test "opens 8N1 115200 in active mode with line framing and a partial-line flush", %{
    start: start
  } do
    {:ok, pid} = start.("ttyUSB0", [])
    %{node: node, opts: opts, owner: ^pid} = FakeUART.opened(:sys.get_state(pid).uart)

    assert node == "/dev/ttyUSB0"
    assert opts[:active] == true
    assert opts[:speed] == 115_200
    assert {opts[:data_bits], opts[:stop_bits], opts[:parity]} == {8, 1, :none}
    assert opts[:flow_control] == :none
    assert opts[:framing] == {Circuits.UART.Framing.Line, separator: "\n", max_length: 4096}
    assert opts[:rx_framing_timeout] == 500
  end

  test "passes line options through", %{start: start} do
    {:ok, pid} = start.("/dev/ttyACM1", baud: 1_500_000, parity: :even, flow_control: :hardware)
    %{opts: opts} = FakeUART.opened(:sys.get_state(pid).uart)
    assert {opts[:speed], opts[:parity], opts[:flow_control]} == {1_500_000, :even, :hardware}
  end

  test "writes each line with a UTC millisecond timestamp, partial lines as-is", %{
    start: start,
    logs: logs
  } do
    {:ok, pid} = start.("ttyUSB0", [])
    feed(pid, "U-Boot 2024.01\r")
    feed(pid, {:partial, "login: "})
    feed(pid, "")

    assert [a, b, c] = lines(Path.join(logs, "ttyUSB0.log"))
    assert split_ts(a) == "U-Boot 2024.01"
    assert split_ts(b) == "login: "
    assert split_ts(c) == ""
  end

  test "status, stop by label or node, and tail", %{start: start, sup: sup, logs: logs} do
    {:ok, pid} = start.("ttyUSB0", name: "board-a")
    for i <- 1..5, do: feed(pid, "line #{i}")

    assert [entry] = Capture.status(sup)
    assert %{label: "board-a", node: "/dev/ttyUSB0", baud: 115_200, state: :capturing} = entry
    assert entry.file == Path.join(logs, "board-a.log")
    assert entry.bytes == File.stat!(entry.file).size
    assert %DateTime{} = entry.since

    assert {:ok, last} = Capture.tail("board-a", 2, root: logs)
    assert Enum.map(last, &split_ts/1) == ["line 4", "line 5"]

    assert :ok = Capture.stop("board-a", sup)
    assert Capture.status(sup) == []
    assert {:error, :not_found} = Capture.stop("board-a", sup)
    # The file outlives the capture.
    assert {:ok, [_, _]} = Capture.tail("board-a", 2, root: logs)

    {:ok, _} = start.("ttyUSB0", name: "board-a")
    assert :ok = Capture.stop("/dev/ttyUSB0", sup)
    assert Capture.status(sup) == []
  end

  test "rotates once at the cap and tail reaches into the rotated file", %{
    start: start,
    logs: logs
  } do
    # 24-byte timestamp + space + 9-byte payload + newline = 35 bytes a line.
    {:ok, pid} = start.("ttyUSB0", max_bytes: 100)
    for i <- 1..7, do: feed(pid, "payload-#{i}")

    log = Path.join(logs, "ttyUSB0.log")
    assert Enum.map(lines(log <> ".1"), &split_ts/1) == ["payload-5", "payload-6"]
    assert Enum.map(lines(log), &split_ts/1) == ["payload-7"]
    assert File.stat!(log).size <= 100
    assert File.stat!(log <> ".1").size <= 100
    refute File.exists?(log <> ".2")
    assert :sys.get_state(pid).bytes == 35

    assert {:ok, tail} = Capture.tail("ttyUSB0", 3, root: logs)
    assert Enum.map(tail, &split_ts/1) == ["payload-5", "payload-6", "payload-7"]
  end

  test "a rotation between tail's two opens is neither repeated nor reordered", %{
    start: start,
    logs: logs
  } do
    # 35 bytes a line: payload-3 rotates 1 and 2 out to .log.1.
    {:ok, pid} = start.("ttyUSB0", max_bytes: 100)
    for i <- 1..2, do: feed(pid, "payload-#{i}")

    rotate_once = fn ->
      if not Process.get(:rotated, false) do
        Process.put(:rotated, true)
        for i <- 3..4, do: feed(pid, "payload-#{i}")
      end
    end

    assert {:ok, tail} = Capture.tail("ttyUSB0", 4, root: logs, between_opens: rotate_once)
    assert Process.get(:rotated)
    assert Enum.map(tail, &split_ts/1) == ["payload-1", "payload-2", "payload-3", "payload-4"]
  end

  test "a second capture of the same node or label is busy", %{start: start, sup: sup} do
    {:ok, _} = start.("ttyUSB0", [])
    assert {:error, :busy} = start.("/dev/ttyUSB0", name: "other")
    assert {:error, :busy} = start.("ttyUSB1", name: "ttyUSB0")
    assert [%{label: "ttyUSB0"}] = Capture.status(sup)
  end

  test "a claim left by a killed capture does not block a new one", %{start: start, sup: sup} do
    {:ok, pid} = start.("ttyUSB0", [])
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}, @receive_ms
    assert {:ok, _} = start.("ttyUSB0", [])
    assert [_] = Capture.status(sup)
  end

  test "refuses a node another host process holds open", %{start: start, proc: proc} do
    for {pid, fd, target} <- [
          {"412", "3", "/dev/ttyUSB0"},
          {"77", "0", "/dev/pts/1"},
          {"77", "5", "/dev/ttyUSB0"},
          {"9", "1", "/dev/ttyUSB1"}
        ] do
      dir = Path.join([proc, pid, "fd"])
      File.mkdir_p!(dir)
      File.ln_s!(target, Path.join(dir, fd))
    end

    File.mkdir_p!(Path.join(proc, "self"))

    assert {:error, {:in_use, [77, 412]}} = start.("ttyUSB0", [])
    assert {:ok, _} = start.("ttyUSB2", [])
  end

  for reason <- [:eio, :ebadf, :enxio] do
    test "an unplug (#{reason}) ends the capture and it is not restarted", %{
      start: start,
      sup: sup
    } do
      reason = unquote(reason)
      {:ok, pid} = start.("ttyUSB0", [])
      uart = :sys.get_state(pid).uart
      ref = Process.monitor(pid)
      uart_ref = Process.monitor(uart)

      FakeUART.deliver(uart, {:error, reason})

      assert_receive {:DOWN, ^ref, _, _, {:shutdown, {:port_closed, ^reason}}}, @receive_ms
      assert_receive {:DOWN, ^uart_ref, _, _, _}, @receive_ms
      assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(sup)
      assert Capture.status(sup) == []
      assert {:ok, _} = start.("ttyUSB0", [])
    end
  end

  test "an open failure leaves nothing behind", %{start: start, sup: sup} do
    assert {:error, :enoent} = start.("ttyFAIL0", [])
    assert Capture.status(sup) == []
    assert {:ok, _} = start.("ttyUSB9", name: "ttyFAIL0")
  end

  test "rejects labels and nodes that could leave the log directory", %{start: start, logs: logs} do
    for bad <- ["../x", "..", ".", "a/b", "", String.duplicate("a", 65), "a b"] do
      assert {:error, :invalid_label} = start.("ttyUSB0", name: bad)
      assert {:error, :invalid_label} = Capture.tail(bad, 1, root: logs)
    end

    for bad <- [
          "/dev/../etc/passwd",
          "../ttyUSB0",
          "/dev/serial/by-id/x",
          "/dev/..",
          "/dev/pts/0",
          "watchdog0",
          "/dev/mmcblk0",
          "tty",
          "/dev/tty../x"
        ] do
      assert {:error, :invalid_node} = start.(bad, name: "ok")
    end

    assert {:error, :enoent} = Capture.tail("never", 1, root: logs)
  end

  test "the label defaults to the owning device's stable id", %{
    start: start,
    root: root,
    logs: logs
  } do
    ctx = DevicesFixtures.bench(%{sysfs_root: Path.join(root, "bench"), dev_root: "/dev"})

    {:ok, pid} = start.("ttyUSB0", sysfs_root: ctx.sysfs_root, dev_root: "/dev")
    assert :sys.get_state(pid).label == "usb-1-1.2"
    assert File.exists?(Path.join(logs, "usb-1-1.2.log"))

    {:ok, pid} = start.("ttyS0", sysfs_root: ctx.sysfs_root, dev_root: "/dev")
    assert :sys.get_state(pid).label == "ttyS0"
  end

  test "logs are private to root", %{start: start, logs: logs} do
    {:ok, pid} = start.("ttyUSB0", max_bytes: 40)
    log = Path.join(logs, "ttyUSB0.log")
    assert mode(logs) == 0o700
    assert mode(log) == 0o600

    feed(pid, "payload-1")
    feed(pid, "payload-2")
    assert File.exists?(log <> ".1")
    assert mode(log) == 0o600
    assert mode(log <> ".1") == 0o600
  end

  test "max_bytes is clamped to 64 MiB", %{start: start} do
    {:ok, pid} = start.("ttyUSB0", max_bytes: 1024 * 1024 * 1024)
    assert :sys.get_state(pid).max_bytes == 64 * 1024 * 1024
  end

  test "a failed rotation keeps the live log and warns once", %{start: start, logs: logs} do
    {:ok, pid} = start.("ttyUSB0", max_bytes: 40)
    log = Path.join(logs, "ttyUSB0.log")
    # A non-empty directory in .1's place: rename fails, even as root.
    File.mkdir_p!(Path.join(log <> ".1", "x"))

    output =
      capture_log(fn ->
        for i <- 1..4, do: feed(pid, "payload-#{i}")
      end)

    assert Enum.map(lines(log), &split_ts/1) == for(i <- 1..4, do: "payload-#{i}")
    assert length(Regex.scan(~r/rotation failed/, output)) == 1
  end

  test "write failures are counted and warned about once", %{start: start, sup: sup} do
    {:ok, pid} = start.("ttyUSB0", [])
    :sys.replace_state(pid, fn state -> File.close(state.io) && state end)

    output =
      capture_log(fn ->
        for i <- 1..3, do: feed(pid, "lost-#{i}")
      end)

    assert [%{dropped: 3}] = Capture.status(sup)
    assert length(Regex.scan(~r/write failed/, output)) == 1
  end

  test "tail reads the last lines of large files and spans the rotation", %{logs: logs} do
    File.mkdir_p!(logs)
    log = Path.join(logs, "big.log")
    # Lines straddle the 64 KiB read chunks.
    File.write!(log <> ".1", Enum.map(1..20_000, &"old #{&1}\n"))
    File.write!(log, Enum.map(1..20_000, &"new #{&1}\n"))

    assert {:ok, ["new 19999", "new 20000"]} = Capture.tail("big", 2, root: logs)

    assert {:ok, tail} = Capture.tail("big", 20_002, root: logs)
    assert Enum.take(tail, 3) == ["old 19999", "old 20000", "new 1"]
    assert List.last(tail) == "new 20000"

    File.rm!(log)
    assert {:ok, ["old 20000"]} = Capture.tail("big", 1, root: logs)
  end

  test "an absent supervisor is an error, not a raise", %{start: start} do
    assert {:error, :absent} = Capture.status(:no_such_capture)
    assert {:error, :absent} = Capture.stop("ttyUSB0", :no_such_capture)
    assert {:error, :absent} = start.("ttyUSB0", supervisor: :no_such_capture)
  end

  test "a worker outliving its supervisor's table stops cleanly", %{start: start} do
    # Not restarted, so no new table of the same name can stand in for it.
    sup = :"capture_#{System.unique_integer([:positive])}"
    start_supervised!({Capture, name: sup}, id: :temporary_capture, restart: :temporary)
    {:ok, pid} = start.("ttyUSB0", supervisor: sup)
    ref = Process.monitor(pid)
    Process.exit(Process.whereis(sup), :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}, @receive_ms
  end
end
