defmodule Vagus.API.CoreProxyWSTest.DialCounter do
  @moduledoc "Counts requests that actually reached the fake Core's `/api/websocket` route — proves a caller rejected at the WSBridge handshake never causes `Vagus.API.CoreProxy.WSBridge.Upstream` to dial Core at all."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def bump, do: Agent.update(__MODULE__, &(&1 + 1))
  def count, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.CoreProxyWSTest.CoreAuthScript do
  @moduledoc "Controls whether the fake Core's `/api/websocket` handshake (`CoreHandshakeHandler`) replies `auth_ok` (`:ok`, the default) or `auth_invalid` (`:invalid`) to a correctly-shaped `auth` message — the Core-side-handshake-failure test's control knob."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> :ok end, name: __MODULE__)
  def set(mode), do: Agent.update(__MODULE__, fn _ -> mode end)
  def get, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.CoreProxyWSTest.CoreHandshakeHandler do
  @moduledoc """
  A `WebSock` handler standing in for Core's own `/api/websocket` endpoint —
  plays the SERVER side of fact 8's `_websocket_client` handshake that
  `Vagus.API.CoreProxy.WSBridge.Upstream` runs as the CLIENT: pushes
  `auth_required` shortly after init (see `init/1` — not synchronously
  from init's own return), expects `{"type":"auth","access_token":T}`,
  replies `auth_ok` (or, per `CoreAuthScript`, `auth_invalid` regardless of
  whether `T` is actually correct — the Core-side-failure test's knob) then
  echoes further frames — except the magic words below, which travel as a
  command's `"type"` because the bridge relays nothing else. `hello` gets
  `"world"` back (rather than an echo) so a passing round-trip proves the
  frame really crossed into this fake Core and back, not just an
  accidental local loop. `close:<code>:<reason>` closes with that exact
  code (`Vagus.Ingress.WSBridgeTest.EchoHandler`'s own convention).
  `stall`, post-auth, parks the process in a `receive`-forever — the
  steady-state-backpressure tests' way of making Core's own TCP socket
  buffer fill up (Bandit stops reading once this handler stops returning
  from `handle_in/2`), distinct from `CoreAuthScript`'s `:stall` (which
  withholds `auth_ok` itself, the pre-`ha_ready?` pending-cap window). Reports
  init/terminate, and every frame it echoes, to the test process.
  """
  @behaviour WebSock

  alias Vagus.API.CoreProxyWSTest.CoreAuthScript

  @impl WebSock
  def init(%{test_pid: test_pid, expected_token: expected_token}) do
    send(test_pid, {:core_init, self()})

    # issue #1: Bandit 1.12.0 can silently lose a frame pushed straight from
    # `WebSock.init/1`'s own return under CPU starvation
    # (`Bandit.WebSocket.Socket.send_frame/3` discards the send result) —
    # that's what stranded this fake's `auth_required` push and produced the
    # flake's `{:close, 1011, ""}`. Pushing from the first `handle_info` tick
    # instead is outside that window.
    Process.send_after(self(), :push_auth_required, 0)

    state = %{test_pid: test_pid, expected_token: expected_token, authed?: false}
    {:ok, state}
  end

  @impl WebSock
  def handle_in({data, opcode: :text}, %{authed?: false} = state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "auth", "access_token" => token}} ->
        handle_core_auth(token, state)

      _other ->
        {:stop, :normal, {1000, ""}, state}
    end
  end

  def handle_in({~s({"type":"close:) <> rest = data, opcode: :text}, %{authed?: true} = state) do
    case rest |> String.trim_trailing(~s("})) |> String.split(":", parts: 2) do
      [code_str, reason] -> {:stop, :normal, {String.to_integer(code_str), reason}, state}
      _other -> {:push, {:text, data}, state}
    end
  end

  def handle_in({~s({"type":"stall"}), opcode: :text}, %{authed?: true} = state) do
    receive do
      :never_sent -> {:ok, state}
    end
  end

  def handle_in({~s({"type":"hello"}), opcode: :text}, %{authed?: true} = state) do
    {:push, {:text, "world"}, state}
  end

  def handle_in({data, opcode: opcode}, %{authed?: true} = state) do
    send(state.test_pid, {:core_frame, opcode, data})
    {:push, {opcode, data}, state}
  end

  defp handle_core_auth(token, state) do
    case CoreAuthScript.get() do
      :invalid ->
        {:stop, :normal, {1000, ""}, [{:text, encode(%{"type" => "auth_invalid"})}], state}

      # Consume the auth message but never reply `auth_ok` — holds
      # `Vagus.API.CoreProxy.WSBridge.Upstream` in `ha_ready?: false` so the
      # caller's frames pile up in `pending` (the pending-cap overflow test's
      # window).
      :stall ->
        {:ok, state}

      _ok ->
        if token == state.expected_token do
          {:push, {:text, encode(%{"type" => "auth_ok", "ha_version" => "2026.7.3"})},
           %{state | authed?: true}}
        else
          {:stop, :normal, {1000, ""}, [{:text, encode(%{"type" => "auth_invalid"})}], state}
        end
    end
  end

  @impl WebSock
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(:push_auth_required, state) do
    {:push, {:text, encode(%{"type" => "auth_required", "ha_version" => "2026.7.3"})}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(reason, %{test_pid: test_pid}) do
    send(test_pid, {:core_terminate, reason})
    :ok
  end

  defp encode(map), do: Jason.encode!(map)
end

defmodule Vagus.API.CoreProxyWSTest.CoreSocketHandler do
  @moduledoc """
  Core's `/api/websocket` as it behaves on the Supervisor unix socket (A3):
  the peer is already the Supervisor user, so nothing is pushed on connect
  and no `auth` message is expected — anything auth-shaped that arrives is
  reported to the test process. `hello` answers `"world"` (same
  crossed-the-bridge proof as `CoreHandshakeHandler`, same magic-word
  convention); `auth-then-hello` pushes an `auth_ok` frame BEFORE
  `"world"`, so a test can prove the bridge swallows a handshake frame
  instead of relaying a second one to a caller that already had its own.
  """
  @behaviour WebSock

  @impl WebSock
  def init(%{test_pid: test_pid} = state) do
    send(test_pid, {:core_socket_init, self()})
    {:ok, state}
  end

  @impl WebSock
  def handle_in({~s({"type":"hello"}), opcode: :text}, state),
    do: {:push, {:text, "world"}, state}

  def handle_in({~s({"type":"auth-then-hello"}), opcode: :text}, state) do
    auth_ok = Jason.encode!(%{"type" => "auth_ok", "ha_version" => "2026.8.0"})
    {:push, [{:text, auth_ok}, {:text, "world"}], state}
  end

  def handle_in({data, opcode: :text}, %{test_pid: test_pid} = state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "auth"}} -> send(test_pid, {:core_socket_unexpected_auth, data})
      _other -> :ok
    end

    {:push, {:text, data}, state}
  end

  def handle_in({data, opcode: :binary}, state), do: {:push, {:binary, data}, state}

  @impl WebSock
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_msg, state), do: {:ok, state}

  # A barrier for the test: this process reports nothing after it.
  @impl WebSock
  def terminate(reason, %{test_pid: test_pid}) do
    send(test_pid, {:core_socket_terminate, reason})
    :ok
  end
end

defmodule Vagus.API.CoreProxyWSTest.FakeCoreSocket do
  @moduledoc "Routes `/api/websocket` to the handshake-free `CoreSocketHandler`."
  use Plug.Router

  alias Vagus.API.CoreProxyWSTest.{CoreSocketHandler, DialCounter}

  plug(:match)
  plug(:dispatch)

  get "/api/websocket" do
    DialCounter.bump()
    test_pid = Application.fetch_env!(:vagus, :core_ws_test_pid)
    # 30s sat exactly at the bridges' 30s heartbeat interval — a knife-edge
    # idle race under CI starvation (the fake's own idle close can fire
    # first) plus a real bound for wedge/flood tests that legitimately
    # starve this receive path; 900_000 matches the production listeners'
    # own idle bound instead.
    WebSockAdapter.upgrade(conn, CoreSocketHandler, %{test_pid: test_pid}, timeout: 900_000)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Vagus.API.CoreProxyWSTest.FakeCore do
  @moduledoc "Stands in for Home Assistant Core's WS API: the single `/api/websocket` route bumps `DialCounter` (proving a real dial happened) then upgrades to `CoreHandshakeHandler`."
  use Plug.Router

  alias Vagus.API.CoreProxyWSTest.{CoreHandshakeHandler, DialCounter}

  plug(:match)
  plug(:dispatch)

  get "/api/websocket" do
    DialCounter.bump()
    test_pid = Application.fetch_env!(:vagus, :core_ws_test_pid)
    expected_token = Application.fetch_env!(:vagus, :core_ws_expected_token)

    WebSockAdapter.upgrade(
      conn,
      CoreHandshakeHandler,
      %{test_pid: test_pid, expected_token: expected_token},
      timeout: 900_000
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Vagus.API.CoreProxyWSTest.Client do
  @moduledoc """
  A minimal hand-rolled `Mint.WebSocket` client standing in for the caller —
  adapted from `Vagus.Ingress.WSBridgeTest.Client` (same rationale: drive
  `Vagus.API.CoreProxy.WSBridge` exactly as an external WS client would,
  reusing no Vagus code). Holds a small FIFO `queue` of already-decoded
  frames so `next_frame/2` hands back one at a time regardless of how the
  underlying TCP messages happened to chunk.
  """

  defstruct [:conn, :ref, :websocket, queue: []]

  @type t :: %__MODULE__{}

  @spec connect(String.t(), pos_integer(), String.t(), Mint.Types.headers()) ::
          {:ok, t(), Mint.Types.headers()} | {:error, non_neg_integer(), Mint.HTTP.t()}
  def connect(host, port, path, headers \\ []) do
    {:ok, conn} = Mint.HTTP.connect(:http, host, port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)
    {conn, responses} = await_done(conn, ref, [])

    status = find(responses, :status, ref)
    resp_headers = find(responses, :headers, ref) || []

    if status == 101 do
      {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, resp_headers)

      # Unlike `Vagus.Ingress.WSBridgeTest.Client` (the add-on side never
      # sends anything until the browser does), `Vagus.API.CoreProxy.WSBridge`
      # pushes `auth_required` the moment the upgrade completes — on
      # localhost this can arrive in the SAME TCP read as the 101 response
      # itself, bundled into the same `responses` list `await_done/3`
      # already collected. Decoding any `{:data, ^ref, _}` entries here
      # (via the same `decode_all/3` `next_frame/2` uses) and seeding
      # `queue` with them is what makes that race harmless instead of
      # silently dropping the first frame.
      {websocket, frames} = decode_all(websocket, ref, responses)

      # mint_web_socket's post-`new/4` stream never revisits Mint.HTTP1's own
      # parse buffer — bytes bundled with (or immediately behind) the 101
      # response, distinct from the same-batch `{:data, ...}` entries
      # `decode_all/3` above already handles, are stranded there unless
      # drained here, once, right after `new/4`.
      leftover = mint_http1_leftover(conn)
      {websocket, leftover_frames} = decode_all(websocket, ref, [{:data, ref, leftover}])

      {:ok,
       %__MODULE__{conn: conn, ref: ref, websocket: websocket, queue: frames ++ leftover_frames},
       resp_headers}
    else
      {:error, status, conn}
    end
  end

  @spec send_frame(t(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) :: t()
  def send_frame(%__MODULE__{} = c, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(c.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(c.conn, c.ref, data)
    %{c | conn: conn, websocket: websocket}
  end

  @spec next_frame(t(), timeout()) :: {Mint.WebSocket.frame(), t()}
  def next_frame(%__MODULE__{queue: [frame | rest]} = c, timeout) do
    handle_frame(frame, %{c | queue: rest}, timeout)
  end

  def next_frame(%__MODULE__{queue: []} = c, timeout) do
    receive do
      {:tcp, _socket, _data} = msg -> handle_transport_msg(msg, c, timeout)
      {:tcp_closed, _socket} = msg -> handle_transport_msg(msg, c, timeout)
      {:tcp_error, _socket, _reason} = msg -> handle_transport_msg(msg, c, timeout)
      {:ssl, _socket, _data} = msg -> handle_transport_msg(msg, c, timeout)
      {:ssl_closed, _socket} = msg -> handle_transport_msg(msg, c, timeout)
      {:ssl_error, _socket, _reason} = msg -> handle_transport_msg(msg, c, timeout)
    after
      timeout -> raise "timeout waiting for a websocket frame"
    end
  end

  defp handle_transport_msg(msg, c, timeout) do
    case Mint.WebSocket.stream(c.conn, msg) do
      {:ok, conn, responses} ->
        {websocket, frames} = decode_all(c.websocket, c.ref, responses)
        c = %{c | conn: conn, websocket: websocket}

        case frames do
          [] -> next_frame(c, timeout)
          [frame | rest] -> handle_frame(frame, %{c | queue: rest}, timeout)
        end

      # Not a message belonging to this connection's own request — per
      # `Mint.WebSocket.stream/2`'s own documented return shape, ignore and
      # keep waiting rather than crash; not expected in practice for a
      # single hand-rolled test socket, but the correct behavior per Mint's
      # own contract either way.
      :unknown ->
        next_frame(c, timeout)
    end
  end

  # `WSBridge` heartbeats every 30s for the connection's life (fact 8) —
  # a starved test run can stretch past that, so ping/pong control traffic
  # must be answered/absorbed here (as a real WS client's transport layer
  # would) rather than handed to a caller's data-frame assertion. Recursing
  # resets the wait window on each control frame — acceptable in tests,
  # where the bound is "a data frame eventually arrives", not a hard deadline.
  defp handle_frame({:ping, data}, c, timeout) do
    next_frame(send_frame(c, {:pong, data}), timeout)
  end

  defp handle_frame({:pong, _data}, c, timeout) do
    next_frame(c, timeout)
  end

  defp handle_frame(frame, c, _timeout) do
    {frame, c}
  end

  defp decode_all(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, r, data}, {ws, acc} when r == ref ->
        {:ok, ws, decoded} = Mint.WebSocket.decode(ws, data)
        {ws, acc ++ decoded}

      _other, acc ->
        acc
    end)
  end

  # Reaches into Mint.HTTP1's own struct on purpose (see `connect/4`) —
  # guarded so an upstream struct change degrades to a no-op (treated as
  # "no leftover") rather than crashing.
  defp mint_http1_leftover(conn) do
    case conn do
      %{buffer: bin} when is_binary(bin) and bin != <<>> -> bin
      _ -> <<>>
    end
  end

  defp await_done(conn, ref, acc) do
    receive do
      {:tcp, _socket, _data} = msg -> handle_await(msg, conn, ref, acc)
      {:tcp_closed, _socket} = msg -> handle_await(msg, conn, ref, acc)
      {:tcp_error, _socket, _reason} = msg -> handle_await(msg, conn, ref, acc)
      {:ssl, _socket, _data} = msg -> handle_await(msg, conn, ref, acc)
      {:ssl_closed, _socket} = msg -> handle_await(msg, conn, ref, acc)
      {:ssl_error, _socket, _reason} = msg -> handle_await(msg, conn, ref, acc)
    after
      5_000 -> raise "timeout awaiting HTTP response"
    end
  end

  defp handle_await(msg, conn, ref, acc) do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} ->
        acc = acc ++ responses

        if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
          {conn, acc}
        else
          await_done(conn, ref, acc)
        end

      {:error, conn, _reason, responses} ->
        {conn, acc ++ responses}

      # See `handle_transport_msg/3`'s own `:unknown` clause.
      :unknown ->
        await_done(conn, ref, acc)
    end
  end

  defp find(responses, tag, ref) do
    Enum.find_value(responses, fn
      {^tag, ^ref, v} -> v
      _ -> nil
    end)
  end
end

defmodule Vagus.API.CoreProxyWSTest.Stack do
  @moduledoc """
  The fake Core and the real proxy on their own ports, and a caller already
  relaying through them, for test modules beyond `Vagus.API.CoreProxyWSTest`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Vagus.API.CoreProxyWSTest.{Client, CoreAuthScript, DialCounter, FakeCore}
  alias Vagus.API.Dispatcher

  @core_token "core-access-token"
  @recv_timeout 30_000

  @spec start() :: %{proxy_host: String.t(), proxy_port: pos_integer()}
  def start do
    start_supervised!(DialCounter)
    start_supervised!(CoreAuthScript)

    put_env(:core_ws_test_pid, self())
    put_env(:core_ws_expected_token, @core_token)
    put_env(:core_proxy_access_token_fun, fn -> {:ok, @core_token} end)

    core = bandit(FakeCore, :fake_core_bandit)
    proxy = bandit(Dispatcher, :proxy_bandit)

    put_env(:core_base_url, "http://127.0.0.1:#{port(core)}")
    %{proxy_host: "127.0.0.1", proxy_port: port(proxy)}
  end

  defp bandit(plug, id) do
    start_supervised!(
      {Bandit, plug: plug, port: 0, thousand_island_options: [num_acceptors: 1]},
      id: id
    )
  end

  defp port(bandit) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  @spec put_env(atom(), term()) :: :ok
  def put_env(key, value) do
    previous = Application.fetch_env(:vagus, key)
    Application.put_env(:vagus, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vagus, key, value)
        :error -> Application.delete_env(:vagus, key)
      end
    end)
  end

  @doc "A caller past both handshakes, authenticated with `token`."
  @spec relaying_client(String.t(), pos_integer(), String.t()) :: Client.t()
  def relaying_client(host, port, token) do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    assert_receive {:core_init, _core_pid}, @recv_timeout
    client
  end
end
