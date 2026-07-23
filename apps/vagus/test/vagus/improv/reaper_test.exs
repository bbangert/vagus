defmodule Vagus.Improv.ReaperTest do
  use ExUnit.Case, async: true

  # All collaborators injected; no VintageNet, no Improv, no real
  # supervisor tree. `name: nil` avoids the singleton name so async cases
  # can't collide. Agents are start_supervised! like every other
  # long-lived test process (Iron Law #14).
  defp start_reaper(test_pid, overrides) do
    opts =
      Keyword.merge(
        [
          name: nil,
          subscribe: fn -> :ok end,
          connection: fn -> :disconnected end,
          improv_state: fn -> :disarmed end,
          reap: fn ->
            send(test_pid, :reaped)
            :ok
          end,
          check_delay_ms: 10,
          recheck_ms: 10
        ],
        overrides
      )

    start_supervised!({Vagus.Improv.Reaper, opts})
  end

  defp start_agent(initial) do
    start_supervised!({Agent, fn -> initial end})
  end

  test "online at init: reaps once disarmed and stops normally" do
    pid = start_reaper(self(), connection: fn -> :internet end)
    ref = Process.monitor(pid)

    assert_receive :reaped, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "offline at init: no reap until the :internet VintageNet event lands" do
    conn = start_agent(:disconnected)
    pid = start_reaper(self(), connection: fn -> Agent.get(conn, & &1) end)

    refute_receive :reaped, 100

    Agent.update(conn, fn _ -> :internet end)
    send(pid, {VintageNet, ["connection"], :lan, :internet, %{}})
    assert_receive :reaped, 500
  end

  test "does not reap mid-session; retries until improv disarms" do
    session = start_agent(:advertising)

    pid =
      start_reaper(self(),
        connection: fn -> :internet end,
        improv_state: fn -> Agent.get(session, & &1) end
      )

    ref = Process.monitor(pid)
    refute_receive :reaped, 100

    Agent.update(session, fn _ -> :disarmed end)
    assert_receive :reaped, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "connectivity blip: no reap while connection is not :internet" do
    conn = start_agent(:disconnected)
    pid = start_reaper(self(), connection: fn -> Agent.get(conn, & &1) end)

    # Event arrives but by check time the connection has dropped again.
    send(pid, {VintageNet, ["connection"], :lan, :internet, %{}})
    refute_receive :reaped, 100

    # Connection comes back; a fresh event triggers the reap.
    Agent.update(conn, fn _ -> :internet end)
    send(pid, {VintageNet, ["connection"], :disconnected, :internet, %{}})
    assert_receive :reaped, 500
  end

  test "rapid duplicate :internet events still produce exactly one reap" do
    conn = start_agent(:disconnected)
    pid = start_reaper(self(), connection: fn -> Agent.get(conn, & &1) end)
    ref = Process.monitor(pid)

    Agent.update(conn, fn _ -> :internet end)
    # Two events land inside one check window; the check_scheduled? guard
    # coalesces them into a single timer chain. (The reap-count assertion
    # can't catch every pileup regression — the process stops after the
    # first reap regardless — but it pins the user-visible contract and
    # documents the intent.)
    send(pid, {VintageNet, ["connection"], :lan, :internet, %{}})
    send(pid, {VintageNet, ["connection"], :lan, :internet, %{}})

    assert_receive :reaped, 500
    refute_receive :reaped, 100
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
  end

  test "unrelated VintageNet property changes are ignored" do
    pid = start_reaper(self(), connection: fn -> :disconnected end)

    send(pid, {VintageNet, ["interface", "wlan0", "connection"], :lan, :internet, %{}})
    refute_receive :reaped, 100
    assert Process.alive?(pid)
  end
end
