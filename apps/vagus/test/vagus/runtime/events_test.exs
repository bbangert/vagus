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
    "/tmp/vagus-ev-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
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

  describe "gaps and reconnects (FakeEngine model)" do
    alias Vagus.Test.FakeEngine
    alias Vagus.Test.FakeEngine.Model

    @describetag :capture_log

    setup do
      engine = FakeEngine.start_model()
      on_exit(fn -> FakeEngine.stop(engine) end)
      %{engine: engine}
    end

    # Retries within milliseconds, and never treats a stream as settled.
    defp start_stream(engine, opts \\ []) do
      name = unique_name()
      opts = Keyword.merge([backoff: {5, 20}, stable_after: 60_000], opts)
      pid = start_supervised!({Events, [name: name, socket: engine.socket] ++ opts})
      :ok = Events.subscribe(name)
      assert_receive {:docker_events, :gap}, 2_000
      pid
    end

    # Ends the stream and returns once the worker is on a new one.
    defp reconnect(engine, how \\ :abort) do
      Model.drop_event_streams(engine, how)
      assert_receive {:docker_events, :gap}, 2_000
    end

    defp event_requests(engine),
      do: for(%{path: "/events"} = request <- FakeEngine.requests(engine), do: request.query)

    # Everything delivered up to an event emitted now. The worker sends in
    # the order it reads, so nothing that was to come before it is missing.
    defp events_so_far(engine) do
      Model.emit(engine, "sentinel", "app_sentinel")
      collect_events()
    end

    defp collect_events do
      receive do
        {:docker_event, %{name: "app_sentinel"}} -> []
        {:docker_event, event} -> [{event.action, event.name} | collect_events()]
      after
        2_000 -> flunk("the sentinel event never came")
      end
    end

    test "a subscriber is told of a gap once when the first stream is established", %{
      engine: engine
    } do
      start_stream(engine)
      assert events_so_far(engine) == []
      refute_received {:docker_events, :gap}
    end

    test "a subscriber joining an established stream is told of a gap at once", %{engine: engine} do
      pid = start_stream(engine)

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

    test "subscribing twice is one subscription: one notice, each event once", %{engine: engine} do
      pid = start_stream(engine)
      :ok = Events.subscribe(pid)

      Model.emit(engine, "start", "app_a")

      assert events_so_far(engine) == [{"start", "app_a"}]
      refute_received {:docker_events, :gap}
      refute_received {:docker_event, _twice}
    end

    test "an unsubscribed process gets nothing more", %{engine: engine} do
      pid = start_stream(engine)
      test = self()

      # Stays subscribed, and tells this process what it was sent: once it
      # has an event, the worker has sent that event to everyone it would.
      spawn_link(fn ->
        :ok = Events.subscribe(pid)
        send(test, :relay_ready)

        receive do
          {:docker_event, event} -> send(test, {:relayed, event.name})
        end
      end)

      assert_receive :relay_ready, 2_000
      assert :ok = Events.unsubscribe(pid)
      assert :ok = Events.unsubscribe(pid)

      Model.emit(engine, "start", "app_a")

      assert_receive {:relayed, "app_a"}, 2_000
      refute_received {:docker_event, _event}
    end

    test "every reconnect is followed by a gap notice, and asks for no replay", %{engine: engine} do
      start_stream(engine)

      reconnect(engine)
      reconnect(engine)

      assert [first, second, third] = event_requests(engine)
      assert Map.keys(first) == ["filters"]
      assert second == first and third == first
    end

    test "a stream the engine ends properly is reconnected like a broken one", %{engine: engine} do
      start_stream(engine)

      reconnect(engine, :finish)
      Model.emit(engine, "start", "app_a")

      assert events_so_far(engine) == [{"start", "app_a"}]
    end

    test "half a line left by a drop is not joined to the next stream", %{engine: engine} do
      start_stream(engine)

      reconnect(engine, {:mid_line, "die", "app_half"})
      Model.emit(engine, "start", "app_a")

      assert events_so_far(engine) == [{"start", "app_a"}]
    end

    test "a restart by the engine's policy arrives as die, then start", %{engine: engine} do
      start_stream(engine)
      Model.put_container(engine, "homeassistant", restart_policy: "unless-stopped")

      Model.crash(engine, "homeassistant", 1)

      assert events_so_far(engine) == [{"die", "homeassistant"}, {"start", "homeassistant"}]
    end

    test "events for app_, addon_ and Core's container are forwarded, others are not", %{
      engine: engine
    } do
      start_stream(engine)

      for name <- [
            "bystander",
            "app_new",
            "my_app_x",
            "addon_old",
            "application",
            "homeassistant",
            "homeassistant2"
          ],
          do: Model.emit(engine, "start", name)

      assert events_so_far(engine) == [
               {"start", "app_new"},
               {"start", "addon_old"},
               {"start", "homeassistant"}
             ]
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
      pid = start_stream(engine, backoff: {5, 1_000})

      reconnect(engine)
      reconnect(engine)

      # 5 ms and 10 ms were waited; the next wait is 20 ms.
      assert :sys.get_state(pid).backoff_ms == 20
    end

    test "a stream that has lasted puts the back-off back to its start", %{engine: engine} do
      pid = start_stream(engine, backoff: {5, 1_000}, stable_after: 100)
      :erlang.trace(pid, true, [:receive])

      # Whether or not the first stream lasted, one drop from the start
      # leaves the next wait doubled.
      reconnect(engine)
      %{request_ref: stream, backoff_ms: 10} = :sys.get_state(pid)

      # The worker's own timer for the stream now open, read by the worker.
      assert_receive {:trace, ^pid, :receive, {:stable, ^stream}}, 2_000
      assert :sys.get_state(pid).backoff_ms == 5
    end

    test "the lasted-timer of a stream since dropped resets nothing", %{engine: engine} do
      pid = start_stream(engine, backoff: {5, 1_000})
      stale = :sys.get_state(pid).request_ref
      reconnect(engine)

      send(pid, {:stable, stale})
      assert :sys.get_state(pid).backoff_ms == 10
    end

    test "an engine that is away is retried by the same process, at a capped pace" do
      name = unique_name()

      pid =
        start_supervised!({Events, name: name, socket: FakeEngine.socket_path(), backoff: {1, 4}})

      :erlang.trace(pid, true, [:receive])

      for _ <- 1..6, do: assert_receive({:trace, ^pid, :receive, :connect}, 2_000)

      assert Process.whereis(name) == pid
      assert :sys.get_state(pid).backoff_ms == 4
    end
  end

  describe "answers that are not a stream (scripted FakeEngine)" do
    import ExUnit.CaptureLog

    alias Vagus.Test.FakeEngine

    defp event_line(action, name, actor \\ nil) do
      Jason.encode!(%{
        "Type" => "container",
        "Action" => action,
        "Actor" => actor || %{"ID" => "id-" <> name, "Attributes" => %{"name" => name}}
      }) <> "\n"
    end

    test "a refusal is logged with its status, its body is no event, and the retry follows" do
      engine =
        FakeEngine.start([
          # What a careless reader would take for an event of ours.
          {500, event_line("die", "app_refused")},
          {:stream, 200, [{:chunk, event_line("start", "app_a")}, :stall]}
        ])

      on_exit(fn -> FakeEngine.stop(engine) end)
      name = unique_name()

      log =
        capture_log(fn ->
          start_supervised!({Events, name: name, socket: engine.socket, backoff: {5, 20}})
          :ok = Events.subscribe(name)
          assert_receive {:docker_event, %{name: "app_a"}}, 2_000
        end)

      assert log =~ "stream dropped ({:status, 500})"
      refute_received {:docker_event, %{name: "app_refused"}}
      # One stream was established, the second.
      assert_received {:docker_events, :gap}
      refute_received {:docker_events, :gap}
    end

    @tag :capture_log
    test "an event whose actor is not what it should be is passed over, and the worker lives" do
      lines =
        event_line("die", "app_x", "not a map") <>
          event_line("die", "app_y", %{"ID" => "y", "Attributes" => ["not", "a", "map"]}) <>
          "[1, 2]\n" <>
          "not json\n" <>
          event_line("start", "app_a")

      engine = FakeEngine.start([{:stream, 200, [{:chunk, lines}, :stall]}])
      on_exit(fn -> FakeEngine.stop(engine) end)
      name = unique_name()
      pid = start_supervised!({Events, name: name, socket: engine.socket})
      :ok = Events.subscribe(name)

      assert_receive {:docker_event, %{name: "app_a", action: "start"}}, 2_000
      refute_received {:docker_event, _other}
      assert Process.whereis(name) == pid
    end
  end

  describe "how the stream is cut up (inline daemon)" do
    defp timed(action, id, nano) do
      Jason.encode!(%{
        "Action" => action,
        "Type" => "container",
        "Actor" => %{"ID" => id, "Attributes" => %{"name" => "app_" <> id}},
        "timeNano" => nano
      }) <> "\n"
    end

    # The gap between two writes is what makes them two reads; were they
    # read as one, the test would still pass and prove nothing.
    defp send_apart(sock, parts) do
      for part <- parts do
        :ok = :gen_tcp.send(sock, part)
        Process.sleep(20)
      end
    end

    defp framed(binary),
      do: Integer.to_string(byte_size(binary), 16) <> "\r\n" <> binary <> "\r\n"

    setup %{path: path, listen: listen} do
      start_events(unique_name(), path)
      {sock, _head} = accept_conn(listen)
      send_ok_headers(sock)
      %{sock: sock}
    end

    test "events that share a time, or have none, are each delivered", %{sock: sock} do
      untimed = String.replace(timed("die", "c", 0), ~s(,"timeNano":0), "")
      send_chunk(sock, timed("die", "a", 5) <> timed("die", "b", 5) <> untimed)

      assert_receive {:docker_event, %{action: "die", name: "app_a", time_nano: 5}}, 1_000
      assert_receive {:docker_event, %{action: "die", name: "app_b", time_nano: 5}}, 1_000
      assert_receive {:docker_event, %{action: "die", name: "app_c", time_nano: nil}}, 1_000
    end

    # An event line of exactly `bytes` bytes, its newline not counted.
    defp padded(id, bytes) do
      event = fn pad ->
        Jason.encode!(%{
          "Action" => "die",
          "Type" => "container",
          "Actor" => %{"ID" => id, "Attributes" => %{"name" => "app_" <> id, "pad" => pad}}
        })
      end

      event.(String.duplicate("x", bytes - byte_size(event.(""))))
    end

    @tag :capture_log
    test "a line over a megabyte is dropped though it ends, and one of exactly that is not", %{
      sock: sock
    } do
      send_chunk(sock, padded("big", 1_048_577) <> "\n")
      send_chunk(sock, padded("fits", 1_048_576) <> "\n")

      # In the order the worker read them: the first was not passed on.
      assert_receive {:docker_event, %{name: name}}, 2_000
      assert name == "app_fits"
    end

    # A line one byte over the cap and still without its end: the worker has
    # refused it, and holds nothing of it, when the next read comes. Each
    # part after it is a read of its own (see `send_apart/2`).
    defp after_refusal(sock, parts) do
      send_chunk(sock, String.duplicate("x", 1_048_577))
      Process.sleep(50)
      send_apart(sock, Enum.map(parts, &framed/1))
    end

    @tag :capture_log
    test "nothing of a line that outgrew the cap is read, though its end looks like an event", %{
      sock: sock
    } do
      # The end of that line: text that by itself would be an event of ours.
      tail = String.trim_trailing(timed("die", "tail", 1), "\n")
      after_refusal(sock, [tail <> "\n" <> timed("start", "next", 2)])

      assert_receive {:docker_event, %{name: name}}, 2_000
      assert name == "app_next"
    end

    @tag :capture_log
    test "a line that outgrew the cap is skipped to its newline, however many reads away", %{
      sock: sock
    } do
      tail = String.trim_trailing(timed("die", "tail", 1), "\n")
      after_refusal(sock, ["still the same line", tail <> "\n" <> timed("start", "next", 2)])

      assert_receive {:docker_event, %{name: name}}, 2_000
      assert name == "app_next"
    end

    @tag :capture_log
    test "a new stream starts clean of a line the old one was skipping", %{
      sock: sock,
      listen: listen
    } do
      after_refusal(sock, [])
      :gen_tcp.close(sock)

      # The default back-off: a second.
      {again, _head} = accept_conn(listen, 5_000)
      send_ok_headers(again)
      send_chunk(again, timed("start", "next", 2) <> timed("die", "after", 3))

      assert_receive {:docker_event, %{name: name}}, 2_000
      assert name == "app_next"
    end

    test "an event the engine sends twice is delivered twice", %{sock: sock} do
      send_chunk(sock, timed("die", "a", 5) <> timed("die", "a", 5) <> timed("start", "z", 6))

      assert_receive {:docker_event, %{action: "die", name: "app_a"}}, 1_000
      assert_receive {:docker_event, %{action: "die", name: "app_a"}}, 1_000
      assert_receive {:docker_event, %{name: "app_z"}}, 1_000
    end

    test "lines ending in CR LF are lines", %{sock: sock} do
      send_chunk(
        sock,
        String.replace(timed("die", "a", 1) <> timed("start", "a", 2), "\n", "\r\n")
      )

      assert_receive {:docker_event, %{action: "die", name: "app_a"}}, 1_000
      assert_receive {:docker_event, %{action: "start", name: "app_a"}}, 1_000
    end

    test "a read may end between the CR and the LF", %{sock: sock} do
      line = String.trim_trailing(timed("die", "a", 1), "\n")
      send_apart(sock, [framed(line <> "\r"), framed("\n" <> timed("start", "a", 2))])

      assert_receive {:docker_event, %{action: "die", name: "app_a"}}, 1_000
      assert_receive {:docker_event, %{action: "start", name: "app_a"}}, 1_000
    end

    test "a read may end inside the line that gives a chunk's size", %{sock: sock} do
      line = timed("die", "a", 1) <> String.duplicate(" ", 300)
      <<first, rest::binary>> = framed(line <> "\n")
      send_apart(sock, [<<first>>, rest])

      assert_receive {:docker_event, %{action: "die", name: "app_a"}}, 1_000
    end

    test "a read may end inside a character", %{sock: sock} do
      line = timed("die", "é", 1)
      [before, rest] = :binary.split(line, <<0xA9>>)
      send_apart(sock, [framed(before), framed(<<0xA9>> <> rest)])

      assert_receive {:docker_event, %{action: "die", name: "app_é"}}, 1_000
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
