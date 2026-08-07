defmodule Vagus.Core.EventPusherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Core.EventPusher
  alias Vagus.Core.EventPusher.Connection
  alias Vagus.Core.TokenStore

  # These exercise handle_cast/2 and handle_info/2 directly against
  # hand-built state, with no live GenServer/Fresh connection involved —
  # mirrors Vagus.Engine.ManagerTest's approach for the same reason: the
  # pure state-machine transitions (id sequencing, queue bounding,
  # backoff) are fully testable this way without ever reaching
  # Fresh.start/4's real network connection attempt. `conn_mod` is the TCP
  # client here, whose `send_frame/2` is a `Fresh.send/2` cast — which is
  # what makes `received_frame/0` below work with `self()` standing in for
  # the connection process.
  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        ws_url: "ws://example.invalid/api/websocket",
        token_store: :irrelevant,
        client: :irrelevant,
        conn_mod: Connection,
        connection_pid: nil,
        monitor_ref: nil,
        retry_ref: nil,
        ready_ref: nil,
        ready_timeout_ms: 60_000,
        ready: false,
        next_id: 1,
        pending: %{},
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
    test "resets ready and backoff, but never the id counter" do
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
      assert new_state.backoff_ms == 5_000
      # Monotonic across connections: an id must never name two different
      # requests over the manager's lifetime (stale-timeout race).
      assert new_state.next_id == 7
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

  describe "ready timeout" do
    defp forever_pid do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    test "a :connected notification (re)arms the ready timer" do
      state = base_state(%{connection_pid: self(), ready: true, ready_ref: nil})

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :connected, self()}, state)

      assert is_reference(new_state.ready_ref)
      assert new_state.ready == false
    end

    test "becoming ready cancels the timer" do
      state =
        base_state(%{
          connection_pid: self(),
          ready_ref: Process.send_after(self(), {:ready_timeout, self()}, 60_000)
        })

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :ready, self()}, state)

      assert new_state.ready == true
      assert new_state.ready_ref == nil
    end

    test "becoming ready drains an already-delivered {:ready_timeout, _}" do
      # `Process.cancel_timer/1` can't unsend it; the stale-timer
      # discipline says drain rather than rely on the guard clause.
      ref = Process.send_after(self(), {:ready_timeout, self()}, 0)
      assert_receive {:ready_timeout, _pid}, 200
      send(self(), {:ready_timeout, self()})

      state = base_state(%{connection_pid: self(), ready_ref: ref})

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :ready, self()}, state)

      assert new_state.ready_ref == nil
      refute_received {:ready_timeout, _}
    end

    test "a connection that never becomes ready is killed, and the :DOWN arms a retry" do
      pid = forever_pid()
      monitor_ref = Process.monitor(pid)

      state =
        base_state(%{
          connection_pid: pid,
          monitor_ref: monitor_ref,
          ready: false,
          backoff_ms: 5,
          ready_ref: Process.send_after(self(), {:ready_timeout, pid}, 60_000)
        })

      {{:noreply, killed_state}, log} =
        with_log(fn -> EventPusher.handle_info({:ready_timeout, pid}, state) end)

      assert log =~ "never became ready"
      assert killed_state.ready_ref == nil

      # The kill is the whole mechanism: it turns an invisible half-open
      # wedge into the ordinary `:DOWN` the manager already knows how to
      # recover from, transport re-pick and all.
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :killed}, 1_000
      refute Process.alive?(pid)

      assert {:noreply, down_state} =
               EventPusher.handle_info(
                 {:DOWN, monitor_ref, :process, pid, :killed},
                 killed_state
               )

      assert down_state.connection_pid == nil
      assert down_state.ready_ref == nil
      assert is_reference(down_state.retry_ref)
      assert_receive :retry_connect, 200
    end

    test "a ready connection is never killed by a stale timer" do
      pid = forever_pid()
      state = base_state(%{connection_pid: pid, ready: true, ready_ref: nil})

      assert {:noreply, ^state} = EventPusher.handle_info({:ready_timeout, pid}, state)
      assert Process.alive?(pid)
    end

    test "a timeout naming a connection that is no longer current is a no-op" do
      current = forever_pid()
      previous = forever_pid()
      state = base_state(%{connection_pid: current, ready: false})

      assert {:noreply, ^state} = EventPusher.handle_info({:ready_timeout, previous}, state)
      assert Process.alive?(previous)
      assert Process.alive?(current)
    end

    test "the :DOWN handler clears the ready timer" do
      ref = Process.monitor(self())

      state =
        base_state(%{
          connection_pid: self(),
          monitor_ref: ref,
          backoff_ms: 5,
          ready_ref: Process.send_after(self(), {:ready_timeout, self()}, 60_000)
        })

      assert {:noreply, new_state} =
               EventPusher.handle_info({:DOWN, ref, :process, self(), :killed}, state)

      assert new_state.ready_ref == nil
    end
  end

  # The Gate-B wedge, whole: a leg that connects at the TCP level and then
  # hears nothing back (Core gone from the port it was dialled on) used to
  # leave the manager with a live `connection_pid`, `ready: false` and no
  # armed retry — forever, because the process stayed alive and the monitor
  # had nothing to report. Driven through the real GenServer against a
  # listener that accepts and never answers.
  describe "wedged connection, end to end" do
    setup do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      test = self()
      acceptor = spawn_link(fn -> accept_loop(listen, test) end)

      on_exit(fn ->
        Process.exit(acceptor, :kill)
        :gen_tcp.close(listen)
      end)

      %{ws_url: "ws://127.0.0.1:#{port}/api/websocket"}
    end

    defp accept_loop(listen, test) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          # Deliberately never replied to: the WS upgrade can't complete,
          # so the connection never reports `:connected` or `:ready`.
          send(test, {:accepted, socket})
          accept_loop(listen, test)

        {:error, _reason} ->
          :ok
      end
    end

    defp start_token_store_with_refresh_token do
      name = :"wedge_ts_#{System.unique_integer([:positive])}"

      path =
        Path.join(System.tmp_dir!(), "vagus_wedge_ts_#{System.unique_integer([:positive])}.json")

      start_supervised!(%{id: name, start: {TokenStore, :start_link, [[name: name, path: path]]}})
      :ok = TokenStore.put_options(%{"refresh_token" => "wedge-refresh-token"}, name)
      on_exit(fn -> File.rm(path) end)

      name
    end

    test "the manager kills the wedged leg and dials again", %{ws_url: ws_url} do
      token_store = start_token_store_with_refresh_token()
      name = :"wedge_pusher_#{System.unique_integer([:positive])}"

      pusher =
        start_supervised!(%{
          id: name,
          start:
            {EventPusher, :start_link,
             [
               [
                 name: name,
                 ws_url: ws_url,
                 token_store: token_store,
                 client: :irrelevant,
                 ready_timeout: 500
               ]
             ]}
        })

      assert_receive {:accepted, _socket}, 2_000

      %{connection_pid: wedged} = :sys.get_state(pusher)
      assert is_pid(wedged)
      wedged_ref = Process.monitor(wedged)

      # Wedged exactly as observed on device: alive, connected, not ready.
      assert %{ready: false} = :sys.get_state(pusher)

      assert_receive {:DOWN, ^wedged_ref, :process, ^wedged, _reason}, 2_000

      # And the manager is back in its ordinary recovery path rather than
      # sitting on a live-but-useless connection.
      assert %{connection_pid: nil, ready: false, retry_ref: retry_ref} =
               eventually_state(pusher, &(&1.connection_pid == nil))

      assert is_reference(retry_ref)

      # The retry re-runs transport selection and dials afresh (5s backoff;
      # the retry timer itself is covered by the :DOWN tests above).
      assert_receive {:accepted, _socket}, 10_000
    end

    defp eventually_state(pusher, fun, attempts \\ 100) do
      state = :sys.get_state(pusher)

      cond do
        fun.(state) ->
          state

        attempts == 0 ->
          flunk("manager never reached the expected state: #{inspect(state)}")

        true ->
          Process.sleep(20)
          eventually_state(pusher, fun, attempts - 1)
      end
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

  describe "handle_call({:command, _, _}, from, state)" do
    setup do
      %{from: {self(), make_ref()}}
    end

    test "sends the frame with the manager-assigned id and stashes the caller", %{from: from} do
      state = base_state(%{ready: true, connection_pid: self(), next_id: 4})

      assert {:noreply, new_state} =
               EventPusher.handle_call(
                 {:command, %{"type" => "config/auth/list"}, 5_000},
                 from,
                 state
               )

      assert received_frame() == %{"id" => 4, "type" => "config/auth/list"}
      assert new_state.next_id == 5
      assert {^from, timer} = new_state.pending[4]
      assert is_reference(timer)
    end

    test "replies {:error, :not_connected} immediately when not ready", %{from: from} do
      state = base_state(%{ready: false, connection_pid: nil})

      assert {:reply, {:error, :not_connected}, ^state} =
               EventPusher.handle_call(
                 {:command, %{"type" => "config/auth/list"}, 5_000},
                 from,
                 state
               )
    end

    test "does not enter the offline queue", %{from: from} do
      state = base_state(%{ready: false, connection_pid: nil})

      assert {:reply, {:error, :not_connected}, new_state} =
               EventPusher.handle_call({:command, %{"type" => "x"}, 5_000}, from, state)

      assert new_state.queue_size == 0
    end
  end

  describe "handle_info({:event_pusher_result, id, result}, state)" do
    test "replies to the waiting caller and drops the pending entry" do
      ref = make_ref()
      timer = Process.send_after(self(), :never, 60_000)
      state = base_state(%{pending: %{7 => {{self(), ref}, timer}}})

      assert {:noreply, new_state} =
               EventPusher.handle_info(
                 {:event_pusher_result, 7, {:ok, [%{"id" => "abc"}]}},
                 state
               )

      assert_receive {^ref, {:ok, [%{"id" => "abc"}]}}
      assert new_state.pending == %{}
    end

    test "propagates a success:false envelope as an error to the caller" do
      ref = make_ref()
      timer = Process.send_after(self(), :never, 60_000)
      state = base_state(%{pending: %{1 => {{self(), ref}, timer}}})

      error = %{"code" => "unauthorized", "message" => "Unauthorized"}

      assert {:noreply, new_state} =
               EventPusher.handle_info(
                 {:event_pusher_result, 1, {:error, {:core_error, error}}},
                 state
               )

      assert_receive {^ref, {:error, {:core_error, ^error}}}
      assert new_state.pending == %{}
    end

    test "a result for an id nobody is waiting on is ignored" do
      state = base_state()

      assert {:noreply, ^state} =
               EventPusher.handle_info({:event_pusher_result, 99, {:ok, nil}}, state)
    end

    test "a late result for an already-replied id is ignored" do
      ref = make_ref()
      timer = Process.send_after(self(), :never, 60_000)
      state = base_state(%{pending: %{3 => {{self(), ref}, timer}}})

      {:noreply, replied} =
        EventPusher.handle_info({:event_pusher_result, 3, {:ok, :first}}, state)

      assert_receive {^ref, {:ok, :first}}

      assert {:noreply, ^replied} =
               EventPusher.handle_info({:event_pusher_result, 3, {:ok, :second}}, replied)

      refute_receive {^ref, _}, 20
    end
  end

  describe "handle_info({:command_timeout, id}, state)" do
    test "replies {:error, :timeout} and leaves no pending entry" do
      ref = make_ref()
      timer = Process.send_after(self(), :never, 60_000)
      state = base_state(%{pending: %{2 => {{self(), ref}, timer}}})

      assert {:noreply, new_state} = EventPusher.handle_info({:command_timeout, 2}, state)

      assert_receive {^ref, {:error, :timeout}}
      assert new_state.pending == %{}
    end

    test "a timeout for an already-replied id is a no-op" do
      state = base_state()
      assert {:noreply, ^state} = EventPusher.handle_info({:command_timeout, 2}, state)
    end

    test "the timer fires end-to-end from handle_call/3 with a short timeout" do
      from = {self(), make_ref()}
      state = base_state(%{ready: true, connection_pid: self(), next_id: 1})

      {:noreply, state} = EventPusher.handle_call({:command, %{"type" => "x"}, 5}, from, state)

      assert_receive {:command_timeout, 1}, 200
      assert {:noreply, new_state} = EventPusher.handle_info({:command_timeout, 1}, state)
      assert new_state.pending == %{}
    end
  end

  describe "in-flight commands are failed whenever the connection goes away" do
    test "a fresh connection replies {:error, :disconnected} to every pending request" do
      ref_a = make_ref()
      ref_b = make_ref()
      timer_a = Process.send_after(self(), :never, 60_000)
      timer_b = Process.send_after(self(), :never, 60_000)

      state =
        base_state(%{
          connection_pid: self(),
          ready: true,
          next_id: 9,
          pending: %{1 => {{self(), ref_a}, timer_a}, 2 => {{self(), ref_b}, timer_b}}
        })

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :connected, self()}, state)

      assert_receive {^ref_a, {:error, :disconnected}}
      assert_receive {^ref_b, {:error, :disconnected}}
      assert new_state.pending == %{}
      assert new_state.next_id == 9
    end

    test "the connection dying replies {:error, :disconnected} to every pending request" do
      ref = Process.monitor(self())
      caller_ref = make_ref()
      timer = Process.send_after(self(), :never, 60_000)

      state =
        base_state(%{
          connection_pid: self(),
          monitor_ref: ref,
          ready: true,
          backoff_ms: 5,
          pending: %{1 => {{self(), caller_ref}, timer}}
        })

      assert {:noreply, new_state} =
               EventPusher.handle_info({:DOWN, ref, :process, self(), :killed}, state)

      assert_receive {^caller_ref, {:error, :disconnected}}
      assert new_state.pending == %{}
    end
  end

  describe "stale {:command_timeout, id} messages (PR #13 review round 4)" do
    # `Process.cancel_timer/1` cannot unsend a message that already went
    # out, so a timeout for a request that has just been resolved can be
    # sitting in the mailbox. Both halves of the fix are asserted here: the
    # message is drained, and ids never repeat anyway.
    defp already_fired_timer(id) do
      timer = Process.send_after(self(), {:command_timeout, id}, 0)
      assert_receive {:command_timeout, ^id}, 200
      # Put it back: the manager is being driven inside THIS process, so
      # this mailbox is the one `cancel_timeout/2` drains.
      send(self(), {:command_timeout, id})
      timer
    end

    test "fail_pending drains an already-delivered timeout instead of leaving it queued" do
      caller_ref = make_ref()
      timer = already_fired_timer(1)

      state =
        base_state(%{
          connection_pid: self(),
          ready: true,
          next_id: 2,
          pending: %{1 => {{self(), caller_ref}, timer}}
        })

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_connection, :connected, self()}, state)

      assert_receive {^caller_ref, {:error, :disconnected}}
      assert new_state.pending == %{}
      refute_received {:command_timeout, 1}
    end

    test "a resolved result drains its own already-delivered timeout" do
      caller_ref = make_ref()
      timer = already_fired_timer(4)
      state = base_state(%{pending: %{4 => {{self(), caller_ref}, timer}}})

      assert {:noreply, new_state} =
               EventPusher.handle_info({:event_pusher_result, 4, {:ok, :done}}, state)

      assert_receive {^caller_ref, {:ok, :done}}
      assert new_state.pending == %{}
      refute_received {:command_timeout, 4}
    end

    test "a command issued after a reconnect never reuses the previous id" do
      caller_ref = make_ref()
      timer = already_fired_timer(1)

      state =
        base_state(%{
          connection_pid: self(),
          ready: true,
          next_id: 2,
          pending: %{1 => {{self(), caller_ref}, timer}}
        })

      # Reconnect: pending fails, the id counter carries on.
      {:noreply, state} =
        EventPusher.handle_info({:event_pusher_connection, :connected, self()}, state)

      assert_receive {^caller_ref, {:error, :disconnected}}

      {:noreply, state} =
        EventPusher.handle_info({:event_pusher_connection, :ready, self()}, state)

      from = {self(), make_ref()}

      assert {:noreply, new_state} =
               EventPusher.handle_call(
                 {:command, %{"type" => "config/auth/list"}, 5_000},
                 from,
                 state
               )

      assert received_frame()["id"] == 2
      refute Map.has_key?(new_state.pending, 1)
      assert Map.has_key?(new_state.pending, 2)
    end
  end

  describe "command/2" do
    test "returns {:error, :not_started} when the manager isn't running" do
      assert EventPusher.command(%{"type" => "config/auth/list"},
               server: :vagus_event_pusher_absent
             ) == {:error, :not_started}
    end
  end
end
