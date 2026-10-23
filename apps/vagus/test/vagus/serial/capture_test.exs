defmodule Vagus.Serial.CaptureTest do
  use ExUnit.Case, async: true

  alias Vagus.Serial.Capture
  alias Vagus.Test.FakeUART

  @moduletag :capture_log

  @ts ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \z/

  setup do
    sup = :"capture_#{System.unique_integer([:positive])}"
    start_supervised!({Capture, name: sup})
    root = Path.join(System.tmp_dir!(), "vagus-serial-#{System.unique_integer([:positive])}")
    proc = Path.join(root, "proc")
    File.mkdir_p!(proc)
    on_exit(fn -> File.rm_rf!(root) end)
    logs = Path.join(root, "serial")

    start = fn node, opts ->
      Capture.start(
        node,
        [supervisor: sup, root: logs, proc_root: proc, uart_mod: FakeUART] ++ opts
      )
    end

    %{sup: sup, logs: logs, proc: proc, start: start}
  end

  defp feed(pid, data) do
    send(pid, {:circuits_uart, "/dev/ttyUSB0", data})
    # A call after the send orders it: the worker has handled the data.
    _ = :sys.get_state(pid)
  end

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
    assert_receive {:DOWN, ^ref, _, _, :killed}
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

  test "an unplug ends the capture and it is not restarted", %{start: start, sup: sup} do
    {:ok, pid} = start.("ttyUSB0", [])
    uart = :sys.get_state(pid).uart
    ref = Process.monitor(pid)
    uart_ref = Process.monitor(uart)

    send(pid, {:circuits_uart, "/dev/ttyUSB0", {:error, :eio}})

    assert_receive {:DOWN, ^ref, _, _, {:shutdown, {:port_closed, :eio}}}
    assert_receive {:DOWN, ^uart_ref, _, _, _}
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(sup)
    assert Capture.status(sup) == []
    assert {:ok, _} = start.("ttyUSB0", [])
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

    for bad <- ["/dev/../etc/passwd", "../ttyUSB0", "/dev/serial/by-id/x", "/dev/.."] do
      assert {:error, :invalid_node} = start.(bad, name: "ok")
    end

    assert {:error, :enoent} = Capture.tail("never", 1, root: logs)
  end
end
