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
  echoes further frames — except the literal text `"hello"`, which gets
  `"world"` back (rather than an echo) so a passing round-trip proves the
  frame really crossed into this fake Core and back, not just an
  accidental local loop. `"close:<code>:<reason>"` closes with that exact
  code (`Vagus.Ingress.WSBridgeTest.EchoHandler`'s own convention).
  `"stall"`, post-auth, parks the process in a `receive`-forever — the
  steady-state-backpressure tests' way of making Core's own TCP socket
  buffer fill up (Bandit stops reading once this handler stops returning
  from `handle_in/2`), distinct from `CoreAuthScript`'s `:stall` (which
  withholds `auth_ok` itself, the pre-`ha_ready?` pending-cap window). Reports
  init/terminate to the test process.
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

  def handle_in({"close:" <> rest, opcode: :text}, %{authed?: true} = state) do
    case String.split(rest, ":", parts: 2) do
      [code_str, reason] -> {:stop, :normal, {String.to_integer(code_str), reason}, state}
      _other -> {:push, {:text, "close:" <> rest}, state}
    end
  end

  def handle_in({"stall", opcode: :text}, %{authed?: true} = state) do
    receive do
      :never_sent -> {:ok, state}
    end
  end

  def handle_in({"hello", opcode: :text}, %{authed?: true} = state) do
    {:push, {:text, "world"}, state}
  end

  def handle_in({data, opcode: :text}, %{authed?: true} = state),
    do: {:push, {:text, data}, state}

  def handle_in({data, opcode: :binary}, %{authed?: true} = state),
    do: {:push, {:binary, data}, state}

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
  reported to the test process. `"hello"` answers `"world"` (same
  crossed-the-bridge proof as `CoreHandshakeHandler`);
  `"auth-then-hello"` pushes an `auth_ok` frame BEFORE `"world"`, so a test
  can prove the bridge swallows a handshake frame instead of relaying a
  second one to a caller that already had its own.
  """
  @behaviour WebSock

  @impl WebSock
  def init(%{test_pid: test_pid} = state) do
    send(test_pid, {:core_socket_init, self()})
    {:ok, state}
  end

  @impl WebSock
  def handle_in({"hello", opcode: :text}, state), do: {:push, {:text, "world"}, state}

  def handle_in({"auth-then-hello", opcode: :text}, state) do
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

  @impl WebSock
  def terminate(_reason, _state), do: :ok
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

defmodule Vagus.API.CoreProxyWSTest do
  @moduledoc """
  Phase 3 (WS leg) tests for `Vagus.API.CoreProxy.WSBridge` /
  `Vagus.API.CoreProxy.WSBridge.Upstream`
  (`.claude/plans/vagus-core-api-proxy/plan.md`), following
  `Vagus.Ingress.WSBridgeTest`'s harness precedent: a fake Core (a real
  `Bandit`-served `Plug.Router` playing Core's own WS handshake role), the
  real proxy stack (`Bandit` serving `Vagus.API.Dispatcher`), and the
  hand-rolled Mint `Client` above standing in for the caller.

  The 400/405 (non-upgrade / wrong-method) cases don't need a real socket —
  those are plain HTTP responses answered before any upgrade is attempted —
  so they use `Plug.Test` directly against `Dispatcher`, same convention as
  `Vagus.API.CoreProxyTest`'s own non-streaming cases.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  # issue #1: the suite's WS deadlines already baseline at 60s (config/test.exs)
  # for starved-CI headroom — ExUnit's own 60s default per-test timeout must
  # sit above that, not equal to it.
  @moduletag timeout: 120_000

  alias Vagus.Addon.Registry
  alias Vagus.API.CoreProxyWSTest.{Client, CoreAuthScript, DialCounter, FakeCore}
  alias Vagus.API.{Dispatcher, Token}

  @opts Dispatcher.init([])
  @expected_core_token "core-access-token"

  # Real-socket wait bound for every handshake/close frame. Deliberately
  # generous: a terminal close code propagates over FOUR hops (Core → the
  # `Upstream` GenServer → `WSBridge` → the caller socket), across two real
  # Bandit servers, and a tighter 2s bound flaked on a loaded CI runner
  # (never locally — 25× file repeats stayed green) on the Core-auth-failure
  # close-propagation test. Nothing here should ever legitimately approach 5s.
  @recv_timeout 30_000

  setup do
    start_supervised!(DialCounter)
    start_supervised!(CoreAuthScript)
    start_supervised!({Finch, name: Vagus.API.CoreProxy.Finch})

    test_pid = self()
    Application.put_env(:vagus, :core_ws_test_pid, test_pid)
    Application.put_env(:vagus, :core_ws_expected_token, @expected_core_token)

    fake_core_pid =
      start_supervised!(
        {Bandit, plug: FakeCore, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :fake_core_bandit
      )

    proxy_pid =
      start_supervised!(
        {Bandit, plug: Dispatcher, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :proxy_bandit
      )

    fake_core_port = listening_port(fake_core_pid)
    proxy_port = listening_port(proxy_pid)

    prev_base_url = Application.get_env(:vagus, :core_base_url)
    Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{fake_core_port}")

    Application.put_env(:vagus, :core_proxy_access_token_fun, fn ->
      {:ok, @expected_core_token}
    end)

    # issue #1: these three carry a config/test.exs baseline (60_000, not the
    # library default) — `delete_env` would strip that baseline for the rest
    # of the suite after this file's first test runs, not just restore the
    # library default. Save/restore-prior instead, same discipline as
    # `prev_base_url` above.
    prev_auth_timeout = Application.get_env(:vagus, :core_ws_auth_timeout)
    prev_handoff_timeout = Application.get_env(:vagus, :core_ws_handoff_timeout)
    prev_send_timeout = Application.get_env(:vagus, :core_ws_send_timeout)

    on_exit(fn ->
      if is_nil(prev_base_url),
        do: Application.delete_env(:vagus, :core_base_url),
        else: Application.put_env(:vagus, :core_base_url, prev_base_url)

      if is_nil(prev_auth_timeout),
        do: Application.delete_env(:vagus, :core_ws_auth_timeout),
        else: Application.put_env(:vagus, :core_ws_auth_timeout, prev_auth_timeout)

      if is_nil(prev_handoff_timeout),
        do: Application.delete_env(:vagus, :core_ws_handoff_timeout),
        else: Application.put_env(:vagus, :core_ws_handoff_timeout, prev_handoff_timeout)

      if is_nil(prev_send_timeout),
        do: Application.delete_env(:vagus, :core_ws_send_timeout),
        else: Application.put_env(:vagus, :core_ws_send_timeout, prev_send_timeout)

      Application.delete_env(:vagus, :core_proxy_access_token_fun)
      Application.delete_env(:vagus, :core_ws_test_pid)
      Application.delete_env(:vagus, :core_ws_expected_token)
      Application.delete_env(:vagus, :core_ws_pending_max_frames)
      Application.delete_env(:vagus, :core_ws_pending_max_bytes)
    end)

    %{proxy_host: "127.0.0.1", proxy_port: proxy_port}
  end

  ## Helpers

  defp listening_port(bandit_pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  defp addon_token(slug, grants \\ %{}) do
    token = "core-ws-tok-#{System.unique_integer([:positive])}"

    identity =
      Map.merge(
        %{
          slug: slug,
          services_role: %{},
          auth_api: false,
          discovery: [],
          hassio_api: false,
          hassio_role: "default",
          homeassistant_api: false
        },
        grants
      )

    :ok = Registry.register(token, identity)
    on_exit(fn -> Registry.unregister_slug(slug) end)
    token
  end

  defp decode_text({:text, data}), do: Jason.decode!(data)

  ## 1. Accept: full handshake + text/binary relay both ways

  test "a caller with a flagged add-on token completes the handshake and relays both ways", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_accept", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    auth_required = Jason.decode!(raw)
    assert auth_required["type"] == "auth_required"
    assert Map.has_key?(auth_required, "ha_version")

    # Fact 8: no `"type"` field is required on the caller's own message —
    # deliberately omitted here to prove that.
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    auth_ok = Jason.decode!(raw)
    assert auth_ok["type"] == "auth_ok"
    assert Map.has_key?(auth_ok, "ha_version")

    assert_receive {:core_init, _core_pid}, @recv_timeout
    assert DialCounter.count() == 1

    client = Client.send_frame(client, {:text, "hello"})
    {frame, client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}

    payload = :crypto.strong_rand_bytes(10_000)
    expected_sha = :crypto.hash(:sha256, payload)
    client = Client.send_frame(client, {:binary, payload})
    {frame, _client} = Client.next_frame(client, @recv_timeout)

    assert {:binary, echoed} = frame
    assert :crypto.hash(:sha256, echoed) == expected_sha
  end

  ## 2. Rejections at the caller handshake — fake Core never dialed

  test "an unknown token -> auth_invalid then close, fake Core never dialed", %{
    proxy_host: host,
    proxy_port: port
  } do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client =
      Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => "not-a-real-token"})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  test "a registered add-on token WITHOUT homeassistant_api -> auth_invalid then close, fake Core never dialed",
       %{proxy_host: host, proxy_port: port} do
    token = addon_token("cp_ws_no_flag")
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  test "the supervisor token -> auth_invalid then close (not special-cased — it simply doesn't resolve)",
       %{proxy_host: host, proxy_port: port} do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => Token.get()})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  ## 3. api_password field

  test "a flagged add-on token via the api_password field also succeeds", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_api_password", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, Jason.encode!(%{"api_password" => token})})

    {{:text, raw}, _client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_ok"

    # `DialCounter` is bumped by `FakeCore`'s route handler, which runs
    # before `CoreHandshakeHandler.init/1` sends `:core_init` — waiting for
    # that message is what makes the count assertion below race-free
    # instead of racing `Upstream`'s own asynchronous dial.
    assert_receive {:core_init, _core_pid}, @recv_timeout
    assert DialCounter.count() == 1
  end

  ## 4. Timeout — deterministic: the deadline is shrunk to 100ms and the
  ## client simply waits (up to 2s) for the guaranteed-to-fire local timer;
  ## no sleep, no race — `Process.send_after/3` fires unconditionally once
  ## armed in `WSBridge.init/1`.

  test "the caller-auth deadline closes the connection when the caller sends nothing", %{
    proxy_host: host,
    proxy_port: port
  } do
    Application.put_env(:vagus, :core_ws_auth_timeout, 100)

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert decode_text({:text, raw})["type"] == "auth_invalid"

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1000, _}, frame)
    assert DialCounter.count() == 0
  end

  ## 5. Close propagation

  test "a Core-initiated close with code 4002 propagates to the caller verbatim", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_close_code", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, _auth_ok}, client} = Client.next_frame(client, @recv_timeout)

    client = Client.send_frame(client, {:text, "close:4002:bye"})
    {frame, _client} = Client.next_frame(client, @recv_timeout)

    assert {:close, 4002, "bye"} = frame
  end

  test "a caller-initiated close tears down the Core-side leg deterministically", %{
    proxy_host: host,
    proxy_port: port
  } do
    token = addon_token("cp_ws_caller_close", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, _auth_ok}, client} = Client.next_frame(client, @recv_timeout)

    assert_receive {:core_init, _core_pid}, @recv_timeout

    _client = Client.send_frame(client, :close)

    assert_receive {:core_terminate, _reason}, @recv_timeout
  end

  ## 6. Aliases

  test "/core/api/websocket reaches the same handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    assert_receive_auth_required(host, port, "/core/api/websocket")
  end

  test "/homeassistant/websocket reaches the same handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    assert_receive_auth_required(host, port, "/homeassistant/websocket")
  end

  test "/homeassistant/api/websocket reaches the same handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    assert_receive_auth_required(host, port, "/homeassistant/api/websocket")
  end

  defp assert_receive_auth_required(host, port, path) do
    {:ok, client, _headers} = Client.connect(host, port, path)
    {{:text, raw}, _client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_required"
  end

  ## 7. Non-upgrade / wrong-method — plain HTTP, no socket needed

  test "a non-upgrade GET /core/websocket gets a plain-text 400" do
    conn = Plug.Test.conn(:get, "/core/websocket")
    conn = Dispatcher.call(conn, @opts)

    assert conn.status == 400
    assert conn.resp_body == "Bad Request"
  end

  test "POST /core/websocket -> 405 Method Not Allowed" do
    conn = Plug.Test.conn(:post, "/core/websocket")
    conn = Dispatcher.call(conn, @opts)

    assert conn.status == 405
  end

  ## 8. Core-side handshake failure — both legs close, but the caller has
  ## already seen its own auth_ok by the time it happens (moduledoc's
  ## "auth_ok is sent before Core is known to be reachable at all").

  test "Core replying auth_invalid instead of auth_ok closes both legs after the caller's own auth_ok",
       %{proxy_host: host, proxy_port: port} do
    CoreAuthScript.set(:invalid)
    token = addon_token("cp_ws_core_rejects", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    assert_receive {:core_init, _core_pid}, @recv_timeout
    assert DialCounter.count() == 1

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  ## 9. Pending-buffer cap (review W3) — a caller flooding frames before Core
  ## finishes its own handshake overflows the bounded `pending` buffer and is
  ## closed 1011 rather than growing it without limit.

  test "a flood before Core's auth_ok overflows the pending cap and closes the caller 1011",
       %{proxy_host: host, proxy_port: port} do
    # Core dials + upgrades but STALLS its `auth_ok`, so `Upstream` stays
    # `ha_ready?: false` and every caller frame below buffers in `pending`.
    CoreAuthScript.set(:stall)
    # A tiny cap so a handful of frames overflow it; the 4th trips `frames > 3`.
    Application.put_env(:vagus, :core_ws_pending_max_frames, 3)
    token = addon_token("cp_ws_pending_flood", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})

    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    assert_receive {:core_init, _core_pid}, @recv_timeout

    # Exactly cap+1 frames: the 4th overflows and triggers the close. No frame
    # is sent AFTER the overflow-triggering one, so no send races a socket the
    # server is already tearing down.
    client =
      Enum.reduce(1..4, client, fn i, c ->
        Client.send_frame(c, {:text, "flood-#{i}"})
      end)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  ## 10-11 (issue #37): steady-state backpressure — a stalled Core wedges the
  ## Mint send, closing the caller with 1011 either via `Upstream`'s own
  ## `send_timeout` (test 10, the normal resolution) or via `WSBridge`'s own
  ## call timeout backstopping a send_timeout that hasn't fired yet (test 11).
  ## Both need Core to actually stop reading — a dedicated `FakeCore` with
  ## small kernel socket buffers, so the wedge establishes after a frame or
  ## two rather than however much a default ~200KB buffer can absorb.

  test "a stalled Core wedges the send; Upstream's own send_timeout closes the caller 1011", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_stall_core()
    Application.put_env(:vagus, :core_ws_send_timeout, 200)

    token = addon_token("cp_ws_stall_send_timeout", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    client = Client.send_frame(client, {:text, "stall"})

    payload = :crypto.strong_rand_bytes(256 * 1024)
    _client = flood_ignoring_send_errors(client, payload, 20)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  test "a stalled Core wedges the send; WSBridge's own handoff timeout backstops it and closes the caller 1011",
       %{proxy_host: host, proxy_port: port} do
    start_stall_core()
    Application.put_env(:vagus, :core_ws_send_timeout, 60_000)
    Application.put_env(:vagus, :core_ws_handoff_timeout, 200)

    token = addon_token("cp_ws_stall_handoff_timeout", %{homeassistant_api: true})

    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, _auth_required}, client} = Client.next_frame(client, @recv_timeout)
    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    client = Client.send_frame(client, {:text, "stall"})

    payload = :crypto.strong_rand_bytes(256 * 1024)
    _client = flood_ignoring_send_errors(client, payload, 20)

    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert match?({:close, 1011, _}, frame)
  end

  # A dedicated `FakeCore` with small kernel socket buffers (recbuf/buffer
  # 4096), so a stalled `CoreHandshakeHandler` wedges the Mint send after a
  # frame or two rather than however much a default ~200KB buffer can absorb
  # before backpressure reaches `Upstream`'s own `:gen_tcp.send`. Points
  # `:core_base_url` at it for the rest of the test — the outer `setup`'s own
  # `on_exit` already restores the pre-test value regardless of what a test
  # itself later puts there.
  defp start_stall_core do
    stall_core_pid =
      start_supervised!(
        {Bandit,
         plug: FakeCore,
         port: 0,
         thousand_island_options: [
           num_acceptors: 1,
           transport_options: [recbuf: 4096, buffer: 4096]
         ]},
        id: :stall_core_bandit
      )

    stall_core_port = listening_port(stall_core_pid)
    Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{stall_core_port}")
    stall_core_port
  end

  # Sends up to `n` frames, one at a time, tolerating the connection closing
  # partway through — once the wedged send trips a close, the caller-facing
  # socket can itself start refusing writes (the cascading backpressure this
  # whole test is about), and that's success, not a test failure: the
  # `assert_receive`-equivalent `Client.next_frame/2` right after this call is
  # what actually proves the close arrived.
  defp flood_ignoring_send_errors(client, _payload, 0), do: client

  defp flood_ignoring_send_errors(client, payload, n) do
    case safe_send_frame(client, {:binary, payload}) do
      {:ok, client} -> flood_ignoring_send_errors(client, payload, n - 1)
      :error -> client
    end
  end

  defp safe_send_frame(%Client{} = c, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(c.websocket, frame)

    case Mint.WebSocket.stream_request_body(c.conn, c.ref, data) do
      {:ok, conn} -> {:ok, %{c | conn: conn, websocket: websocket}}
      {:error, _conn, _reason} -> :error
    end
  rescue
    _ -> :error
  end

  ## 8. The Supervisor↔Core unix socket (A2/A3)

  # Points `Vagus.Core.Transport` at a handshake-free fake Core on a real
  # unix socket. The TCP fake Core from `setup` stays up on `:core_base_url`
  # and shares `DialCounter`, so a dial landing on the wrong one would still
  # be visible.
  defp start_core_socket do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_core_ws_#{System.unique_integer([:positive])}.sock"
      )

    start_supervised!(
      {Bandit,
       plug: Vagus.API.CoreProxyWSTest.FakeCoreSocket,
       port: 0,
       thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]},
      id: :fake_core_socket_bandit
    )

    Application.put_env(:vagus, :core_socket_path, path)

    on_exit(fn ->
      Application.put_env(:vagus, :core_socket_path, nil)
      File.rm(path)
    end)

    path
  end

  # The caller-facing half is unchanged by the transport: this proxy still
  # runs Core's handshake against the CALLER itself (fact 8).
  defp authenticate_caller(host, port, token) do
    {:ok, client, _headers} = Client.connect(host, port, "/core/websocket")
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_required"

    client = Client.send_frame(client, {:text, Jason.encode!(%{"access_token" => token})})
    {{:text, raw}, client} = Client.next_frame(client, @recv_timeout)
    assert Jason.decode!(raw)["type"] == "auth_ok"

    client
  end

  test "on the socket the proxy relays without ever running Core's auth handshake", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_core_socket()

    # Would raise if the Core-side credential were resolved at all — on the
    # socket it must not be.
    Application.put_env(:vagus, :core_proxy_access_token_fun, fn ->
      raise "access token resolved on the socket path"
    end)

    token = addon_token("cp_ws_socket", %{homeassistant_api: true})
    client = authenticate_caller(host, port, token)

    assert_receive {:core_socket_init, _core_pid}, @recv_timeout

    client = Client.send_frame(client, {:text, "hello"})
    {frame, client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}

    payload = :crypto.strong_rand_bytes(4_096)
    client = Client.send_frame(client, {:binary, payload})
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:binary, payload}

    refute_received {:core_socket_unexpected_auth, _data}
  end

  test "a handshake frame Core sends on the socket anyway is swallowed, not relayed", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_core_socket()
    token = addon_token("cp_ws_socket_auth_frame", %{homeassistant_api: true})
    client = authenticate_caller(host, port, token)

    assert_receive {:core_socket_init, _core_pid}, @recv_timeout

    client = Client.send_frame(client, {:text, "auth-then-hello"})

    # The caller already had its own `auth_ok` from this proxy — the one
    # Core just emitted must never reach it.
    {frame, _client} = Client.next_frame(client, @recv_timeout)
    assert frame == {:text, "world"}
  end

  test "frames sent before Core's socket upgrade completes are still delivered in order", %{
    proxy_host: host,
    proxy_port: port
  } do
    start_core_socket()
    token = addon_token("cp_ws_socket_pending", %{homeassistant_api: true})
    client = authenticate_caller(host, port, token)

    # `auth_ok` is pushed to the caller before `Upstream` has upgraded, so
    # these land in `pending` and are flushed on `{:done, ref}` — the socket
    # path's flush point.
    client = Client.send_frame(client, {:text, "one"})
    client = Client.send_frame(client, {:text, "two"})

    {frame1, client} = Client.next_frame(client, @recv_timeout)
    {frame2, _client} = Client.next_frame(client, @recv_timeout)

    assert frame1 == {:text, "one"}
    assert frame2 == {:text, "two"}
  end
end
