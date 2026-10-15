defmodule Vagus.Runtime.Engine.Docker.EventSourceTest do
  # The Mint path, through `Vagus.Runtime.Events`, against a unix-socket
  # server speaking just enough chunked HTTP/1.1.
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Engine.Docker.EventSource
  alias Vagus.Runtime.Engine.Event
  alias Vagus.Runtime.Events

  setup ctx do
    path = "/tmp/vagus-ev-#{System.unique_integer([:positive])}.sock"
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        active: false,
        packet: :raw,
        backlog: 1
      ])

    on_exit(fn -> :gen_tcp.close(listen) end)
    on_exit(fn -> File.rm(path) end)

    unless ctx[:own_events] do
      name = :"events_#{System.unique_integer([:positive])}"
      start_supervised!({Events, name: name, source: EventSource, engine_opts: [socket: path]})
      :ok = Events.subscribe(name)
    end

    %{listen: listen, path: path}
  end

  defp accept_conn(listen, timeout \\ 3_000) do
    {:ok, sock} = :gen_tcp.accept(listen, timeout)
    head = read_request_head(sock, "")

    :ok =
      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
      )

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

  defp send_chunk(sock, binary) do
    size_hex = binary |> byte_size() |> Integer.to_string(16)
    :ok = :gen_tcp.send(sock, size_hex <> "\r\n" <> binary <> "\r\n")
  end

  defp event_json(action, name, id, attrs_extra \\ %{}, type \\ "container") do
    Jason.encode!(%{
      "Action" => action,
      "Type" => type,
      "Actor" => %{"ID" => id, "Attributes" => Map.merge(%{"name" => name}, attrs_extra)},
      "timeNano" => 1_700_000_000_000_000_000
    }) <> "\n"
  end

  test "asks for container events only, and normalizes a die", %{listen: listen} do
    {sock, head} = accept_conn(listen)
    assert head =~ "GET /events?filters=" <> URI.encode_www_form(~s({"type":["container"]}))

    send_chunk(
      sock,
      event_json("die", "unlabelled", "abc123", %{
        "exitCode" => "137",
        "supervisor_managed" => ""
      })
    )

    assert_receive {:engine_event, event}, 1_000

    assert event == %Event{
             action: :die,
             name: "unlabelled",
             id: "abc123",
             exit_code: 137,
             time_ns: 1_700_000_000_000_000_000,
             managed: true
           }
  end

  test "a line split across chunks is reassembled", %{listen: listen} do
    {sock, _head} = accept_conn(listen)
    line = event_json("die", "addon_split", "split1", %{"exitCode" => "1"})
    midpoint = div(byte_size(line), 2)
    <<part1::binary-size(^midpoint), part2::binary>> = line

    send_chunk(sock, part1)
    Process.sleep(20)
    send_chunk(sock, part2)

    assert_receive {:engine_event, %Event{name: "addon_split", action: :die, exit_code: 1}}, 1_000
  end

  test "health statuses become :health with the status", %{listen: listen} do
    {sock, _head} = accept_conn(listen)
    send_chunk(sock, event_json("health_status: unhealthy", "addon_h", "h1"))
    send_chunk(sock, event_json("health_status: healthy", "addon_h", "h1"))

    assert_receive {:engine_event, %Event{action: :health, health: :unhealthy}}, 1_000
    assert_receive {:engine_event, %Event{action: :health, health: :healthy}}, 1_000
  end

  test "non-container and malformed lines are skipped", %{listen: listen} do
    {sock, _head} = accept_conn(listen)
    send_chunk(sock, event_json("create", "addon_net", "n1", %{}, "network"))
    send_chunk(sock, "{not json\n")
    send_chunk(sock, event_json("start", "addon_after", "a1"))

    assert_receive {:engine_event, %Event{id: "a1", action: :start}}, 1_000
    refute_received {:engine_event, %Event{id: "n1"}}
  end

  test "a line past the cap without a newline is dropped, and the stream goes on", %{
    listen: listen
  } do
    {sock, _head} = accept_conn(listen)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send_chunk(sock, String.duplicate("x", 1_048_577))
        send_chunk(sock, "\n" <> event_json("start", "addon_capped", "c1"))
        assert_receive {:engine_event, %Event{id: "c1"}}, 2_000
      end)

    assert log =~ "pending line exceeded"
  end

  @tag :own_events
  test "a 200 makes the stream ready, which resyncs; a 500 does not", %{
    listen: listen,
    path: path
  } do
    test = self()
    list = fn -> send(test, :listed) && {:ok, []} end

    start_supervised!(
      {Events,
       name: :"events_#{System.unique_integer([:positive])}",
       source: EventSource,
       engine_opts: [socket: path],
       list: list}
    )

    {sock, _head} = accept_conn(listen)
    assert_receive :listed, 1_000

    ExUnit.CaptureLog.capture_log(fn ->
      :gen_tcp.close(sock)
      {:ok, sock2} = :gen_tcp.accept(listen, 5_000)
      _head = read_request_head(sock2, "")

      :ok =
        :gen_tcp.send(sock2, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")

      refute_receive :listed, 500
    end)
  end

  test "a server close reconnects", %{listen: listen} do
    ExUnit.CaptureLog.capture_log(fn ->
      {sock1, _head} = accept_conn(listen)
      :gen_tcp.close(sock1)

      {sock2, head2} = accept_conn(listen, 5_000)
      assert head2 =~ "GET /events"
      send_chunk(sock2, event_json("start", "addon_reco", "reco1"))
      assert_receive {:engine_event, %Event{name: "addon_reco", action: :start}}, 1_000
    end)
  end

  test "Docker's actions map onto the engine-neutral set" do
    actions =
      for action <- ~w(start die create destroy exec_start oom kill),
          do: EventSource.normalize(%{"Action" => action}).action

    assert actions == [:start, :die, :create, :destroy, :other, :other, :other]
  end
end
