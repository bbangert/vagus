defmodule Vagus.Core.EventPusherTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.EventPusher

  # These exercise handle_cast/2 and handle_info/2 directly against
  # hand-built state, with no live GenServer/Fresh connection involved —
  # mirrors Vagus.Engine.ManagerTest's approach for the same reason: the
  # pure state-machine transitions (id sequencing, queue bounding,
  # backoff) are fully testable this way without ever reaching
  # Fresh.start/4's real network connection attempt.
  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        ws_url: "ws://example.invalid/api/websocket",
        token_store: :irrelevant,
        client: :irrelevant,
        connection_pid: nil,
        monitor_ref: nil,
        ready: false,
        next_id: 1,
        queue: :queue.new(),
        queue_size: 0,
        backoff_ms: 5_000
      },
      overrides
    )
  end

  defp received_frame do
    assert_receive {:"$gen_cast", {:request, {:text, json}}}
    Jason.decode!(json)
  end

  describe "handle_cast({:push, _}, state) while ready and connected" do
    test "sends immediately with the current id and increments next_id" do
      state = base_state(%{ready: true, connection_pid: self(), next_id: 1})

      assert {:noreply, new_state} =
               EventPusher.handle_cast({:push, %{"hello" => "world"}}, state)

      assert new_state.next_id == 2

      assert received_frame() == %{
               "id" => 1,
               "type" => "supervisor/event",
               "data" => %{"hello" => "world"}
             }
    end

    test "ids increase monotonically across successive pushes" do
      state = base_state(%{ready: true, connection_pid: self(), next_id: 1})

      {:noreply, state} = EventPusher.handle_cast({:push, %{"n" => 1}}, state)
      {:noreply, state} = EventPusher.handle_cast({:push, %{"n" => 2}}, state)
      {:noreply, _state} = EventPusher.handle_cast({:push, %{"n" => 3}}, state)

      assert received_frame()["id"] == 1
      assert received_frame()["id"] == 2
      assert received_frame()["id"] == 3
    end
  end

  describe "handle_cast({:push, _}, state) while not ready/connected" do
    test "buffers into the queue instead of sending" do
      state = base_state(%{ready: false, connection_pid: nil})

      assert {:noreply, new_state} = EventPusher.handle_cast({:push, %{"a" => 1}}, state)

      assert new_state.queue_size == 1
      refute_receive {:"$gen_cast", _}, 20
    end

    test "bounds the queue at 50, dropping the oldest" do
      state = base_state(%{ready: false, connection_pid: nil})

      state =
        Enum.reduce(1..55, state, fn n, acc ->
          {:noreply, acc} = EventPusher.handle_cast({:push, %{"n" => n}}, acc)
          acc
        end)

      assert state.queue_size == 50

      # Flushing (ready + connected) should replay events 6..55 in order -
      # 1..5 were dropped as the oldest once the bound was exceeded.
      flushed_state =
        %{state | ready: true, connection_pid: self()}
        |> then(&EventPusher.handle_info({:event_pusher_connection, :ready, self()}, &1))
        |> elem(1)

      assert flushed_state.queue_size == 0

      frames = for _ <- 1..50, do: received_frame()
      assert Enum.map(frames, & &1["data"]["n"]) == Enum.to_list(6..55)
      assert Enum.map(frames, & &1["id"]) == Enum.to_list(1..50)
    end
  end

  describe "handle_info({:event_pusher_connection, :connected, pid}, state)" do
    test "resets ready, next_id and backoff for the current connection pid" do
      state =
        base_state(%{
          connection_pid: self(),
          ready: true,
          next_id: 7,
          backoff_ms: 40_000
        })

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :connected, self()}, state)

      assert new_state.ready == false
      assert new_state.next_id == 1
      assert new_state.backoff_ms == 5_000
    end

    test "is a no-op for a stale (no longer current) connection pid" do
      other_pid = spawn(fn -> :ok end)
      state = base_state(%{connection_pid: self(), ready: true, next_id: 3})

      assert {:noreply, ^state} =
               EventPusher.handle_info({:event_pusher_connection, :connected, other_pid}, state)
    end
  end

  describe "handle_info({:event_pusher_connection, :ready, pid}, state)" do
    test "marks ready and flushes any buffered events" do
      queue = :queue.in(%{"n" => 1}, :queue.new())
      state = base_state(%{connection_pid: self(), ready: false, queue: queue, queue_size: 1})

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :ready, self()}, state)

      assert new_state.ready == true
      assert new_state.queue_size == 0
      assert received_frame()["data"] == %{"n" => 1}
    end

    test "is a no-op for a stale connection pid" do
      other_pid = spawn(fn -> :ok end)
      state = base_state(%{connection_pid: self(), ready: false})

      assert {:noreply, ^state} =
               EventPusher.handle_info({:event_pusher_connection, :ready, other_pid}, state)
    end
  end

  describe "handle_info({:DOWN, ref, :process, pid, reason}, state)" do
    test "clears connection state and doubles backoff (capped at 60s)" do
      ref = Process.monitor(self())

      state =
        base_state(%{connection_pid: self(), monitor_ref: ref, ready: true, backoff_ms: 40_000})

      assert {:noreply, new_state} =
               EventPusher.handle_info({:DOWN, ref, :process, self(), :killed}, state)

      assert new_state.connection_pid == nil
      assert new_state.monitor_ref == nil
      assert new_state.ready == false
      assert new_state.backoff_ms == 60_000
    end

    test "backoff doubles from the initial 5s without immediately hitting the cap" do
      ref = Process.monitor(self())
      state = base_state(%{connection_pid: self(), monitor_ref: ref, backoff_ms: 5_000})

      assert {:noreply, new_state} =
               EventPusher.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      assert new_state.backoff_ms == 10_000
    end

    test "schedules a :retry_connect message after the current backoff" do
      ref = Process.monitor(self())
      state = base_state(%{connection_pid: self(), monitor_ref: ref, backoff_ms: 5})

      assert {:noreply, _new_state} =
               EventPusher.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      assert_receive :retry_connect, 200
    end

    test "an unrelated ref is ignored" do
      ref = Process.monitor(self())
      unrelated_ref = make_ref()
      state = base_state(%{connection_pid: self(), monitor_ref: ref})

      assert {:noreply, ^state} =
               EventPusher.handle_info({:DOWN, unrelated_ref, :process, self(), :noproc}, state)
    end
  end

  describe "handle_info(:retry_connect, state)" do
    test "is a no-op once a connection pid is already recorded (no double connect)" do
      state = base_state(%{connection_pid: self()})

      assert {:noreply, ^state} = EventPusher.handle_info(:retry_connect, state)
    end
  end

  describe "handle_info/2 catch-all" do
    test "unknown messages never crash the manager" do
      state = base_state()
      assert {:noreply, ^state} = EventPusher.handle_info({:something, :unexpected}, state)
    end
  end
end
