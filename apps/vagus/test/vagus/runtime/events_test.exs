defmodule Vagus.Runtime.EventsTest do
  @moduledoc """
  Hermetic tests for the docker-events streaming client — a fake unix-socket
  HTTP server stands in for the daemon (no real docker/balena-engine
  required), speaking just enough HTTP/1.1 chunked framing to drive
  `Vagus.Runtime.Events`'s reconnect/buffering logic.
  """

  use ExUnit.Case, async: false

  alias Vagus.Runtime.Events

  ## Fake unix-socket daemon helpers

  defp socket_path do
    "/tmp/vagus-ev-#{System.unique_integer([:positive])}.sock"
  end

  defp start_fake_server(path) do
    # rm first: a leftover socket file from a previous run collides
    # (:eaddrinuse) — pre-existing latent flake, fixed alongside
    # logs/follow_test.exs which inherited this helper.
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :raw,
        backlog: 1
      ])

    listen
  end

  defp accept_conn(listen, timeout \\ 3_000) do
    {:ok, sock} = :gen_tcp.accept(listen, timeout)
    head = read_request_head(sock, "")
    {sock, head}
  end

  defp read_request_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      read_request_head(sock, acc <> data)
    end
  end

  defp send_ok_headers(sock) do
    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
  end

  defp send_chunk(sock, binary) do
    size_hex = binary |> byte_size() |> Integer.to_string(16)
    :ok = :gen_tcp.send(sock, size_hex <> "\r\n" <> binary <> "\r\n")
  end

  ## Event fixtures

  defp event_json(action, name, id, attrs_extra \\ %{}) do
    attributes = Map.merge(%{"name" => name}, attrs_extra)

    Jason.encode!(%{
      "Action" => action,
      "Type" => "container",
      "Actor" => %{"ID" => id, "Attributes" => attributes},
      "timeNano" => 1_700_000_000_000_000_000
    })
  end

  defp unique_name, do: :"events_#{System.unique_integer([:positive])}"

  defp start_events(name, socket_path) do
    pid = start_supervised!({Events, name: name, socket: socket_path})
    :ok = Events.subscribe(name)
    pid
  end

  ## Polling helper (no fixed sleeps for eventual-consistency assertions)

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  setup do
    path = socket_path()
    listen = start_fake_server(path)
    on_exit(fn -> :gen_tcp.close(listen) end)
    on_exit(fn -> File.rm(path) end)
    %{path: path, listen: listen}
  end

  test "subscriber receives a die event with parsed exit_code, action/name/id intact", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    start_events(name, path)

    {sock, _head} = accept_conn(listen)
    send_ok_headers(sock)

    line =
      event_json("die", "addon_foo", "abc123", %{
        "exitCode" => "137",
        "supervisor_managed" => ""
      }) <> "\n"

    send_chunk(sock, line)

    assert_receive {:docker_event, event}, 1_000
    assert event.action == "die"
    assert event.name == "addon_foo"
    assert event.id == "abc123"
    assert event.exit_code == 137
    assert event.time_nano == 1_700_000_000_000_000_000
    assert event.attributes["exitCode"] == "137"
  end

  test "an unmanaged container event (no label, non-addon name) is not forwarded", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    start_events(name, path)

    {sock, _head} = accept_conn(listen)
    send_ok_headers(sock)

    unmanaged = event_json("die", "unrelated-container", "zzz999") <> "\n"
    send_chunk(sock, unmanaged)

    refute_receive {:docker_event, _}, 300

    # sentinel: a managed event on the same stream still gets through, proving
    # the stream/subscriber weren't wedged by the filtered-out event above.
    managed =
      event_json("start", "addon_bar", "def456", %{"supervisor_managed" => ""}) <> "\n"

    send_chunk(sock, managed)

    assert_receive {:docker_event, %{name: "addon_bar", action: "start"}}, 1_000
  end

  test "a Core-named container event (no label) is forwarded — Core-name pass-through", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    start_events(name, path)

    {sock, _head} = accept_conn(listen)
    send_ok_headers(sock)

    # The adopted Core container: name "homeassistant", NO supervisor_managed
    # label, exit code as docker sends it (string attribute).
    line = event_json("die", Vagus.Core.Container.name(), "core01", %{"exitCode" => "1"}) <> "\n"
    send_chunk(sock, line)

    assert_receive {:docker_event, event}, 1_000
    assert event.name == Vagus.Core.Container.name()
    assert event.action == "die"
    assert event.exit_code == 1

    # sentinel: an unlabeled non-Core, non-addon name on the same stream is
    # still dropped — the pass-through is exact-name, not a general loosening.
    send_chunk(sock, event_json("die", "homeassistant-imposter", "imp01") <> "\n")
    refute_receive {:docker_event, %{name: "homeassistant-imposter"}}, 300
  end

  test "a JSON object split across two chunk frames/writes is reassembled", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    start_events(name, path)

    {sock, _head} = accept_conn(listen)
    send_ok_headers(sock)

    line =
      event_json("die", "addon_split", "split1", %{
        "exitCode" => "1",
        "supervisor_managed" => ""
      }) <> "\n"

    midpoint = div(byte_size(line), 2)
    <<part1::binary-size(^midpoint), part2::binary>> = line

    send_chunk(sock, part1)
    Process.sleep(20)
    send_chunk(sock, part2)

    assert_receive {:docker_event, event}, 1_000
    assert event.name == "addon_split"
    assert event.action == "die"
    assert event.exit_code == 1
  end

  test "health_status: unhealthy action passes through verbatim", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    start_events(name, path)

    {sock, _head} = accept_conn(listen)
    send_ok_headers(sock)

    line =
      event_json("health_status: unhealthy", "addon_health", "health1", %{
        "supervisor_managed" => ""
      }) <> "\n"

    send_chunk(sock, line)

    assert_receive {:docker_event, %{action: "health_status: unhealthy", name: "addon_health"}},
                   1_000
  end

  test "server closing the connection triggers a reconnect; subscriber keeps receiving", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    start_events(name, path)

    {sock1, _head1} = accept_conn(listen)
    send_ok_headers(sock1)
    :gen_tcp.close(sock1)

    # Default backoff starts at 1s — allow generous headroom for the retry.
    {sock2, head2} = accept_conn(listen, 5_000)
    assert head2 =~ "GET /events"
    send_ok_headers(sock2)

    line =
      event_json("start", "addon_reco", "reco1", %{"supervisor_managed" => ""}) <> "\n"

    send_chunk(sock2, line)

    assert_receive {:docker_event, %{name: "addon_reco", action: "start"}}, 1_000
  end

  test "a dead subscriber is pruned and does not crash the server", %{
    path: path,
    listen: listen
  } do
    name = unique_name()
    events_pid = start_supervised!({Events, name: name, socket: path})

    task = Task.async(fn -> Events.subscribe(name) end)
    dead_pid = task.pid
    Task.await(task)

    wait_until(fn ->
      %{subscribers: subs} = :sys.get_state(events_pid)
      not Map.has_key?(subs, dead_pid)
    end)

    {sock, _head} = accept_conn(listen)
    send_ok_headers(sock)

    line = event_json("start", "addon_alive", "alive1", %{"supervisor_managed" => ""}) <> "\n"
    send_chunk(sock, line)

    # No subscriber left to receive it — just prove nothing crashed.
    Process.sleep(100)
    assert Process.alive?(events_pid)
  end

  describe "gaps, resuming and replays (FakeEngine model)" do
    alias Vagus.Test.FakeEngine
    alias Vagus.Test.FakeEngine.Model

    @describetag :capture_log

    setup do
      engine = FakeEngine.start_model(ring: 4)
      on_exit(fn -> FakeEngine.stop(engine) end)
      %{engine: engine}
    end

    # Retries within milliseconds, and never treats a stream as settled.
    defp start_resuming(engine, opts \\ []) do
      name = unique_name()
      opts = Keyword.merge([backoff: {5, 20}, stable_after: 60_000], opts)
      pid = start_supervised!({Events, [name: name, socket: engine.socket] ++ opts})
      :ok = Events.subscribe(name)
      assert_receive {:docker_events, :gap}, 2_000
      pid
    end

    # Drops the stream and returns once the worker is on a new one.
    defp reconnect(engine) do
      Model.drop_event_streams(engine)
      assert_receive {:docker_events, :gap}, 2_000
    end

    defp event_requests(engine),
      do: for(%{path: "/events"} = request <- FakeEngine.requests(engine), do: request.query)

    defp received_events do
      receive do
        {:docker_event, event} -> [{event.action, event.name} | received_events()]
      after
        100 -> []
      end
    end

    test "a subscriber is told of a gap once when the first stream is established", %{
      engine: engine
    } do
      start_resuming(engine)
      refute_receive {:docker_events, :gap}, 100
    end

    test "a subscriber joining an established stream is told of a gap at once", %{engine: engine} do
      pid = start_resuming(engine)

      task =
        Task.async(fn ->
          :ok = Events.subscribe(pid)

          receive do
            {:docker_events, :gap} -> :told
          after
            2_000 -> :not_told
          end
        end)

      assert Task.await(task) == :told
    end

    test "every reconnect is followed by a gap notice", %{engine: engine} do
      start_resuming(engine)

      reconnect(engine)
      reconnect(engine)

      assert length(event_requests(engine)) == 3
    end

    test "the first request asks for no replay; a reconnect asks since the newest event seen", %{
      engine: engine
    } do
      start_resuming(engine)
      nano = Model.emit(engine, "start", "app_a")
      assert_receive {:docker_event, %{time_nano: ^nano}}, 2_000

      reconnect(engine)

      assert [first, second] = event_requests(engine)
      refute is_map_key(first, "since")

      fraction = nano |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")
      assert second["since"] == "#{div(nano, 1_000_000_000)}.#{fraction}"
    end

    test "an event missed while disconnected is replayed, after the gap notice", %{engine: engine} do
      start_resuming(engine)
      Model.emit(engine, "start", "app_a")
      assert_receive {:docker_event, %{action: "start"}}, 2_000

      Model.drop_event_streams(engine)
      Model.emit(engine, "die", "app_a", %{"exitCode" => "3"})

      # Both come from the worker, so the order they are read in is the
      # order it sent them.
      first =
        receive do
          {:docker_events, :gap} -> :gap
          {:docker_event, %{action: "die"}} -> :event
        after
          2_000 -> flunk("neither a gap notice nor the replayed event")
        end

      assert first == :gap
      assert_receive {:docker_event, %{action: "die", name: "app_a", exit_code: 3}}, 2_000
    end

    test "the replay's copy of an event already delivered is not delivered again", %{
      engine: engine
    } do
      start_resuming(engine)
      Model.emit(engine, "die", "app_a")
      assert_receive {:docker_event, %{action: "die"}}, 2_000

      reconnect(engine)
      Model.emit(engine, "start", "app_a")

      # The engine replayed the die (its replay is inclusive); only what is
      # new comes through.
      assert_receive {:docker_event, %{action: "start"}}, 2_000
      assert received_events() == []
    end

    test "what the engine's ring has dropped is lost, and the gap notice still comes", %{
      engine: engine
    } do
      start_resuming(engine)
      Model.emit(engine, "start", "app_seen")
      assert_receive {:docker_event, %{name: "app_seen"}}, 2_000

      Model.drop_event_streams(engine)
      for n <- 1..6, do: Model.emit(engine, "die", "app_#{n}")

      assert_receive {:docker_events, :gap}, 2_000
      # The ring holds four.
      assert received_events() == for(n <- 3..6, do: {"die", "app_#{n}"})
    end

    test "events for app_, addon_ and Core's container are forwarded, others are not", %{
      engine: engine
    } do
      start_resuming(engine)

      for name <- [
            "bystander",
            "app_new",
            "my_app_x",
            "addon_old",
            "application",
            "homeassistant"
          ],
          do: Model.emit(engine, "start", name)

      assert received_events() == [
               {"start", "app_new"},
               {"start", "addon_old"},
               {"start", "homeassistant"}
             ]
    end

    test "a restart by the engine's policy arrives as die, then start", %{engine: engine} do
      start_resuming(engine)
      Model.put_container(engine, "homeassistant", restart_policy: "unless-stopped")

      Model.crash(engine, "homeassistant", 1)

      assert received_events() == [{"die", "homeassistant"}, {"start", "homeassistant"}]
    end

    test "managed?/2 is the label, the two prefixes, or Core's name" do
      assert Events.managed?("app_x", %{})
      assert Events.managed?("addon_x", %{})
      assert Events.managed?(Vagus.Core.Container.name(), %{})
      assert Events.managed?("anything", %{"supervisor_managed" => ""})

      refute Events.managed?("application", %{})
      refute Events.managed?("my_app_x", %{})
      refute Events.managed?("homeassistant2", %{})
      refute Events.managed?(nil, %{})
    end

    test "a stream that drops before it has lasted leaves the back-off raised", %{engine: engine} do
      pid = start_resuming(engine, backoff: {5, 1_000})

      reconnect(engine)
      reconnect(engine)

      # 5 ms and 10 ms were waited; the next wait is 20 ms.
      assert :sys.get_state(pid).backoff_ms == 20
    end

    test "a stream that has lasted puts the back-off back to its start", %{engine: engine} do
      pid = start_resuming(engine, backoff: {5, 1_000}, stable_after: 60_000)
      reconnect(engine)
      assert :sys.get_state(pid).backoff_ms == 10

      # The timer's message for the stream now open, without the wait.
      send(pid, {:stable, :sys.get_state(pid).request_ref})
      assert :sys.get_state(pid).backoff_ms == 5
    end

    test "the lasted-timer of a stream since dropped resets nothing", %{engine: engine} do
      pid = start_resuming(engine, backoff: {5, 1_000})
      stale = :sys.get_state(pid).request_ref
      reconnect(engine)

      send(pid, {:stable, stale})
      assert :sys.get_state(pid).backoff_ms == 10
    end

    test "an engine that is away is retried by the same process, at a capped pace" do
      name = unique_name()
      missing = "/tmp/vagus-ev-none-#{System.unique_integer([:positive])}.sock"

      pid = start_supervised!({Events, name: name, socket: missing, backoff: {1, 4}})
      :erlang.trace(pid, true, [:receive])

      for _ <- 1..6, do: assert_receive({:trace, ^pid, :receive, :connect}, 2_000)

      assert Process.whereis(name) == pid
      assert :sys.get_state(pid).backoff_ms == 4
    end
  end

  describe "events that share a time (inline daemon)" do
    defp timed(action, id, nano) do
      Jason.encode!(%{
        "Action" => action,
        "Type" => "container",
        "Actor" => %{"ID" => id, "Attributes" => %{"name" => "app_" <> id}},
        "timeNano" => nano
      }) <> "\n"
    end

    setup %{path: path, listen: listen} do
      start_events(unique_name(), path)
      {sock, _head} = accept_conn(listen)
      send_ok_headers(sock)
      %{sock: sock}
    end

    test "two different events with one timeNano are both delivered", %{sock: sock} do
      send_chunk(sock, timed("die", "a", 5) <> timed("die", "b", 5) <> timed("start", "a", 5))

      assert_receive {:docker_event, %{action: "die", name: "app_a"}}, 1_000
      assert_receive {:docker_event, %{action: "die", name: "app_b"}}, 1_000
      assert_receive {:docker_event, %{action: "start", name: "app_a"}}, 1_000
    end

    test "an event stamped earlier than the newest seen is delivered", %{sock: sock} do
      send_chunk(sock, timed("start", "a", 9) <> timed("die", "b", 7))

      assert_receive {:docker_event, %{action: "start", name: "app_a"}}, 1_000
      assert_receive {:docker_event, %{action: "die", name: "app_b"}}, 1_000
    end

    test "an event with no time is delivered, each time it comes", %{sock: sock} do
      line =
        Jason.encode!(%{
          "Action" => "die",
          "Type" => "container",
          "Actor" => %{"ID" => "a", "Attributes" => %{"name" => "app_a"}}
        }) <> "\n"

      send_chunk(sock, line <> line)

      assert_receive {:docker_event, %{action: "die", time_nano: nil}}, 1_000
      assert_receive {:docker_event, %{action: "die", time_nano: nil}}, 1_000
    end
  end

  describe "schedule_reconnect/2" do
    import ExUnit.CaptureLog

    defp drop_state(backoff_ms) do
      %{
        conn: :conn,
        request_ref: make_ref(),
        buffer: "x",
        backoff: {1_000, 30_000},
        backoff_ms: backoff_ms,
        streaming?: true,
        reconnect_timer: nil
      }
    end

    # handle_responses/2 can schedule on `:done`/`:error` and the stream-error
    # branch then schedules the same drop again: that must arm one timer,
    # warn once and advance the backoff once.
    test "a second schedule for the same drop is a no-op beyond clearing the connection" do
      {state, log} =
        with_log(fn ->
          state = Events.schedule_reconnect(:stream_ended, drop_state(1_000))
          Events.schedule_reconnect({:closed, :again}, %{state | conn: :conn})
        end)

      assert state.backoff_ms == 2_000
      assert is_reference(state.reconnect_timer)
      assert state.conn == nil
      assert length(Regex.scan(~r/docker-events stream dropped/, log)) == 1

      Process.cancel_timer(state.reconnect_timer)
    end

    test "each drop doubles the wait for the next, up to the cap" do
      waits =
        Enum.map_reduce(1..5, %{drop_state(1_000) | backoff: {1_000, 4_000}}, fn _drop, state ->
          {state, _log} = with_log(fn -> Events.schedule_reconnect(:stream_ended, state) end)
          Process.cancel_timer(state.reconnect_timer)
          {state.backoff_ms, %{state | reconnect_timer: nil}}
        end)

      assert elem(waits, 0) == [2_000, 4_000, 4_000, 4_000, 4_000]
    end
  end
end
