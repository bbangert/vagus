defmodule Vagus.Serial.CapturePtyTest do
  # The real Circuits.UART against a socat pty pair: the framing and flush
  # options are otherwise only checked as keywords handed to a fake.
  use ExUnit.Case, async: true

  alias Vagus.Serial.Capture
  alias Vagus.Serial.Capture.Worker

  @moduletag :pty
  @moduletag :capture_log

  if is_nil(System.find_executable("socat")) do
    @moduletag skip: "socat is not on PATH"
  end

  @ts ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z /

  setup do
    root = Path.join(System.tmp_dir!(), "vagus-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ours = Path.join(root, "ours")
    peer = Path.join(root, "peer")

    socat =
      Port.open({:spawn_executable, System.find_executable("socat")}, [
        :binary,
        :exit_status,
        args: ["pty,raw,echo=0,link=#{ours}", "pty,raw,echo=0,link=#{peer}"]
      ])

    {:os_pid, os_pid} = Port.info(socat, :os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true) end)
    eventually(fn -> File.exists?(ours) and File.exists?(peer) end)

    sup = :"capture_pty_#{System.unique_integer([:positive])}"
    start_supervised!({Capture, name: sup})
    {:ok, writer} = Circuits.UART.start_link()
    :ok = Circuits.UART.open(writer, peer, speed: 115_200, active: false)

    %{root: root, ours: ours, sup: sup, writer: writer, socat: socat, os_pid: os_pid}
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          50 -> eventually(fun, tries - 1)
        end
    end
  end

  # Capture.start/2 takes /dev/tty* only, and socat's links live elsewhere,
  # so the worker is started directly with what start/2 would hand it.
  test "captures timestamped lines, flushes a partial one, and stays down when the peer goes",
       ctx do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        ctx.sup,
        {Worker, node: ctx.ours, label: "pty", table: ctx.sup, root: ctx.root, flush_ms: 100}
      )

    log = Path.join(ctx.root, "pty.log")
    :ok = Circuits.UART.write(ctx.writer, "U-Boot 2024.01\r\nlogin: ")

    eventually(fn -> length(String.split(File.read!(log), "\n", trim: true)) == 2 end)
    [boot, login] = String.split(File.read!(log), "\n", trim: true)
    assert boot =~ @ts and String.ends_with?(boot, " U-Boot 2024.01")
    assert login =~ @ts and String.ends_with?(login, " login: ")

    ref = Process.monitor(pid)
    System.cmd("kill", ["#{ctx.os_pid}"])

    assert_receive {:DOWN, ^ref, _, _, {:shutdown, {:port_closed, _}}}, 5_000
    assert %{active: 0} = DynamicSupervisor.count_children(ctx.sup)
  end
end
