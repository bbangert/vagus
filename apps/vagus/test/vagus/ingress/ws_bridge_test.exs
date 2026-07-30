defmodule Vagus.Ingress.WSBridgeTest.EchoHandler do
  @moduledoc """
  A `WebSock` handler standing in for an ingress-enabled add-on's own
  WebSocket endpoint (e.g. ESPHome's dashboard console/log stream, §B5).
  Echoes text/binary frames verbatim; a special text command
  `"close:<code>:<reason>"` makes it close the connection with that exact
  code, to exercise `Vagus.Ingress.WSBridge`'s faithful close-code
  propagation. Reports its own lifecycle (`init/1`/`terminate/2`) to the
  test process via whatever pid was baked into its `state` at upgrade time,
  so the test can observe both ends of the two-hop relay deterministically
  (no sleeps).
  """
  @behaviour WebSock

  @impl WebSock
  def init(%{test_pid: test_pid, path: path, query: query} = state) do
    send(test_pid, {:echo_init, path, query})
    {:ok, state}
  end

  @impl WebSock
  def handle_in({"close:" <> rest, opcode: :text}, state) do
    case String.split(rest, ":", parts: 2) do
      [code_str, reason] ->
        {:stop, :normal, {String.to_integer(code_str), reason}, state}

      _other ->
        {:push, {:text, "close:" <> rest}, state}
    end
  end

  def handle_in({data, opcode: :text}, state), do: {:push, {:text, data}, state}
  def handle_in({data, opcode: :binary}, state), do: {:push, {:binary, data}, state}

  @impl WebSock
  def handle_control(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(reason, %{test_pid: test_pid}) do
    send(test_pid, {:echo_terminate, reason})
    :ok
  end
end

defmodule Vagus.Ingress.WSBridgeTest.FakeAddon do
  @moduledoc """
  Stands in for the add-on's own HTTP server: the single `/ws` route
  upgrades to `EchoHandler`, reporting the exact request path + query
  string it received (proving the upstream leg's path/query passthrough,
  independent of the browser-facing proxy's own path handling already
  covered by `Vagus.API.IngressProxyTest`).
  """
  use Plug.Router

  alias Vagus.Ingress.WSBridgeTest.EchoHandler

  plug(:match)
  plug(:dispatch)

  get "/ws" do
    test_pid = Application.fetch_env!(:vagus, :ws_bridge_test_pid)

    # audit F1/B1: captured here, in the Plug/handshake phase, rather than
    # inside `EchoHandler` — by the time a `WebSock` handler exists the
    # original HTTP request (and its headers) are gone; `conn.req_headers`
    # is only ever available on this side of the upgrade.
    send(test_pid, {:ws_upgrade_headers, conn.req_headers})

    WebSockAdapter.upgrade(
      conn,
      EchoHandler,
      %{test_pid: test_pid, path: conn.request_path, query: conn.query_string},
      timeout: 30_000
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule Vagus.Ingress.WSBridgeTest.Client do
  @moduledoc """
  A minimal hand-rolled `Mint.WebSocket` client, standing in for the
  browser — deliberately *not* reusing any Vagus code, since the whole
  point is to drive the bridge exactly as an external WS client would.
  Holds a small FIFO `queue` of already-decoded-but-unconsumed frames so
  `next_frame/2` can hand back one frame at a time regardless of how the
  underlying TCP messages happened to chunk.
  """

  defstruct [:conn, :ref, :websocket, queue: []]

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
      {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}, resp_headers}
    else
      {:error, status, conn}
    end
  end

  @type t :: %__MODULE__{}

  @spec send_frame(t(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) :: t()
  def send_frame(%__MODULE__{} = c, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(c.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(c.conn, c.ref, data)
    %{c | conn: conn, websocket: websocket}
  end

  @spec next_frame(t(), timeout()) :: {Mint.WebSocket.frame(), t()}
  def next_frame(%__MODULE__{queue: [frame | rest]} = c, _timeout) do
    {frame, %{c | queue: rest}}
  end

  def next_frame(%__MODULE__{queue: []} = c, timeout) do
    # Selective on purpose: this test process is *also* the recipient of
    # `EchoHandler`'s `{:echo_init, ...}`/`{:echo_terminate, ...}` lifecycle
    # messages (asserted separately via `assert_receive`). A catch-all
    # `receive do msg -> ... end` here would steal those out of the mailbox
    # before the test's own `assert_receive` ever saw them (and hand them
    # to `Mint.WebSocket.stream/2`, which — correctly — doesn't recognize
    # them and returns `:unknown`). Matching only genuine transport
    # messages leaves anything else in the mailbox, in order, for later.
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
          [frame | rest] -> {frame, %{c | queue: rest}}
        end
    end
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

  # Same selective-`receive` reasoning as `next_frame/2` above — this
  # process's mailbox may also carry `EchoHandler` lifecycle messages.
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
    end
  end

  defp find(responses, tag, ref) do
    Enum.find_value(responses, fn
      {^tag, ^ref, v} -> v
      _ -> nil
    end)
  end
end

defmodule Vagus.Ingress.WSBridgeTest do
  @moduledoc """
  IW-P4-T2: hermetic end-to-end tests for `Vagus.Ingress.WSBridge` (browser
  leg) + `Vagus.Ingress.WSBridge.Upstream` (add-on leg)
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B2.3), reusing
  `Vagus.API.IngressProxyTest`'s harness pattern: three real listening
  processes (a fake ingress-enabled add-on, the proxy stack itself, and
  `Vagus.Ingress.Finch` — unused by the WS leg but present in the stack
  exactly as `Vagus.API.Supervisor` wires it on a real device), driven by a
  fourth, the hand-rolled `Client` above standing in for the browser.
  """
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Config, State}
  alias Vagus.Ingress.WSBridgeTest.{Client, FakeAddon}

  setup do
    start_supervised!({Vagus.Ingress, []})
    start_supervised!({Finch, name: Vagus.Ingress.Finch})

    Application.put_env(:vagus, :ws_bridge_test_pid, self())

    addon_pid =
      start_supervised!(
        {Bandit, plug: FakeAddon, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :fake_addon_bandit
      )

    proxy_pid =
      start_supervised!(
        {Bandit,
         plug: Vagus.API.Dispatcher, port: 0, thousand_island_options: [num_acceptors: 1]},
        id: :proxy_bandit
      )

    addon_port = listening_port(addon_pid)
    proxy_port = listening_port(proxy_pid)

    slug = "ws_bridge_test_#{System.unique_integer([:positive])}"
    {:ok, config} = Config.parse(required_config(slug))
    :ok = State.put(config, :started)
    {:ok, entry} = State.get(slug)

    Application.put_env(:vagus, :ingress_target_fun, fn
      ^slug -> {:ok, {"127.0.0.1", addon_port}}
      _other -> {:error, :unknown_slug}
    end)

    on_exit(fn ->
      Application.delete_env(:vagus, :ingress_target_fun)
      Application.delete_env(:vagus, :ws_bridge_test_pid)
      State.delete(slug)
    end)

    %{
      slug: slug,
      token: entry.ingress_token,
      proxy_host: "127.0.0.1",
      proxy_port: proxy_port
    }
  end

  ## Helpers

  defp listening_port(bandit_pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  defp required_config(slug) do
    %{
      "name" => "WS Bridge Test Addon",
      "version" => "1.0.0",
      "slug" => slug,
      "description" => "fake ingress add-on for WSBridge tests",
      "arch" => ["amd64"],
      "ingress" => true,
      "ingress_port" => 8099
    }
  end

  defp cookie_header(session), do: {"cookie", "ingress_session=#{session}"}

  defp connect_client(host, port, token, path_and_query \\ "/ws") do
    {:ok, session} = Vagus.Ingress.create_session()

    Client.connect(host, port, "/ingress/#{token}#{path_and_query}", [
      cookie_header(session)
    ])
  end

  # `GenServer.dictionary`'s `$initial_call` is how OTP itself tags a
  # process's start function — used here (rather than any Vagus-internal
  # hook) to deterministically find the live `Upstream` pid for the
  # monitor-based cleanup assertion in test 5, without touching
  # `Vagus.Ingress.WSBridge`'s actual implementation to add a test-only
  # "report my pid" backdoor.
  defp find_upstream_pid do
    Enum.find(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          match?(
            {Vagus.Ingress.WSBridge.Upstream, :init, 1},
            Keyword.get(dict, :"$initial_call")
          )

        _ ->
          false
      end
    end)
  end

  ## 1. Text echo round-trip

  test "text frame round-trips through the full chain", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, client, _headers} = connect_client(host, port, token)

    assert_receive {:echo_init, "/ws", ""}, 2_000

    client = Client.send_frame(client, {:text, "hello ingress"})
    {frame, _client} = Client.next_frame(client, 2_000)

    assert frame == {:text, "hello ingress"}
  end

  ## 1b. Header forwarding on the WS leg (audit F1/B1)

  test "the WS upgrade forwards the browser's filtered headers to the add-on verbatim", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    {:ok, _client, _resp_headers} =
      Client.connect(host, port, "/ingress/#{token}/ws", [
        cookie_header(session),
        {"x-ingress-path", "/api/hassio_ingress/#{token}"},
        {"x-hass-source", "core.uso"},
        {"x-forwarded-proto", "https"},
        {"x-forwarded-host", "homeassistant.local"},
        {"user-agent", "vagus-test-browser/1.0"},
        # Must never reach the add-on — the auth/identity strip
        # (`IngressProxy.strip_request_headers/1`) applies identically here.
        {"x-supervisor-token", "should-never-arrive"},
        {"x-hassio-key", "should-never-arrive"},
        {"x-remote-user-id", "should-never-arrive"}
      ])

    assert_receive {:ws_upgrade_headers, headers}, 2_000

    by_name =
      Enum.reduce(headers, %{}, fn {k, v}, acc ->
        Map.update(acc, String.downcase(k), [v], &(&1 ++ [v]))
      end)

    assert by_name["cookie"] == ["ingress_session=#{session}"]
    assert by_name["x-ingress-path"] == ["/api/hassio_ingress/#{token}"]
    assert by_name["x-hass-source"] == ["core.uso"]
    assert by_name["x-forwarded-proto"] == ["https"]
    assert by_name["x-forwarded-host"] == ["homeassistant.local"]
    assert by_name["user-agent"] == ["vagus-test-browser/1.0"]
    assert by_name["x-forwarded-for"] == ["127.0.0.1"]

    refute Map.has_key?(by_name, "x-supervisor-token")
    refute Map.has_key?(by_name, "x-hassio-key")
    refute Map.has_key?(by_name, "x-remote-user-id")

    # [VERIFIED]: `Mint.HTTP1.add_default_headers/2`
    # (`deps/mint/lib/mint/http1.ex:1167-1170`) is `Headers.put_new("Host",
    # "host", ...)` — it only fills in a `Host` when one isn't already
    # present in the outgoing header list. Since `headers` (the forwarded
    # set) already carries the browser's own `Host`, Mint's own upgrade
    # request adds no second one — exactly one `host` header reaches the
    # add-on, and it's the browser's value, not the upstream connection's
    # own `ip:port` authority.
    assert by_name["host"] != nil
    assert length(by_name["host"]) == 1

    # `Mint.WebSocket.upgrade/5` always prepends its own
    # `connection`/`sec-websocket-*` handshake headers
    # (`deps/mint_web_socket/lib/mint/web_socket/utils.ex`'s `headers/2`) —
    # these must appear exactly once, not doubled with anything forwarded
    # from the browser's own handshake to the proxy (which
    # `strip_request_headers/1`'s hop-by-hop + `sec-websocket-` prefix strip
    # already excludes from `headers` entirely).
    assert by_name["connection"] == ["upgrade"]
    assert length(by_name["sec-websocket-key"]) == 1
    assert length(by_name["sec-websocket-version"]) == 1
  end

  test "an inbound x-forwarded-for is appended to, not overwritten, on the WS leg (audit B1/B2.2)",
       %{proxy_host: host, proxy_port: port, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    # testing-phase7.md Warning: the test above (and `ingress_proxy_test.exs`'s
    # HTTP-leg equivalent, before its own fix) sends no inbound
    # `x-forwarded-for` at all, so `append_forwarded_for/2`'s `existing <>
    # ", " <> peer` branch — the actual audited multi-hop behavior — had
    # zero coverage on either leg. `IngressProxy.build_request_headers/1` is
    # the one function both legs share (this module's own moduledoc, and
    # `upgrade_websocket/4`'s comment above it), so this pins it here too.
    {:ok, _client, _resp_headers} =
      Client.connect(host, port, "/ingress/#{token}/ws", [
        cookie_header(session),
        {"x-forwarded-for", "203.0.113.9"}
      ])

    assert_receive {:ws_upgrade_headers, headers}, 2_000

    by_name =
      Enum.reduce(headers, %{}, fn {k, v}, acc ->
        Map.update(acc, String.downcase(k), [v], &(&1 ++ [v]))
      end)

    assert by_name["x-forwarded-for"] == ["203.0.113.9, 127.0.0.1"]
  end

  ## 2. Binary echo round-trip — 100KB, sha256 verified intact

  test "a 100KB binary frame survives intact (sha256 match)", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, client, _headers} = connect_client(host, port, token)
    assert_receive {:echo_init, _path, _query}, 2_000

    payload = :crypto.strong_rand_bytes(100_000)
    expected_sha = :crypto.hash(:sha256, payload)

    client = Client.send_frame(client, {:binary, payload})
    {frame, _client} = Client.next_frame(client, 5_000)

    assert {:binary, echoed} = frame
    assert byte_size(echoed) == 100_000
    assert :crypto.hash(:sha256, echoed) == expected_sha
  end

  ## 3. Multiple frames, both directions, ordering preserved

  test "5 frames sent in order are received back in the same order", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, client, _headers} = connect_client(host, port, token)
    assert_receive {:echo_init, _path, _query}, 2_000

    messages = for i <- 1..5, do: "msg-#{i}"

    client = Enum.reduce(messages, client, fn msg, c -> Client.send_frame(c, {:text, msg}) end)

    {received, _client} =
      Enum.map_reduce(messages, client, fn _msg, c ->
        Client.next_frame(c, 2_000)
      end)

    assert Enum.map(received, fn {:text, data} -> data end) == messages
  end

  ## 4. Upstream close with a specific code -> faithful propagation

  test "an upstream close with code 4321 propagates to the client verbatim", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, client, _headers} = connect_client(host, port, token)
    assert_receive {:echo_init, _path, _query}, 2_000

    client = Client.send_frame(client, {:text, "close:4321:bye"})
    {frame, _client} = Client.next_frame(client, 2_000)

    assert {:close, 4321, "bye"} = frame
  end

  ## 5. Client-initiated close -> upstream terminate fires, Upstream exits

  test "a client close tears down the upstream leg deterministically", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, client, _headers} = connect_client(host, port, token)
    assert_receive {:echo_init, _path, _query}, 2_000

    # Round-trip one frame first: by the time we've seen it echoed back,
    # both the browser leg's `Upstream` GenServer and its own upgraded
    # connection to the fake add-on are proven fully live (not just
    # "started", but actually relaying) — no sleep needed to know the
    # upstream pid we're about to look up already exists.
    client = Client.send_frame(client, {:text, "ping"})
    {{:text, "ping"}, client} = Client.next_frame(client, 2_000)

    upstream_pid = find_upstream_pid()
    assert is_pid(upstream_pid)
    ref = Process.monitor(upstream_pid)

    _client = Client.send_frame(client, :close)

    # The echo server's own `terminate/2` firing proves
    # `Vagus.Ingress.WSBridge.terminate/2` (invoked because the *browser*
    # side closed) actually stopped the `Upstream` GenServer, which in turn
    # best-effort sent its own close frame to the fake add-on before
    # closing its socket.
    assert_receive {:echo_terminate, _reason}, 2_000

    # `GenServer.stop/3` (used in `Vagus.Ingress.WSBridge.terminate/2`) is
    # synchronous, so by the time it returns the `Upstream` process has
    # already exited — this `:DOWN` is a formality confirming it, not a
    # race we're hoping to win.
    assert_receive {:DOWN, ^ref, :process, ^upstream_pid, _reason}, 2_000
  end

  ## 6. Missing/invalid session cookie -> 401, never upgrades (regression)

  test "a WS upgrade attempt without a valid session cookie gets a plain 401, never upgrades", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    assert {:error, 401, conn} =
             Client.connect(host, port, "/ingress/#{token}/ws", [])

    Mint.HTTP.close(conn)
  end

  ## 7. Query string reaches the echo server

  test "the query string reaches the add-on's own WS endpoint intact", %{
    proxy_host: host,
    proxy_port: port,
    token: token
  } do
    {:ok, _client, _headers} = connect_client(host, port, token, "/ws?foo=bar&baz=1")

    assert_receive {:echo_init, "/ws", "foo=bar&baz=1"}, 2_000
  end

  ## 8-9 (W3): Upstream driven directly — pending-buffer cap + upgrade
  ## deadline, against a raw listener that accepts but never upgrades.

  describe "Upstream direct (W3: pending cap + upgrade deadline)" do
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Accept the connection but never reply — the add-on's TCP is alive,
      # its WS handshake stalls forever, exactly the scenario W3 defends
      # against.
      spawn_link(fn ->
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, _socket} -> receive(do: (:never_sent -> :ok))
          {:error, _reason} -> :ok
        end
      end)

      on_exit(fn -> :gen_tcp.close(listen) end)

      %{port: port}
    end

    test "casting frames past :pending_max_bytes closes the parent with 1011", %{port: port} do
      args = %{
        parent: self(),
        ip: "127.0.0.1",
        port: port,
        path: "/ws",
        protocols: [],
        headers: [],
        pending_max_bytes: 5,
        pending_max_frames: 256,
        upgrade_deadline_ms: 60_000
      }

      {:ok, pid} = Vagus.Ingress.WSBridge.Upstream.start_link(args)
      ref = Process.monitor(pid)

      GenServer.cast(pid, {:frame, :binary, :binary.copy(<<0>>, 10)})

      assert_receive {:upstream_close, 1011, ""}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    test "casting more than :pending_max_frames closes the parent with 1011", %{port: port} do
      args = %{
        parent: self(),
        ip: "127.0.0.1",
        port: port,
        path: "/ws",
        protocols: [],
        headers: [],
        pending_max_bytes: 1_000_000,
        pending_max_frames: 3,
        upgrade_deadline_ms: 60_000
      }

      {:ok, pid} = Vagus.Ingress.WSBridge.Upstream.start_link(args)
      ref = Process.monitor(pid)

      for _ <- 1..4, do: GenServer.cast(pid, {:frame, :text, "hi"})

      assert_receive {:upstream_close, 1011, ""}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    test "the upgrade deadline closes the parent with 1011 when the 101 never arrives", %{
      port: port
    } do
      args = %{
        parent: self(),
        ip: "127.0.0.1",
        port: port,
        path: "/ws",
        protocols: [],
        headers: [],
        upgrade_deadline_ms: 30
      }

      {:ok, pid} = Vagus.Ingress.WSBridge.Upstream.start_link(args)
      ref = Process.monitor(pid)

      assert_receive {:upstream_close, 1011, ""}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end
end
