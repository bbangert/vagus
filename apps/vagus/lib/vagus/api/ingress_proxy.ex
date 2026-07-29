defmodule Vagus.API.IngressProxy do
  @moduledoc """
  The ingress HTTP reverse-proxy leg (`docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B2), reached only via `Vagus.API.Dispatcher`'s `["ingress", token | rest]`
  routing rule — **never** through `Vagus.API.Router`, and deliberately with
  no `Plug.Parsers` anywhere upstream of this module (see
  `Vagus.API.Dispatcher`'s moduledoc for why).

  ## Auth is 100% the session cookie (§B1.4)

  The real Supervisor's `/ingress/{token}/.*` route bypasses the
  `X-Supervisor-Token`/`Authorization` middleware entirely — the *only*
  gate is a valid `ingress_session` cookie, checked (and slid another 15
  minutes via `Vagus.Ingress.validate_session/1`) on every single proxied
  request. No token/cookie means a plain-text 401, no JSON envelope — this
  path is outside the router, so there is no `Vagus.API.Envelope` to wrap
  it (upstream's equivalent raises `aiohttp.web.HTTPUnauthorized`, itself a
  plain-text response).

  ## Request flow (§B2.2)

  1. `ingress_session` cookie → `Vagus.Ingress.validate_session/1`; `:error`
     or missing cookie → 401.
  2. `{token}` (the path segment right after `/ingress/`) →
     `Vagus.Ingress.resolve_token/1` → add-on slug; unresolvable → 503
     (upstream: `HTTPServiceUnavailable`).
  3. slug → `{ip, port}` via `config :vagus, :ingress_target_fun` (default
     `&default_target/1`, injectable so tests can point at a fake add-on
     without a real docker daemon/container) → resolution failure → 502.
  4. A `Connection: upgrade` + `Upgrade: websocket` request upgrades via
     `WebSockAdapter.upgrade/4` to `Vagus.Ingress.WSBridge` — the two-linked-
     process bridge described in the research doc §2 and that module's own
     moduledoc (§B2.3). Auth/target resolution above already happened by
     the time this branch runs; the bridge itself never touches either.
  5. Otherwise, the plain-HTTP leg: stream the request body into `Finch`,
     stream the response back out, following
     `.claude/plans/vagus-m4-ingress-watchdog/research/proxy-approach.md`
     §1 exactly (Finch/Mint's request/response streaming is
     request-then-stream-response, never duplex — which is what makes the
     "thread the final `conn` back out of the request-body stream" trick
     below safe, see `build_request_body/1`). `path_info` segments are
     joined back into the upstream path **verbatim** (see `build_url/4`'s
     doc comment) — they arrive already percent-encoded exactly as the
     browser sent them; `path_info` is never percent-decoded anywhere in
     this stack.

  Never buffers a body. Per-chunk memory stays ~64KB either direction —
  load-bearing on a 1GB device.
  """

  @behaviour Plug

  import Plug.Conn

  alias Vagus.Addon.State
  alias Vagus.Network

  # Two pools, differing only in whether they bind the supervisor anchor as
  # the source address; `finch_for/1` picks per request. See
  # `Vagus.Network.source_bind_opts/1` for why the choice is keyed on the
  # destination — a bridge add-on filtering on client IP needs the `.2`
  # origin, a `host_network: true` add-on reached on loopback is refused by
  # it. Finch fixes `conn_opts` per pool at startup, so this cannot be a
  # per-request option.
  @finch Vagus.Ingress.Finch
  @local_finch Vagus.Ingress.LocalFinch

  # 15 minutes — matches the ingress session's sliding-window idle timeout
  # (`Vagus.Ingress` §B1.2) and `Vagus.API.Supervisor`'s Thousand Island
  # `read_timeout`. A short default here would kill a legitimately
  # slow-but-alive upstream (e.g. a large firmware upload, or a
  # long-polling/log-tail response) well before the session itself would
  # ever time the client out.
  @receive_timeout 900_000

  # RFC 7230 §6.1 hop-by-hop headers: meaningful only for a single
  # transport-level hop, never something to relay to (or receive verbatim
  # from) the next hop. Stripped both directions.
  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization
                 te trailer transfer-encoding upgrade)

  # §B2.2 step 4's inbound strip list, beyond the RFC hop-by-hop set: the
  # framing headers we recompute ourselves (Finch derives its own
  # content-length/encoding for the outgoing request), the WebSocket
  # handshake headers (irrelevant on the plain-HTTP leg; the WS branch
  # never reaches here), and the auth/identity headers that must never leak
  # from the browser session into the add-on's view of the request.
  #
  # `cookie` and an inbound `x-forwarded-for` are deliberately NOT in this
  # list — contract parity with §B2.2, whose strip list omits both, and with
  # upstream's own behavior (it preserves any existing XFF, then appends its
  # own peer view, exactly like `append_forwarded_for/2` below does here).
  # The wider blast radius this implies — a leaked ingress token rides the
  # same global session cookie every add-on's ingress traffic shares — is a
  # real design tradeoff, tracked for the P5-T1 device gate rather than
  # fixed here.
  @request_strip_extra ~w(content-length content-encoding x-supervisor-token x-hassio-key)

  # §B2.2 step 7's outbound strip list: Plug re-derives its own framing via
  # `send_resp`/`send_chunked`+`chunk`, so forwarding the upstream's raw
  # content-length/transfer-encoding verbatim would conflict with it.
  @response_strip_extra ~w(content-length transfer-encoding)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    ["ingress", token | rest] = conn.path_info

    with :ok <- check_session(conn),
         {:ok, slug} <- Vagus.Ingress.resolve_token(token),
         {:ok, {ip, port}} <- resolve_target(slug) do
      proxy(conn, ip, port, rest)
    else
      :unauthorized -> send_plain(conn, 401, "Unauthorized")
      :error -> send_plain(conn, 503, "Service Unavailable")
      {:error, _reason} -> send_plain(conn, 502, "Bad Gateway")
    end
  end

  @doc """
  Default `:ingress_target_fun` — resolves `slug` to `{ip, port}` from
  `Vagus.Addon.State` (the port) and a live docker inspect of
  `addon_<slug>` (the container's `hassio` bridge IP), mirroring
  `Vagus.Addon.Manager`'s `register_dns/3` IP-lookup pattern.
  """
  @spec default_target(String.t()) :: {:ok, {String.t(), pos_integer()}} | {:error, term()}
  def default_target(slug) do
    case State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, entry} ->
        with {:ok, port} <- resolve_port(entry),
             {:ok, ip} <- resolve_ip(slug, entry) do
          {:ok, {ip, port}}
        end
    end
  end

  # The resolved dynamic/settings port (`Vagus.Ingress.dynamic_port/2`'s
  # persisted result) wins when present; otherwise fall back to the
  # config-declared static port, when it's a real (non-zero) port rather
  # than the `ingress_port: 0` "assign one dynamically" sentinel.
  defp resolve_port(%{ingress_port: port}) when is_integer(port) and port > 0, do: {:ok, port}

  defp resolve_port(%{config: %{ingress_port: port}}) when is_integer(port) and port > 0,
    do: {:ok, port}

  defp resolve_port(_entry), do: {:error, :no_ingress_port}

  # A `host_network: true` add-on (e.g. ESPHome) has no `hassio` bridge IP —
  # its ingress port is bound on the host itself, i.e. this emulator's
  # loopback. Same rule as `Vagus.Addon.Watchdog.Probe`'s default
  # `:host_ip_fun` (§B7).
  defp resolve_ip(_slug, %{config: %{host_network: true}}), do: {:ok, "127.0.0.1"}

  defp resolve_ip(slug, _entry) do
    id = "addon_#{slug}"

    with {:ok, %{"NetworkSettings" => %{"Networks" => networks}}} <-
           Vagus.Runtime.Docker.inspect_container(id),
         %{"IPAddress" => ip} when is_binary(ip) and ip != "" <-
           Map.get(networks, Network.name()) do
      {:ok, ip}
    else
      _ -> {:error, :no_container_ip}
    end
  end

  ## Session + target resolution

  defp check_session(conn) do
    case conn.cookies["ingress_session"] do
      session when is_binary(session) ->
        case Vagus.Ingress.validate_session(session) do
          :ok -> :ok
          :error -> :unauthorized
        end

      _missing ->
        :unauthorized
    end
  end

  defp resolve_target(slug) do
    fun = Application.get_env(:vagus, :ingress_target_fun, &default_target/1)
    fun.(slug)
  end

  ## WS upgrade seam

  defp proxy(conn, ip, port, rest) do
    if websocket_upgrade?(conn) do
      upgrade_websocket(conn, ip, port, rest)
    else
      proxy_http(conn, ip, port, rest)
    end
  end

  defp websocket_upgrade?(conn) do
    connection_header_has_upgrade?(conn) and upgrade_header_is_websocket?(conn)
  end

  defp connection_header_has_upgrade?(conn) do
    conn
    |> get_req_header("connection")
    |> Enum.any?(&String.contains?(String.downcase(&1), "upgrade"))
  end

  defp upgrade_header_is_websocket?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  ## WebSocket bridge leg (IW-P4-T1) — §B2.3, research §2. The actual bridge
  ## implementation (the two-linked-process browser/upstream design) lives
  ## in `Vagus.Ingress.WSBridge`; this module's job stops at the upgrade
  ## call itself.

  defp upgrade_websocket(conn, ip, port, rest) do
    protocols = requested_subprotocols(conn)
    conn = maybe_negotiate_subprotocol(conn, protocols)

    WebSockAdapter.upgrade(
      conn,
      Vagus.Ingress.WSBridge,
      %{target: {ip, port}, path: build_ws_path(rest, conn.query_string), protocols: protocols},
      # `:timeout` here is WebSockAdapter/Bandit's *post-upgrade* idle
      # timeout — a knob entirely separate from Thousand Island's own
      # connection-level `read_timeout` (research §3's gotcha). Both are
      # deliberately set to the same 15 minutes as the ingress session's
      # own sliding-window idle expiry (`@receive_timeout`, matching
      # `Vagus.Ingress` §B1.2) rather than left to their differing defaults
      # (WebSockAdapter 60s, Thousand Island 60s) to coincidentally agree.
      timeout: @receive_timeout,
      # §B2.3: upstream's `web.WebSocketResponse(..., max_msg_size=16 MiB)`.
      max_frame_size: 16_777_216
    )
  end

  # Same upstream path the HTTP leg would use (`build_url/4`'s verbatim,
  # never-percent-decoded `rest` join — see that function's doc comment),
  # minus the `http://{ip}:{port}` prefix: `Mint.WebSocket.upgrade/5` takes
  # a path, the connection itself already carries the host.
  defp build_ws_path(rest, query_string) do
    path = "/" <> Enum.join(rest, "/")
    if query_string == "", do: path, else: path <> "?" <> query_string
  end

  defp requested_subprotocols(conn) do
    conn
    |> get_req_header("sec-websocket-protocol")
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
  end

  # [VERIFIED, not a [VERIFY] gap]: `Bandit.WebSocket.Handshake.send_handshake/2`
  # (`deps/bandit/lib/bandit/websocket/handshake.ex:72-81`) builds the 101
  # response headers as the RFC-mandated three (`upgrade`/`connection`/
  # `sec-websocket-accept`) ++ any negotiated extension header ++
  # `conn.resp_headers` **verbatim** — and `WebSockAdapter.upgrade/4` itself
  # never touches `resp_headers` (it only calls `Plug.Conn.upgrade_adapter/3`).
  # So a `put_resp_header/3` called here, before the upgrade, genuinely
  # reaches the browser's 101 response on Bandit. Confirmed both by reading
  # that source and empirically in `ws_bridge_test.exs`'s subprotocol
  # assertion. We echo back the browser's FIRST requested subprotocol
  # (the common non-negotiating convention) without waiting to see what the
  # add-on itself selects — by the time the add-on's own 101 arrives,
  # Bandit has already committed ours (the upgrade to `Bandit.WebSocket.Handler`,
  # and thus `Vagus.Ingress.WSBridge.init/1` dialing the add-on, only happens
  # *after* our 101 is already on the wire). A narrow, accepted deviation:
  # ESPHome's console does not require subprotocol negotiation to function.
  defp maybe_negotiate_subprotocol(conn, []), do: conn

  defp maybe_negotiate_subprotocol(conn, [first | _rest]) do
    put_resp_header(conn, "sec-websocket-protocol", first)
  end

  ## Plain-HTTP leg

  defp proxy_http(conn, ip, port, rest) do
    url = build_url(ip, port, rest, conn.query_string)
    headers = build_request_headers(conn)
    {body, ref} = build_request_body(conn)
    request = Finch.build(conn.method, url, headers, body)

    acc = %{conn: conn, ref: ref, resolved?: ref == nil, status: nil, mode: nil}

    request
    |> Finch.stream_while(finch_for(ip), acc, &handle_event/2, receive_timeout: @receive_timeout)
    |> finish()
  end

  # A loopback destination is a `host_network: true` add-on (`resolve_ip/2`),
  # which must be dialled without the anchor bind.
  defp finch_for(ip), do: if(Network.loopback?(ip), do: @local_finch, else: @finch)

  # [DEVIATION from the task brief's stated premise]: `path_info` segments
  # are **not** percent-decoded by the time they reach a plug — confirmed
  # empirically (a `%20` in the URL arrived as a literal `%20`, not a
  # space, in `conn.path_info`) and in source:
  # `Plug.Conn.Adapter.conn/5`'s `split_path/1`
  # (`deps/plug/lib/plug/conn/adapter.ex:49-52`) is `:binary.split(path,
  # "/", [:global])` with no `URI.decode` anywhere, and Bandit's own
  # `Bandit.Pipeline.determine_path_and_query/1`
  # (`deps/bandit/lib/bandit/pipeline.ex:109-122`) — which builds the `%URI{}`
  # `Plug.Conn.Adapter.conn/5` receives — likewise just splits on `?`/`#`,
  # never decoding either. So `rest` here is already exactly as
  # percent-encoded as the original request line; re-encoding it (as the
  # task brief originally called for) would double-encode any existing
  # `%XX` escape. Joining verbatim is not just simpler but the *only*
  # correct option, and happens to match upstream's own behavior more
  # directly too (`api/ingress.py`'s `_create_url` forwards the path
  # without re-decoding/re-encoding it either).
  defp build_url(ip, port, rest, query_string) do
    path = Enum.join(rest, "/")
    base = "http://#{ip}:#{port}/#{path}"
    if query_string == "", do: base, else: base <> "?" <> query_string
  end

  defp build_request_headers(conn) do
    conn.req_headers
    |> strip_request_headers()
    |> append_forwarded_for(conn)
  end

  defp strip_request_headers(headers) do
    Enum.reject(headers, fn {k, _v} ->
      k = String.downcase(k)

      k in @hop_by_hop or k in @request_strip_extra or
        String.starts_with?(k, "sec-websocket-") or
        String.starts_with?(k, "x-remote-user-")
    end)
  end

  # Existing value (if any) + ", " + the browser's peer IP as seen by this
  # hop — matching §B2.2 step 4's "re-appended again with Supervisor's own
  # peer view" (here Vagus is the only hop, so there's just the one
  # append).
  defp append_forwarded_for(headers, conn) do
    peer = conn.remote_ip |> :inet.ntoa() |> to_string()

    {existing, rest} =
      Enum.split_with(headers, fn {k, _} -> String.downcase(k) == "x-forwarded-for" end)

    value =
      case existing do
        [{_, v} | _] -> v <> ", " <> peer
        [] -> peer
      end

    rest ++ [{"x-forwarded-for", value}]
  end

  # Only attach a stream body when the request can actually carry one —
  # matching the real Supervisor's own POST-only-when-declared streaming
  # (§B3.3); everything else (GET, HEAD, a bodyless POST) passes `nil`.
  #
  # Not a lossy simplification: per RFC 7230 §3.3, an HTTP/1.1 request with
  # neither `Content-Length` nor `Transfer-Encoding: chunked` framing has no
  # body at all — there is nothing to read (Bandit itself couldn't produce
  # one either), so treating the absence of both headers as bodyless is
  # exactly correct, not an approximation.
  defp has_body?(conn) do
    case get_req_header(conn, "content-length") do
      [cl] ->
        case Integer.parse(cl) do
          {n, _} -> n > 0
          :error -> false
        end

      [] ->
        conn
        |> get_req_header("transfer-encoding")
        |> Enum.any?(&String.contains?(String.downcase(&1), "chunked"))
    end
  end

  # Streams the request body into Finch via `Stream.resource/3` over
  # `Plug.Conn.read_body/2`, never holding more than one `read_length`
  # (64KB) chunk in memory — the whole point of splitting this proxy out
  # from underneath `Plug.Parsers` (research §3 gotcha 1).
  #
  # Plug requires using the conn `read_body/2` returns on every subsequent
  # call, but the stream's `next_fun` runs *inside* Finch (whichever
  # process calls `Finch.stream_while/5` below — always this same process,
  # since Finch/Mint never hands request-body enumeration off to another
  # process), not in `call/2`'s own stack frame. Threading it back out via
  # `send(self(), ...)` + a later `receive` in that same process is safe
  # specifically *because* Finch's request/response streaming is
  # request-then-stream-response, never duplex (research §1): the entire
  # body is drained before the first `{:status, _}` response event ever
  # reaches `handle_event/2`, so the message is always already sitting in
  # our own mailbox by the time we go looking for it — this never blocks.
  # (A non-blocking `receive ... after 0` in `resolve_conn/1` is a defensive
  # fallback, not something expected to ever miss.) The process dictionary
  # would work as well; a message is preferred so nothing survives past
  # this one request if something above changes.
  defp build_request_body(conn) do
    if has_body?(conn) do
      ref = make_ref()
      parent = self()

      stream =
        Stream.resource(
          fn -> conn end,
          fn
            :done ->
              {:halt, :done}

            conn ->
              case read_body(conn, read_length: 64_000) do
                {:more, data, conn} ->
                  {[data], conn}

                {:ok, data, conn} ->
                  send(parent, {ref, conn})
                  {[data], :done}
              end
          end,
          fn
            :done -> :ok
            %Plug.Conn{} = leftover_conn -> send(parent, {ref, leftover_conn})
          end
        )

      {{:stream, stream}, ref}
    else
      {nil, nil}
    end
  end

  ## Response streaming (Finch.stream_while/5)

  defp resolve_conn(%{resolved?: true} = acc), do: acc

  defp resolve_conn(%{ref: ref, conn: conn} = acc) do
    final_conn =
      receive do
        {^ref, c} -> c
      after
        0 -> conn
      end

    %{acc | conn: final_conn, resolved?: true}
  end

  defp handle_event(event, acc) do
    acc = resolve_conn(acc)
    do_handle_event(event, acc)
  end

  defp do_handle_event({:status, status}, acc) do
    {:cont, %{acc | status: status}}
  end

  defp do_handle_event({:headers, headers}, acc) do
    conn =
      headers
      |> strip_response_headers()
      |> Enum.reduce(acc.conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      |> put_resp_header("x-accel-buffering", "no")

    if empty_body_status?(acc.status) or conn.method == "HEAD" do
      conn = send_resp(conn, acc.status, "")
      {:halt, %{acc | conn: conn, mode: :empty}}
    else
      conn = send_chunked(conn, acc.status)
      {:cont, %{acc | conn: conn, mode: :chunked}}
    end
  end

  defp do_handle_event({:data, chunk}, acc) do
    case chunk(acc.conn, chunk) do
      {:ok, conn} -> {:cont, %{acc | conn: conn}}
      # The client hung up mid-stream — nothing more to do but stop.
      {:error, _reason} -> {:halt, %{acc | conn: halt(acc.conn)}}
    end
  end

  defp do_handle_event({:trailers, _trailers}, acc), do: {:cont, acc}

  defp strip_response_headers(headers) do
    Enum.reject(headers, fn {k, _v} ->
      k = String.downcase(k)
      k in @hop_by_hop or k in @response_strip_extra
    end)
  end

  defp empty_body_status?(status) when status in [204, 304], do: true
  defp empty_body_status?(status) when status >= 100 and status < 200, do: true
  defp empty_body_status?(_status), do: false

  defp finish({:ok, acc}) do
    acc |> resolve_conn() |> Map.fetch!(:conn)
  end

  defp finish({:error, _finch_error, acc}) do
    acc = resolve_conn(acc)

    case acc.mode do
      # Nothing sent to the browser yet (a connect/handshake failure before
      # any response event arrived) — safe to send an honest 502.
      nil -> send_plain(acc.conn, 502, "Bad Gateway")
      # Already mid-response (`send_resp`/`send_chunked` already called) —
      # a second response would raise `Plug.Conn.AlreadySentError`; just halt.
      _started -> halt(acc.conn)
    end
  end

  defp send_plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
