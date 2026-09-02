defmodule Vagus.Host.MemoryMonitorTest do
  @moduledoc """
  Readers are injected and `interval: :manual` disables self-scheduling, so
  every tick is driven by an explicit `send(pid, :tick)` and a
  `:sys.get_state/1` afterwards acts as the completion barrier. `async:
  false` because the assertions read captured log output.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Host.MemoryMonitor

  @mib 1024 * 1024

  @idle %{
    some: %{avg10: 0.0, avg60: 0.0, avg300: 0.0, total: 2383},
    full: %{avg10: 0.0, avg60: 0.0, avg300: 0.0, total: 250}
  }

  setup do
    prev = Application.get_env(:vagus, :memory_monitor)
    Application.put_env(:vagus, :memory_monitor, true)
    on_exit(fn -> restore_env(:memory_monitor, prev) end)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)

  defp start(opts \\ []) do
    defaults = [
      name: nil,
      interval: :manual,
      available: fn -> {:ok, 512 * @mib} end,
      swap: fn -> {:ok, %{total: 1024 * @mib, free: 768 * @mib}} end,
      pressure: fn -> {:ok, @idle} end
    ]

    start_supervised!({MemoryMonitor, Keyword.merge(defaults, opts)})
  end

  defp tick(pid, count \\ 1) do
    for _ <- 1..count do
      send(pid, :tick)
      :sys.get_state(pid)
    end

    pid
  end

  defp psi(some_avg60, full_avg60) do
    %{
      some: %{avg10: 0.0, avg60: some_avg60, avg300: 0.0, total: 1},
      full: %{avg10: 0.0, avg60: full_avg60, avg300: 0.0, total: 1}
    }
  end

  defp count(log, needle), do: log |> String.split(needle) |> length() |> Kernel.-(1)

  test "disabled config -> :ignore, no process registered" do
    Application.put_env(:vagus, :memory_monitor, false)

    assert :ignore = MemoryMonitor.start_link([])
    assert Process.whereis(MemoryMonitor) == nil
  end

  test "logs nothing for the first four ticks and one sample on the fifth" do
    pid = start()

    refute capture_log(fn -> tick(pid, 4) end) =~ "avail"
    log = capture_log(fn -> tick(pid) end)
    assert count(log, "Vagus.Host.MemoryMonitor: avail") == 1
  end

  test "the sample carries MemAvailable, swap use and both PSI triples" do
    pid = start(pressure: fn -> {:ok, psi(1.5, 0.25)} end)

    log = capture_log(fn -> tick(pid, 5) end)

    assert log =~
             "Vagus.Host.MemoryMonitor: avail 512 MiB, swap 256/1024 MiB, " <>
               "psi some 0.00/1.50/0.00 full 0.00/0.25/0.00"
  end

  test "logs one sample per five ticks, not one per tick" do
    pid = start()

    log = capture_log(fn -> tick(pid, 15) end)
    assert count(log, "Vagus.Host.MemoryMonitor: avail") == 3
  end

  test "warns when full avg60 reaches the threshold" do
    pid = start(pressure: fn -> {:ok, psi(0.0, 5.0)} end)

    log = capture_log(fn -> tick(pid) end)
    assert log =~ "[warning]"
    assert log =~ "Vagus.Host.MemoryMonitor: memory pressure"
  end

  test "warns when some avg60 reaches the threshold" do
    pid = start(pressure: fn -> {:ok, psi(10.0, 0.0)} end)

    assert capture_log(fn -> tick(pid) end) =~ "Vagus.Host.MemoryMonitor: memory pressure"
  end

  test "stays quiet just below both thresholds" do
    pid = start(pressure: fn -> {:ok, psi(9.99, 4.99)} end)

    refute capture_log(fn -> tick(pid, 5) end) =~ "memory pressure"
  end

  test "warns at most once per warn_interval" do
    clock = :counters.new(1, [])
    pid = start(pressure: fn -> {:ok, psi(0.0, 20.0)} end, now: fn -> :counters.get(clock, 1) end)

    log = capture_log(fn -> tick(pid, 2) end)
    assert count(log, "memory pressure") == 1

    :counters.add(clock, 1, 599_999)
    refute capture_log(fn -> tick(pid) end) =~ "memory pressure"

    :counters.add(clock, 1, 1)
    assert count(capture_log(fn -> tick(pid) end), "memory pressure") == 1
  end

  test "a reader returning :error drops its part of the sample and does not crash" do
    pid = start(swap: fn -> :error end)

    log = capture_log(fn -> tick(pid, 5) end)

    assert Process.alive?(pid)
    assert log =~ "Vagus.Host.MemoryMonitor: avail 512 MiB, psi some"
    refute log =~ "swap"
  end

  test "absent PSI is noted once at debug, never warned about" do
    pid = start(pressure: fn -> :error end)

    log = capture_log(fn -> tick(pid, 10) end)

    assert Process.alive?(pid)
    assert count(log, "no memory PSI") == 1
    refute log =~ "memory pressure"
    refute log =~ "psi some"
  end

  test "every reader failing logs no sample at all" do
    pid = start(available: fn -> :error end, swap: fn -> :error end, pressure: fn -> :error end)

    log = capture_log(fn -> tick(pid, 5) end)

    assert Process.alive?(pid)
    refute log =~ "Vagus.Host.MemoryMonitor: avail"
  end

  test "a raising reader is rescued and the process keeps sampling" do
    parent = self()

    raising = fn ->
      send(parent, :called)
      raise "procfs on fire"
    end

    pid = start(available: raising)

    log = capture_log(fn -> tick(pid) end)

    assert log =~ "Vagus.Host.MemoryMonitor: sample failed"
    assert log =~ "procfs on fire"
    assert Process.alive?(pid)
    assert_received :called

    # Still ticking, and the failed tick still counted.
    assert %{ticks: 2} = :sys.get_state(tick(pid))
  end

  test "a throwing reader is caught the same way" do
    pid = start(swap: fn -> throw(:nope) end)

    assert capture_log(fn -> tick(pid) end) =~
             "Vagus.Host.MemoryMonitor: sample failed (caught throw: :nope)"

    assert Process.alive?(pid)
  end

  test "an unexpected message is ignored, not crashed on" do
    pid = start()

    log = capture_log(fn -> send(pid, :something_else) && :sys.get_state(pid) end)

    assert log =~ "ignoring unexpected message :something_else"
    assert Process.alive?(pid)
    assert %{ticks: 0} = :sys.get_state(pid)
  end

  test "schedules its own ticks when an interval is set" do
    pid = start(interval: 10)

    assert wait_for_ticks(pid, 3)
  end

  defp wait_for_ticks(pid, wanted, attempts \\ 200) do
    cond do
      :sys.get_state(pid).ticks >= wanted ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_for_ticks(pid, wanted, attempts - 1)
    end
  end
end
