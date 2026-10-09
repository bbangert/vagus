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

  describe "app processes" do
    import Vagus.AppFixtures, only: [app_config: 2, app_info: 1, install_app: 1]

    defp app_slug, do: "events_app_#{System.unique_integer([:positive])}"

    defp app_pid(slug) do
      [{pid, _}] = Registry.lookup(Vagus.App.Directory, {:slug, slug})
      pid
    end

    test "an app's container event goes to whichever process holds its slug when sent", %{
      path: path,
      listen: listen
    } do
      slug = app_slug()
      start_supervised!({Events, name: unique_name(), socket: path})
      {sock, _head} = accept_conn(listen)
      send_ok_headers(sock)

      {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
      send_chunk(sock, event_json("die", "addon_" <> slug, "c1") <> "\n")
      assert_receive {:docker_event, %{action: "die", id: "c1"}}, 1_000

      # A restarted app process is found by the next event, with no subscribe.
      :ok = Registry.unregister(Vagus.App.Directory, {:slug, slug})
      test = self()

      owner =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
          send(test, :registered)

          receive do
            event -> send(test, {:owner_got, event})
          end
        end)

      assert_receive :registered
      send_chunk(sock, event_json("start", "addon_" <> slug, "c2") <> "\n")
      assert_receive {:owner_got, {:docker_event, %{action: "start", id: "c2"}}}, 1_000
      refute_received {:docker_event, %{id: "c2"}}
      assert is_pid(owner)
    end

    test "each connect lists the app containers and tells each app process its state", %{
      path: path,
      listen: listen
    } do
      slug = app_slug()
      install_app(app_config(slug, %{}))
      pid = app_pid(slug)
      {:ok, listings} = Agent.start_link(fn -> [] end)

      list = fn _socket ->
        Agent.get_and_update(listings, fn
          [] ->
            {{:ok, [container("/addon_" <> slug, "c1", "running", "Up 2 minutes")]}, [:first]}

          seen ->
            {{:ok,
              [
                container("/addon_" <> slug, "c1", "exited", "Exited (137) 1 second ago"),
                container("/not_an_app", "x", "running", "Up")
              ]}, [:again | seen]}
        end)
      end

      # The app process's receipt of each synthesized event is traced, so
      # whatever the test asks it next is handled after that event.
      :erlang.trace(pid, true, [:receive])
      on_exit(fn -> :erlang.trace(pid, false, [:receive]) end)
      start_supervised!({Events, name: unique_name(), socket: path, list: list})

      # The first connect: a running container this process did not start is
      # adopted as its own.
      {sock1, _head} = accept_conn(listen)
      send_ok_headers(sock1)

      assert_receive {:trace, ^pid, :receive, {:docker_event, %{action: "start", id: "c1"}}},
                     1_000

      assert {:ok, %{state: :started}} = app_info(slug)
      assert %{container_id: "c1"} = :sys.get_state(pid) |> elem(1)

      # The container died while the stream was down: the reconnect tells it.
      :gen_tcp.close(sock1)
      {sock2, _head} = accept_conn(listen, 5_000)
      send_ok_headers(sock2)

      assert_receive {:trace, ^pid, :receive,
                      {:docker_event, %{action: "die", id: "c1", exit_code: 137}}},
                     5_000

      assert {:ok, %{state: :error}} = app_info(slug)
      assert %{last_event: {:exited, 137}} = :sys.get_state(pid) |> elem(1)
      assert Agent.get(listings, & &1) == [:again, :first]
    end

    test "a listing that fails leaves the stream running", %{path: path, listen: listen} do
      test = self()
      list = fn _socket -> send(test, :listed) && {:error, :down} end
      name = unique_name()
      start_supervised!({Events, name: name, socket: path, list: list})
      :ok = Events.subscribe(name)

      {sock, _head} = accept_conn(listen)
      send_ok_headers(sock)
      assert_receive :listed, 1_000

      send_chunk(sock, event_json("start", "addon_after", "a1") <> "\n")
      assert_receive {:docker_event, %{id: "a1"}}, 1_000
    end

    test "a live event that arrives while the listing runs is sent after the listing's", %{
      path: path,
      listen: listen
    } do
      slug = app_slug()
      owner = owner(slug)
      name = unique_name()
      start_supervised!({Events, name: name, socket: path, list: held_listing(self())})
      :ok = Events.subscribe(name)

      {sock, _head} = accept_conn(listen)
      send_ok_headers(sock)
      assert_receive {:listing, lister}, 1_000

      send_chunk(sock, event_json("start", "addon_" <> slug, "c1") <> "\n")
      assert_receive {:docker_event, %{action: "start", id: "c1"}}, 1_000

      send(
        lister,
        {:go, [container("/addon_" <> slug, "c1", "exited", "Exited (1) 1 second ago")]}
      )

      assert_receive {:owner_got, %{action: first, id: "c1"}}, 1_000
      assert_receive {:owner_got, %{action: last, id: "c1"}}, 1_000
      assert {first, last} == {"die", "start"}
      assert ping(owner) == :pong
      refute_received {:owner_got, _}
    end

    test "a listing from an earlier connection is dropped", %{path: path, listen: listen} do
      slug = app_slug()
      owner = owner(slug)

      events =
        start_supervised!({Events, name: unique_name(), socket: path, list: held_listing(self())})

      {sock1, _head} = accept_conn(listen)
      send_ok_headers(sock1)
      assert_receive {:listing, old}, 1_000
      :gen_tcp.close(sock1)

      {sock2, _head} = accept_conn(listen, 5_000)
      send_ok_headers(sock2)
      assert_receive {:listing, new}, 5_000

      # Answered while the new connection's listing still runs.
      ref = Process.monitor(old)
      send(old, {:go, [container("/addon_" <> slug, "c1", "exited", "Exited (1) 1 second ago")]})
      assert_receive {:DOWN, ^ref, :process, ^old, :normal}, 1_000
      _ = :sys.get_state(events)
      assert ping(owner) == :pong
      refute_received {:owner_got, _}

      send(new, {:go, [container("/addon_" <> slug, "c2", "running", "Up 1 second")]})
      assert_receive {:owner_got, %{action: "start", id: "c2"}}, 1_000
      assert ping(owner) == :pong
      refute_received {:owner_got, _}
    end

    test "a listing that dies lets go of the live events it held back", %{
      path: path,
      listen: listen
    } do
      slug = app_slug()
      owner = owner(slug)
      name = unique_name()
      start_supervised!({Events, name: name, socket: path, list: held_listing(self())})
      :ok = Events.subscribe(name)

      {sock, _head} = accept_conn(listen)
      send_ok_headers(sock)
      assert_receive {:listing, lister}, 1_000
      send_chunk(sock, event_json("start", "addon_" <> slug, "c1") <> "\n")
      assert_receive {:docker_event, %{action: "start", id: "c1"}}, 1_000

      ExUnit.CaptureLog.capture_log(fn ->
        ref = Process.monitor(lister)
        Process.exit(lister, :kill)
        assert_receive {:DOWN, ^ref, :process, ^lister, :killed}
        assert_receive {:owner_got, %{action: "start", id: "c1"}}, 1_000
      end)

      assert ping(owner) == :pong
    end

    defp held_listing(test) do
      fn _socket ->
        send(test, {:listing, self()})

        receive do
          {:go, containers} -> {:ok, containers}
        end
      end
    end

    # Registered as the app process, it forwards each event it is routed.
    defp owner(slug) do
      test = self()

      pid =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
          send(test, :registered)
          forward(test)
        end)

      assert_receive :registered
      pid
    end

    defp forward(test) do
      receive do
        {:docker_event, payload} -> send(test, {:owner_got, payload})
        {:ping, from} -> send(from, :pong)
      end

      forward(test)
    end

    # Every routed event the process was sent is forwarded before the reply.
    defp ping(owner) do
      send(owner, {:ping, self()})
      assert_receive :pong, 1_000
      :pong
    end

    defp container(name, id, state, status),
      do: %{"Id" => id, "Names" => [name], "State" => state, "Status" => status}
  end

  describe "schedule_reconnect/2" do
    import ExUnit.CaptureLog

    defp drop_state(backoff_ms) do
      %{
        conn: :conn,
        request_ref: make_ref(),
        buffer: "x",
        backoff_ms: backoff_ms,
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
  end
end
