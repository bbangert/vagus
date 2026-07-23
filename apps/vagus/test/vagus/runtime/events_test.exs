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
end
