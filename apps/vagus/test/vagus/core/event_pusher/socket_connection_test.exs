defmodule Vagus.Core.EventPusher.SocketConnectionTest.Handler do
  @moduledoc """
  Core's `/api/websocket` as it behaves on the Supervisor socket (A3): the
  connection is already the Supervisor user, so **no** `auth_required` is
  pushed and **no** `auth` message is expected. Anything auth-shaped that
  does arrive is reported to the test process as `{:core_ws, {:unexpected,
  msg}}` — the assertion that Vagus never tries to authenticate here.
  """
  @behaviour WebSock

  @impl WebSock
  def init(%{test_pid: test_pid} = state) do
    send(test_pid, {:core_ws, {:init, self()}})
    {:ok, state}
  end

  @impl WebSock
  def handle_in({data, opcode: :text}, %{test_pid: test_pid} = state) do
    msg = Jason.decode!(data)
    send(test_pid, {:core_ws, {:frame, msg}})

    case msg do
      %{"type" => "auth"} ->
        send(test_pid, {:core_ws, {:unexpected, msg}})
        {:ok, state}

      %{"type" => "config/auth/list", "id" => id} ->
        {:push, {:text, result(id, [%{"id" => "u1", "is_owner" => true}])}, state}

      %{"type" => "boom", "id" => id} ->
        {:push, {:text, error(id, %{"code" => "unknown_command"})}, state}

      %{"id" => id} ->
        {:push, {:text, result(id, nil)}, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(:push_auth_ok, state) do
    {:push, {:text, Jason.encode!(%{"type" => "auth_ok", "ha_version" => "2026.8.0"})}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp result(id, payload) do
    Jason.encode!(%{"type" => "result", "id" => id, "success" => true, "result" => payload})
  end

  defp error(id, err) do
    Jason.encode!(%{"type" => "result", "id" => id, "success" => false, "error" => err})
  end
end

defmodule Vagus.Core.EventPusher.SocketConnectionTest.FakeCore do
  @moduledoc "Routes `/api/websocket` to the handshake-free handler above."
  use Plug.Router

  alias Vagus.Core.EventPusher.SocketConnectionTest.Handler

  plug(:match)
  plug(:dispatch)

  get "/api/websocket" do
    test_pid = Application.fetch_env!(:vagus, :event_pusher_socket_test_pid)
    WebSockAdapter.upgrade(conn, Handler, %{test_pid: test_pid}, timeout: 30_000)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Vagus.Core.EventPusher.SocketConnectionTest do
  @moduledoc """
  A2/A3 — `Vagus.Core.EventPusher` over the Supervisor↔Core unix socket,
  driven end to end against a real WS server on a real unix socket.
  `async: false`: `:core_socket_path` is process-global application env.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.{EventPusher, TokenStore}
  alias Vagus.Core.EventPusher.SocketConnection

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_event_pusher_#{System.unique_integer([:positive])}.sock"
      )

    Application.put_env(:vagus, :event_pusher_socket_test_pid, self())

    start_supervised!(
      {Bandit,
       plug: Vagus.Core.EventPusher.SocketConnectionTest.FakeCore,
       port: 0,
       thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]}
    )

    Application.put_env(:vagus, :core_socket_path, path)

    on_exit(fn ->
      Application.put_env(:vagus, :core_socket_path, nil)
      Application.delete_env(:vagus, :event_pusher_socket_test_pid)
      File.rm(path)
    end)

    %{socket: path}
  end

  # Deliberately holds NO refresh token: on the socket transport there is
  # nothing to be lazy about, and a manager that still waited for one would
  # never connect here.
  defp start_manager do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "vagus_event_pusher_ts_#{System.unique_integer([:positive])}.json"
      )

    store = :"ep_token_store_#{System.unique_integer([:positive])}"
    start_supervised!({TokenStore, name: store, path: store_path})
    on_exit(fn -> File.rm(store_path) end)

    name = :"event_pusher_#{System.unique_integer([:positive])}"
    start_supervised!({EventPusher, name: name, token_store: store})
    await_ready(name)
    name
  end

  defp await_ready(name, attempts \\ 200) do
    cond do
      :sys.get_state(name).ready ->
        :ok

      attempts == 0 ->
        flunk("EventPusher never became ready on the socket transport")

      true ->
        Process.sleep(10)
        await_ready(name, attempts - 1)
    end
  end

  test "connects and becomes ready with no auth handshake at all" do
    name = start_manager()

    assert_receive {:core_ws, {:init, _handler}}, 2_000
    assert :sys.get_state(name).ready
    refute_received {:core_ws, {:unexpected, _msg}}
    refute_received {:core_ws, {:frame, %{"type" => "auth"}}}
  end

  test "command/2 round-trips over the socket (the SSH panel's config/auth/list)" do
    name = start_manager()

    assert {:ok, [%{"id" => "u1", "is_owner" => true}]} =
             EventPusher.command(%{"type" => "config/auth/list"}, server: name, timeout: 5_000)

    assert_receive {:core_ws, {:frame, %{"type" => "config/auth/list", "id" => id}}}, 2_000
    assert is_integer(id)
  end

  test "a success:false envelope surfaces as {:error, {:core_error, _}}" do
    name = start_manager()

    assert {:error, {:core_error, %{"code" => "unknown_command"}}} =
             EventPusher.command(%{"type" => "boom"}, server: name, timeout: 5_000)
  end

  test "push/2 events reach Core over the socket" do
    name = start_manager()

    EventPusher.push(%{"event" => "test_event"}, name)

    assert_receive {:core_ws,
                    {:frame,
                     %{"type" => "supervisor/event", "data" => %{"event" => "test_event"}}}},
                   2_000
  end

  test "the Mint socket carries send_timeout/send_timeout_close (C2, issue #37)" do
    prev = Application.get_env(:vagus, :core_ws_send_timeout)
    Application.put_env(:vagus, :core_ws_send_timeout, 1_234)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :core_ws_send_timeout),
        else: Application.put_env(:vagus, :core_ws_send_timeout, prev)
    end)

    assert SocketConnection.mint_connect_opts({:socket, "/run/x.sock"})[:transport_opts] ==
             [send_timeout: 1_234, send_timeout_close: true]

    # ...and it actually reaches the socket the live connection is holding:
    # without it, a Core whose receive buffer has filled blocks
    # `send_frame_now/2` forever and this GenServer never exits, so the
    # manager's monitor never fires and every EventPusher op deadlocks.
    name = start_manager()
    connection = :sys.get_state(name).connection_pid
    socket = :sys.get_state(connection).conn.socket

    assert {:ok, socket_opts} = :inet.getopts(socket, [:send_timeout, :send_timeout_close])
    assert socket_opts[:send_timeout] == 1_234
    assert socket_opts[:send_timeout_close] == true
  end

  test "a stray handshake frame from Core is ignored, not treated as a result" do
    name = start_manager()
    assert_receive {:core_ws, {:init, handler}}, 2_000

    connection = :sys.get_state(name).connection_pid
    assert is_pid(connection)

    # Provoke the frame the socket transport says should never arrive, then
    # prove the connection is still fully usable.
    send(handler, :push_auth_ok)

    assert {:ok, [_user]} =
             EventPusher.command(%{"type" => "config/auth/list"}, server: name, timeout: 5_000)

    assert Process.alive?(connection)
  end
end
