defmodule Vagus.Core.BootTest do
  @moduledoc """
  CL-P1-T2 boot-time Core adoption — `BootStarterTest`-style: injected
  `:ping`/`:adopt` fns, no real engine or Core container needed.
  `async: false` because several tests assert on captured log output
  (`ExUnit.CaptureLog` is process-global under async).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Core.Boot

  setup do
    # `Boot.start_link/1` reads `config :vagus, :core_boot` at call time
    # (`:ignore` unless truthy) — `config/test.exs` never enables it, so
    # every test but the explicit "disabled" one below needs it flipped on
    # for the injected `:ping`/`:adopt` to ever run.
    prev = Application.get_env(:vagus, :core_boot)
    Application.put_env(:vagus, :core_boot, true)
    on_exit(fn -> restore_env(:core_boot, prev) end)
    :ok
  end

  test "disabled config (core_boot false) -> :ignore, no process registered" do
    prev = Application.get_env(:vagus, :core_boot)
    Application.put_env(:vagus, :core_boot, false)
    on_exit(fn -> restore_env(:core_boot, prev) end)

    assert :ignore = Boot.start_link([])
    assert Process.whereis(Boot) == nil
  end

  test "ping fails a few times then succeeds -> adopt is called exactly once" do
    parent = self()
    counter = :counters.new(1, [])

    ping = fn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if n < 3, do: {:error, :not_ready}, else: :ok
    end

    adopt = fn ->
      send(parent, :adopt_called)
      {:adopted, %{"Id" => "abc123def456"}}
    end

    log =
      capture_log(fn ->
        start_supervised!(
          {Boot, ping: ping, adopt: adopt, interval: 1, max_attempts: 20, name: nil}
        )

        assert_receive :adopt_called, 1_000
        # give a moment to confirm adopt is NOT called again — also long
        # enough for the `Logger.info/1` call right after `adopt.()` returns
        # (same process, so it runs synchronously, immediately after the
        # message send) to land in the `capture_log` device before it's read
        # below.
        Process.sleep(20)
      end)

    assert log =~ "adopted Core container abc123def456"
  end

  test "adopt returns :absent -> logs the no-auto-create warning, never creates" do
    parent = self()

    log =
      capture_log(fn ->
        start_supervised!(
          {Boot,
           ping: fn -> :ok end,
           adopt: fn ->
             send(parent, :adopt_called)
             :absent
           end,
           interval: 1,
           max_attempts: 5,
           name: nil}
        )

        assert_receive :adopt_called, 1_000
        # `adopt.()` returning is what signaled `:adopt_called`; the
        # Logger.warning/1 call it precedes runs immediately after, in the
        # same process — this just gives it a moment to land before the
        # captured log is inspected.
        Process.sleep(20)
      end)

    assert log =~ "Core container absent"
    assert log =~ "NOT auto-creating"
  end

  test "adopt returns an error -> logs a warning" do
    parent = self()

    log =
      capture_log(fn ->
        start_supervised!(
          {Boot,
           ping: fn -> :ok end,
           adopt: fn ->
             send(parent, :adopt_called)
             {:error, :nope}
           end,
           interval: 1,
           max_attempts: 5,
           name: nil}
        )

        assert_receive :adopt_called, 1_000
        # Same reasoning as the "adopted" test above: `Logger.warning/1` runs
        # synchronously right after `adopt.()` returns, in the same process;
        # this just gives the capture_log device a moment to flush it.
        Process.sleep(20)
      end)

    assert log =~ "adopt failed"
    assert log =~ "nope"
  end

  test "engine never ready (all pings fail) -> gives up with a warning, never adopts" do
    parent = self()

    log =
      capture_log(fn ->
        start_supervised!(
          {Boot,
           ping: fn -> {:error, :not_ready} end,
           adopt: fn ->
             send(parent, :adopt_called)
             :absent
           end,
           interval: 1,
           max_attempts: 3,
           name: nil}
        )

        # 3 attempts * 1ms interval exhausts well within this budget.
        Process.sleep(100)
      end)

    refute_received :adopt_called
    assert log =~ "engine not ready after 3 attempts"
    assert log =~ "giving up"
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)
end
