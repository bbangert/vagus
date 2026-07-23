defmodule Vagus.API.LogsFollowRouterTest do
  @moduledoc """
  `/logs/follow` routes — chunked headers, docker-backed streaming against a
  fake engine socket, client-death teardown, and the native-broker branch.
  async: false — mutates :vagus app env (docker_socket, follow_idle_ms,
  core_container) and registers the native broker's global process names.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Mqtt.Broker

  @opts Vagus.API.Router.init([])

  defp sup(conn), do: put_req_header(conn, "authorization", "Bearer #{Vagus.API.Token.get()}")

  setup do
    # Short idle window so native streams (which have no eof) end
    # deterministically instead of holding for the production 15 min.
    Application.put_env(:vagus, :follow_idle_ms, 300)
    on_exit(fn -> Application.delete_env(:vagus, :follow_idle_ms) end)
    :ok
  end

  # -- fake engine socket (events_test/follow_test pattern) -----------------

  defp socket_path, do: "/tmp/vagus-lfr-#{System.unique_integer([:positive])}.sock"

  defp start_fake_server(path) do
    # rm first: a leftover socket file from a previous run collides
    # (:eaddrinuse) — see follow_test.exs for the full story.
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
    listen
  end

  defp accept_and_greet(listen) do
    {:ok, sock} = :gen_tcp.accept(listen, 3_000)
    head = read_head(sock, "")

    :ok =
      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      )

    {sock, head}
  end

  defp read_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      read_head(sock, acc <> data)
    end
  end

  defp send_frame(sock, payload) do
    framed = <<1, 0, 0, 0, byte_size(payload)::32, payload::binary>>
    size_hex = framed |> byte_size() |> Integer.to_string(16)
    :ok = :gen_tcp.send(sock, size_hex <> "\r\n" <> framed <> "\r\n")
  end

  defp with_docker_env(path) do
    old_socket = Application.get_env(:vagus, :docker_socket)
    old_core = Application.get_env(:vagus, :core_container)
    Application.put_env(:vagus, :docker_socket, path)
    Application.put_env(:vagus, :core_container, "homeassistant")

    on_exit(fn ->
      restore_env(:docker_socket, old_socket)
      restore_env(:core_container, old_core)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)

  # -- docker-backed follow ---------------------------------------------------

  test "core follow: chunked 200 + headers + streamed lines until server close" do
    path = socket_path()
    listen = start_fake_server(path)
    with_docker_env(path)

    task =
      Task.async(fn ->
        conn(:get, "/core/logs/follow?lines=7") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    {sock, _head} = accept_and_greet(listen)
    send_frame(sock, "one\n")
    send_frame(sock, "two\n")
    :gen_tcp.close(sock)

    conn = Task.await(task, 5_000)
    assert conn.status == 200
    assert get_resp_header(conn, "x-first-cursor") == ["0"]
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert conn.resp_body == "one\ntwo\n"
  end

  test "no configured core container: honest empty chunked stream that closes" do
    conn = conn(:get, "/core/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert get_resp_header(conn, "x-first-cursor") == ["0"]
    assert conn.resp_body == ""
  end

  test "client death mid-stream tears down the held docker connection" do
    path = socket_path()
    listen = start_fake_server(path)
    with_docker_env(path)
    test_pid = self()

    {:ok, task_pid} =
      Task.start(fn ->
        conn(:get, "/core/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    {sock, _head} = accept_and_greet(listen)
    send_frame(sock, "before-death\n")

    # Kill the request process mid-stream: the Follow process (owner-monitor
    # + link) must die with it and the engine side must see the close.
    Process.exit(task_pid, :kill)
    spawn(fn -> send(test_pid, {:recv, :gen_tcp.recv(sock, 0, 3_000)}) end)
    assert_receive {:recv, {:error, :closed}}, 4_000
  end

  test "an add-on may not follow another add-on's logs" do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Vagus.Addon.Registry.register(token, %{
        slug: "intruder",
        services_role: %{},
        auth_api: false,
        discovery: []
      })

    on_exit(fn -> Vagus.Addon.Registry.unregister_slug("intruder") end)

    conn =
      conn(:get, "/addons/core_mosquitto/logs/follow")
      |> put_req_header("x-supervisor-token", token)
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 403
  end

  # -- native-broker follow ---------------------------------------------------

  test "native add-on follow: backfill then live broker lines, unsubscribed after" do
    # Fake a running native broker: Native.running?/1 is a whereis on the
    # broker subtree name; the logs buffer is <name>.Logs.
    broker_name = Module.concat(Broker, "addon_core_mqtt")
    dummy = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(dummy, broker_name)
    on_exit(fn -> if Process.alive?(dummy), do: Process.exit(dummy, :kill) end)

    logs = start_supervised!({Broker.Logs, name: Module.concat(broker_name, "Logs")})
    GenServer.cast(logs, {:append, "old-line"})

    task =
      Task.async(fn ->
        conn(:get, "/addons/core_mqtt/logs/follow") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    # Wait until the request process has subscribed, then append a live line.
    wait_until(fn -> map_size(:sys.get_state(logs).subscribers) == 1 end)
    GenServer.cast(logs, {:append, "live-line"})

    conn = Task.await(task, 5_000)
    assert conn.status == 200
    assert conn.resp_body == "old-line\nlive-line\n"
    # Idle teardown unsubscribed the (now finished) request process.
    assert :sys.get_state(logs).subscribers == %{}
  end

  # -- §A5 contract surface on follow routes (P3) -----------------------------

  test "follow rejects unsupported Accept with 400 before streaming" do
    conn =
      conn(:get, "/core/logs/follow")
      |> sup()
      |> put_req_header("accept", "application/json")
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 400
  end

  test "lines floor + verbose: docker sees tail=100&timestamps=true; lines get the §A5 prefix" do
    path = socket_path()
    listen = start_fake_server(path)
    with_docker_env(path)

    task =
      Task.async(fn ->
        conn(:get, "/core/logs/follow?lines=1&verbose")
        |> sup()
        |> Vagus.API.Router.call(@opts)
      end)

    {sock, head} = accept_and_greet(listen)
    assert head =~ "tail=100"
    assert head =~ "timestamps=true"

    send_frame(sock, "2026-07-23T01:02:03Z started\n")
    :gen_tcp.close(sock)

    conn = Task.await(task, 5_000)
    {:ok, host} = :inet.gethostname()
    assert conn.resp_body == "2026-07-23 01:02:03.000 #{host} homeassistant: started\n"
  end

  test "boots/0/follow streams the current source; other offsets stream empty" do
    path = socket_path()
    listen = start_fake_server(path)
    with_docker_env(path)

    # Non-zero offset: no journal history — empty stream, no engine dial.
    conn = conn(:get, "/core/logs/boots/-1/follow") |> sup() |> Vagus.API.Router.call(@opts)
    assert conn.status == 200
    assert conn.resp_body == ""

    # Offset 0 = current boot = the live source.
    task =
      Task.async(fn ->
        conn(:get, "/core/logs/boots/0/follow") |> sup() |> Vagus.API.Router.call(@opts)
      end)

    {sock, _head} = accept_and_greet(listen)
    send_frame(sock, "current-boot\n")
    :gen_tcp.close(sock)

    conn = Task.await(task, 5_000)
    assert conn.resp_body == "current-boot\n"
  end

  test "native follow with ?verbose prefixes host + ident (no source stamps)" do
    broker_name = Module.concat(Broker, "addon_core_mqtt")
    dummy = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(dummy, broker_name)
    on_exit(fn -> if Process.alive?(dummy), do: Process.exit(dummy, :kill) end)

    logs = start_supervised!({Broker.Logs, name: Module.concat(broker_name, "Logs")})
    GenServer.cast(logs, {:append, "CONNECT c1"})

    conn =
      conn(:get, "/addons/core_mqtt/logs/follow?verbose")
      |> sup()
      |> Vagus.API.Router.call(@opts)

    {:ok, host} = :inet.gethostname()
    assert conn.resp_body == "#{host} addon_core_mqtt: CONNECT c1\n"
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
