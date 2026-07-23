defmodule Vagus.Mqtt.Broker.LogsTest do
  use ExUnit.Case, async: true

  alias Vagus.Mqtt.Broker.Logs

  # Telemetry-independent: lines are cast directly ({:append, line}), the
  # same message the telemetry callback produces. Each test gets its own
  # named instance (the test name atom) so async cases can't collide on the
  # default singleton name or its telemetry handler id.
  defp start_logs(ctx) do
    pid = start_supervised!({Logs, name: ctx.test})
    %{logs: pid}
  end

  setup :start_logs

  defp append(pid, line), do: GenServer.cast(pid, {:append, line})

  test "subscribe -> append delivers {:broker_log, line}", %{logs: logs} do
    assert :ok = Logs.subscribe(logs)
    append(logs, "CONNECT c1")
    assert_receive {:broker_log, "CONNECT c1"}
  end

  test "unsubscribe stops delivery", %{logs: logs} do
    :ok = Logs.subscribe(logs)
    :ok = Logs.unsubscribe(logs)
    append(logs, "line")
    refute_receive {:broker_log, _}, 100
  end

  test "a dead subscriber is pruned on :DOWN and does not leak", %{logs: logs} do
    # The subscriber must be a process that subscribes ITSELF (subscribe/1
    # registers self()), then dies.
    task =
      Task.async(fn ->
        :ok = Logs.subscribe(logs)
        :ok
      end)

    assert :ok = Task.await(task)
    # Task process is dead; give the :DOWN a moment to be processed, then
    # prove the map no longer holds it (append must not crash and state
    # shows no subscribers).
    append(logs, "after death")
    assert %{subscribers: subs} = :sys.get_state(logs)
    assert subs == %{}
  end

  test "double subscribe is idempotent (single monitor, single delivery)", %{logs: logs} do
    :ok = Logs.subscribe(logs)
    :ok = Logs.subscribe(logs)
    append(logs, "once")
    assert_receive {:broker_log, "once"}
    refute_receive {:broker_log, "once"}, 50

    assert %{subscribers: subs} = :sys.get_state(logs)
    assert map_size(subs) == 1
  end

  test "tail/2 still returns backfill, oldest first, capped", %{logs: logs} do
    for i <- 1..5, do: append(logs, "l#{i}")
    assert Logs.tail(logs, 3) == ["l3", "l4", "l5"]
    assert Logs.tail(logs, 100) == ["l1", "l2", "l3", "l4", "l5"]
  end

  test "subscription delivers while tail keeps accumulating", %{logs: logs} do
    :ok = Logs.subscribe(logs)
    append(logs, "a")
    append(logs, "b")
    assert_receive {:broker_log, "a"}
    assert_receive {:broker_log, "b"}
    assert Logs.tail(logs, 10) == ["a", "b"]
  end
end
