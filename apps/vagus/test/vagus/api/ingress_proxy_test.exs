defmodule Vagus.API.IngressProxyTest.HitCounter do
  @moduledoc "Counts requests the fake add-on Bandit actually received — proves an unauthorized/unresolvable request never reaches it."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def bump, do: Agent.update(__MODULE__, &(&1 + 1))
  def count, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.IngressProxyTest.FakeAddon do
  @moduledoc """
  Stands in for an ingress-enabled add-on's own HTTP server: no
  `Plug.Parsers`, only the raw routes `Vagus.API.IngressProxyTest` needs to
  prove the proxy's streaming/header/status behavior end to end.
  """
  use Plug.Router

  alias Vagus.API.IngressProxyTest.HitCounter

  plug(:bump_hits)
  plug(:match)
  plug(:dispatch)

  defp bump_hits(conn, _opts) do
    HitCounter.bump()
    conn
  end

  # POST body >64KB regression case: proves the proxy streamed every byte
  # rather than a `Plug.Parsers`-truncated prefix.
  post "/echo-body" do
    {body, conn} = read_full_body(conn)

    send_json(conn, 200, %{
      size: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    })
  end

  # Reflects every request header back as JSON, as the RAW ordered list
  # (`[[name, value], ...]`), not a `Map.new/1`-collapsed object —
  # testing-phase7.md's Warning: `Map.new/1` silently collapses duplicate
  # keys, so a regression that made `build_request_headers/1` emit two
  # `Host` headers would be invisible to a map-shaped echo. The WS leg
  # (`ws_bridge_test.exs`) already asserts "exactly one `host`" against a
  # raw list for exactly this reason; this route now lets the HTTP leg prove
  # the same property instead of resting on "the builder is shared" alone.
  get "/echo-headers" do
    send_json(conn, 200, %{headers: Enum.map(conn.req_headers, fn {k, v} -> [k, v] end)})
  end

  # audit F4: the POST counterpart, draining whatever body arrived first.
  post "/echo-headers" do
    {_body, conn} = read_full_body(conn)
    send_json(conn, 200, %{headers: Enum.map(conn.req_headers, fn {k, v} -> [k, v] end)})
  end

  get "/stream3" do
    conn = send_chunked(conn, 200)
    {:ok, conn} = chunk(conn, "chunk1-")
    {:ok, conn} = chunk(conn, "chunk2-")
    {:ok, conn} = chunk(conn, "chunk3")
    conn
  end

  get "/empty204" do
    send_resp(conn, 204, "")
  end

  # audit F2: two `Set-Cookie` + two `Link` headers — `Map.new/1` (used by
  # `/echo-headers` above) would collapse these, so the client asserts
  # against `Finch.Response.headers` directly instead (a raw list,
  # preserving every occurrence and its order).
  get "/multi-headers" do
    conn
    |> prepend_resp_headers([
      {"set-cookie", "a=1"},
      {"set-cookie", "b=2"},
      {"link", "</one>; rel=preload"},
      {"link", "</two>; rel=preload"}
    ])
    |> send_resp(200, "ok")
  end

  # audit F5: an add-on-set `cache-control` must survive the proxy's own
  # cache-control/vary strip untouched.
  get "/own-cache-control" do
    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, "cached")
  end

  # security-phase7.md W3: a malicious/compromised add-on trying to
  # overwrite the shared `ingress_session` cookie by answering with its own
  # `Set-Cookie` for that exact name, alongside an unrelated cookie of its
  # own — the latter must still survive F2's multi-valued-header handling.
  get "/session-fixation-attempt" do
    conn
    |> prepend_resp_headers([
      {"set-cookie", "ingress_session=evil"},
      {"set-cookie", "sid=ok"}
    ])
    |> send_resp(200, "ok")
  end

  # audit F5: a typical add-on's own HTTP stack (rarely Plug-based — real
  # ones are aiohttp/BaseHTTPRequestHandler/etc) never sets a
  # `cache-control` header at all; `%Plug.Conn{}`'s own default is deleted
  # here so this route's response is a faithful stand-in for that, rather
  # than accidentally exercising "the add-on's own value happens to be
  # Plug's default" instead of "the add-on set nothing".
  get "/no-cache-header" do
    conn
    |> delete_resp_header("cache-control")
    |> send_resp(200, "ok")
  end

  # Catch-all: reflects the decoded path + verbatim query string, proving
  # a percent-encoded space round-trips and the query string passes through.
  match _ do
    send_json(conn, 200, %{path: conn.request_path, query: conn.query_string})
  end

  defp read_full_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, data, conn} -> {acc <> data, conn}
      {:more, data, conn} -> read_full_body(conn, acc <> data)
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end

defmodule Vagus.API.IngressProxyTest do
  @moduledoc """
  IW-P3-T3: hermetic end-to-end tests for `Vagus.API.Dispatcher` +
  `Vagus.API.IngressProxy` (`docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B2), driven over **real** listening Bandit servers on both ends — no
  `Plug.Test`, since the whole point under test is byte-for-byte streaming
  in both directions, which `Plug.Test`'s in-memory conn can't exercise.

  Three real processes per test: a fake ingress-enabled add-on
  (`FakeAddon`, above), the proxy stack itself (`Bandit` +
  `Vagus.API.Dispatcher`, exactly as `Vagus.API.Supervisor` wires it on a
  real device), and `Vagus.Ingress.Finch` (the proxy's outbound pool).
  `config :vagus, :ingress_target_fun` is pointed at the fake add-on's port
  for the duration of each test, standing in for a real docker
  inspect/`Vagus.Addon.State` lookup — `default_target/1` itself needs a
  real docker daemon and is out of scope for a hermetic suite.
  """
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Config, State}
  alias Vagus.API.IngressProxyTest.{FakeAddon, HitCounter}
  alias Vagus.API.Token

  @client_finch Vagus.API.IngressProxyTest.ClientFinch

  setup do
    start_supervised!(HitCounter)
    start_supervised!({Vagus.Ingress, []})
    start_supervised!({Finch, name: Vagus.Ingress.Finch})
    # The unbound sibling pool. `Vagus.API.Supervisor` starts both on a real
    # device, and the fake add-on here lives on 127.0.0.1 — i.e. exactly the
    # loopback case `finch_for/1` routes to this pool, so without it every
    # proxy test 500s on an unknown registry.
    start_supervised!({Finch, name: Vagus.Ingress.LocalFinch})
    start_supervised!({Finch, name: @client_finch})

    addon_pid =
      start_supervised!(
        {Bandit,
         plug: FakeAddon,
         port: 0,
         thousand_island_options: [num_acceptors: 1],
         http_options: [compress: false]},
        id: :fake_addon_bandit
      )

    proxy_pid =
      start_supervised!(
        {
          Bandit,
          # audit F5/D8: `compress: false` on BOTH Bandit instances is a
          # test-only isolation, not a production setting — `Vagus.API.
          # Supervisor` runs its real Bandit with default (`true`)
          # compression, and `Bandit.Compression.new/4`
          # (`deps/bandit/lib/bandit/compression.ex`) unconditionally
          # prepends `vary: accept-encoding` to *every* non-204 response it
          # sends, entirely independent of `conn.resp_headers` — so on a
          # real device `vary` still appears on every ingress-proxied
          # response (including plain refusals), regardless of this file's
          # `delete_resp_header("vary")` fix. That header-injection lives in
          # Bandit's own adapter, outside `Vagus.API.IngressProxy`'s reach,
          # and disabling it device-wide is a `Vagus.API.Supervisor` config
          # change, out of scope here. Left both Bandits' compression off so
          # this suite can actually observe *this module's own*
          # cache-control/vary handling without Bandit's independent
          # injection confounding the assertion.
          plug: Vagus.API.Dispatcher,
          port: 0,
          thousand_island_options: [num_acceptors: 1],
          http_options: [compress: false]
        },
        id: :proxy_bandit
      )

    addon_port = listening_port(addon_pid)
    proxy_port = listening_port(proxy_pid)

    slug = "ingress_test_#{System.unique_integer([:positive])}"
    {:ok, config} = Config.parse(required_config(slug))
    :ok = State.put(config, :started)
    {:ok, entry} = State.get(slug)

    Application.put_env(:vagus, :ingress_target_fun, fn
      ^slug -> {:ok, {"127.0.0.1", addon_port}}
      _other -> {:error, :unknown_slug}
    end)

    on_exit(fn ->
      Application.delete_env(:vagus, :ingress_target_fun)
      State.delete(slug)
    end)

    %{
      slug: slug,
      token: entry.ingress_token,
      proxy_base: "http://127.0.0.1:#{proxy_port}",
      proxy_port: proxy_port,
      addon_port: addon_port
    }
  end

  ## Helpers

  # `port: 0` binds an OS-assigned ephemeral port — fully collision-proof,
  # unlike guessing a "probably free" fixed/random port. `Bandit`'s
  # `start_link/1` returns the same pid `ThousandIsland.listener_info/1`
  # expects (Bandit is itself a thin `ThousandIsland` supervisor).
  defp listening_port(bandit_pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  defp required_config(slug) do
    %{
      "name" => "Ingress Test Addon",
      "version" => "1.0.0",
      "slug" => slug,
      "description" => "fake ingress add-on for IngressProxy tests",
      "arch" => ["amd64"],
      "ingress" => true,
      "ingress_port" => 8099
    }
  end

  defp req(method, url, headers \\ [], body \\ nil) do
    request = Finch.build(method, url, headers, body)
    {:ok, resp} = Finch.request(request, @client_finch, receive_timeout: 5_000)
    resp
  end

  defp cookie_header(session), do: {"cookie", "ingress_session=#{session}"}

  defp json(%Finch.Response{body: body}), do: Jason.decode!(body)

  # `FakeAddon`'s `/echo-headers` routes now echo the RAW `[[name, value],
  # ...]` list (see that module's moduledoc note), so tests need this rather
  # than plain `Map.new/1` — which is exactly the collapse-hazard the raw
  # shape exists to avoid. Groups by (already-lowercased, per
  # Plug/Bandit) name into a list of values, preserving duplicates, the same
  # shape `ws_bridge_test.exs`'s WS-leg header assertions already use.
  defp headers_by_name(%{"headers" => headers}) do
    Enum.reduce(headers, %{}, fn [k, v], acc ->
      Map.update(acc, k, [v], &(&1 ++ [v]))
    end)
  end

  defp resp_header(%Finch.Response{headers: headers}, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  # Every occurrence of `name`, in wire order — unlike `resp_header/2`
  # (first match only), this is what audit F2's duplicate-header assertions
  # need: `Finch.Response.headers` is a raw list that preserves duplicates,
  # so nothing upstream of this helper collapses them.
  defp resp_headers(%Finch.Response{headers: headers}, name) do
    headers
    |> Enum.filter(fn {k, _v} -> String.downcase(k) == name end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  # security-phase7.md W1's regression test needs a client that talks raw
  # HTTP/1.1 over ONE socket it fully controls for two sequential requests —
  # deliberately NOT `Finch`/`@client_finch`. Verified empirically (during
  # this fix's own development, by temporarily reintroducing the stale-conn
  # bug and re-running the Finch-based version of this test): a corrupted
  # keep-alive connection does NOT make a Finch-based test fail. Finch/Mint
  # silently detects the dead/wedged pooled connection and opens a fresh one
  # for the next request — exactly the client-side resilience a real browser
  # or Core's aiohttp pool would also have, which is precisely why this bug
  # matters (repeated stalls + connection churn) rather than being merely
  # cosmetic, but it also means a pooled HTTP client can never be the thing
  # that PROVES the bug is fixed. A raw socket has no such fallback: if the
  # connection is wedged, this hangs (caught by `timeout` below) instead of
  # quietly recovering.
  defp raw_http_request(method, path, host, headers, body) do
    header_lines =
      [{"Host", host} | headers]
      |> then(fn hs ->
        if body, do: hs ++ [{"Content-Length", byte_size(body)}], else: hs
      end)
      |> Enum.map_join(fn {k, v} -> "#{k}: #{v}\r\n" end)

    "#{method} #{path} HTTP/1.1\r\n" <> header_lines <> "\r\n" <> (body || "")
  end

  # Reads one full HTTP/1.1 response (status line + headers + body) off
  # `socket`, tolerating the header terminator and the start of the body
  # arriving in the same TCP segment. Handles BOTH framings `IngressProxy`
  # actually uses: `content-length` for `send_plain/3`'s plain-text
  # refusals (401/413/502/503 — never proxied, so a known length up front),
  # and `transfer-encoding: chunked` for every genuinely proxied response
  # (`do_handle_event/2` always calls `send_chunked/2`, since the upstream
  # body is streamed via `Finch.stream_while/5` with no length known ahead
  # of time) — `/echo-headers` in this suite is the latter, [VERIFIED]
  # empirically against this exact harness during this test's development.
  defp recv_http_response(socket, timeout) do
    {header_block, leftover} = read_until(socket, timeout, "", "\r\n\r\n")
    [status_line | header_lines] = String.split(header_block, "\r\n", trim: true)
    status = status_line |> String.split(" ", parts: 3) |> Enum.at(1) |> String.to_integer()

    headers =
      Enum.map(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end)

    body =
      case List.keyfind(headers, "transfer-encoding", 0) do
        {_, "chunked"} ->
          {body, _trailing_buffer} = read_chunked_body(socket, timeout, leftover, "")
          body

        _no_chunking ->
          {_, len} = List.keyfind(headers, "content-length", 0, {"content-length", "0"})
          {body, _rest} = read_exact(socket, timeout, leftover, String.to_integer(len))
          body
      end

    %{status: status, headers: headers, body: body}
  end

  # RFC 7230 §4.1 chunked-body decoder: `<hex-size>\r\n<data>\r\n`, repeated,
  # terminated by a zero-size chunk. `Plug.Conn.chunk/2` (what
  # `do_handle_event/2` calls per upstream `{:data, chunk}` event) never
  # emits trailers, so the zero-size chunk's own terminating blank line is
  # the last thing this needs to consume.
  defp read_chunked_body(socket, timeout, buffer, acc) do
    {size_line, buffer} = read_until(socket, timeout, buffer, "\r\n")
    size = size_line |> String.trim() |> String.to_integer(16)

    if size == 0 do
      {_trailer, buffer} = read_until(socket, timeout, buffer, "\r\n")
      {acc, buffer}
    else
      {chunk, buffer} = read_exact(socket, timeout, buffer, size)
      {_crlf, buffer} = read_until(socket, timeout, buffer, "\r\n")
      read_chunked_body(socket, timeout, buffer, acc <> chunk)
    end
  end

  # Reads (and consumes) up to and including the first `marker` in the
  # stream, returning the bytes before it and whatever arrived after it in
  # the same read as `rest` — the general form `recv_http_response/2`'s
  # header-block read and the chunk-framing reads above both need.
  defp read_until(socket, timeout, buffer, marker) do
    case String.split(buffer, marker, parts: 2) do
      [_marker_not_seen_yet] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, timeout)
        read_until(socket, timeout, buffer <> data, marker)

      [head, rest] ->
        {head, rest}
    end
  end

  # Reads exactly `n` bytes, returning them plus whatever's left in `buffer`
  # after them.
  defp read_exact(_socket, _timeout, buffer, n) when byte_size(buffer) >= n do
    <<data::binary-size(^n), rest::binary>> = buffer
    {data, rest}
  end

  defp read_exact(socket, timeout, buffer, n) do
    {:ok, data} = :gen_tcp.recv(socket, 0, timeout)
    read_exact(socket, timeout, buffer <> data, n)
  end

  ## 1. Happy path

  test "GET with a valid session cookie proxies through to the add-on", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [cookie_header(session)])

    assert resp.status == 200
    assert resp_header(resp, "x-accel-buffering") == "no"
    assert %{"headers" => _headers} = json(resp)
  end

  ## 2. Auth / token-resolution failures

  test "missing session cookie -> 401, and the add-on never sees the request", %{
    proxy_base: base,
    token: token
  } do
    resp = req(:get, "#{base}/ingress/#{token}/echo-headers")

    assert resp.status == 401
    assert resp.body == "Unauthorized"
    assert HitCounter.count() == 0
  end

  test "invalid session cookie -> 401, and the add-on never sees the request", %{
    proxy_base: base,
    token: token
  } do
    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [cookie_header("not-a-real-session")])

    assert resp.status == 401
    assert HitCounter.count() == 0
  end

  test "unknown ingress token -> 503", %{proxy_base: base} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/no-such-token-1234567890/echo-headers", [
        cookie_header(session)
      ])

    assert resp.status == 503
    assert HitCounter.count() == 0
  end

  ## 3. Streamed request body (the Plug.Parsers regression case)

  test "a >64KB POST body reaches the add-on byte-for-byte", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()
    payload = :crypto.strong_rand_bytes(200_000)
    expected_sha = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

    resp =
      req(:post, "#{base}/ingress/#{token}/echo-body", [cookie_header(session)], payload)

    assert resp.status == 200
    assert %{"size" => 200_000, "sha256" => ^expected_sha} = json(resp)
  end

  ## 4. Header handling

  # The fake add-on is on 127.0.0.1, so `finch_for/1` must route it to the
  # UNBOUND pool. Every other test in this file starts both pools, and on
  # `:host` they are configured identically (`source_bind_opts/0` is `[]` with
  # no `:ingress_source_ip`) — so inverting `finch_for/1` would change nothing
  # observable and the whole suite would still pass. That is exactly what
  # review round 2 found.
  #
  # Stopping the BOUND pool makes the choice observable: if the proxy picks it
  # for a loopback target, Finch raises on the unknown registry and the request
  # 500s instead of 200ing. This is the only test that pins the routing rather
  # than the rule (`Vagus.NetworkTest` covers `source_bind_opts/1` itself).
  test "a loopback target is dialled through the unbound pool, not the anchor-bound one",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    :ok = stop_supervised(Vagus.Ingress.Finch)

    resp = req(:get, "#{base}/ingress/#{token}/", [cookie_header(session)])

    assert resp.status == 200,
           "loopback target was not routed to Vagus.Ingress.LocalFinch " <>
             "(got #{resp.status} — finch_for/1 picked the bound pool)"
  end

  test "strips supervisor/hop-by-hop headers, appends x-forwarded-for, passes custom headers through",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [
        cookie_header(session),
        {"x-supervisor-token", "should-never-arrive"},
        {"x-hassio-key", "should-never-arrive"},
        {"connection", "keep-alive"},
        {"x-ingress-path", "/api/hassio_ingress/#{token}"}
      ])

    assert resp.status == 200
    by_name = headers_by_name(json(resp))

    refute Map.has_key?(by_name, "x-supervisor-token")
    # testing-phase7.md Warning: previously only asserted on the WS leg.
    # `strip_request_headers/1` is the one function both legs share, but the
    # requirement is "identical on both legs", not "shares code with the
    # other leg we already checked" — worth pinning here too.
    refute Map.has_key?(by_name, "x-hassio-key")
    refute Map.has_key?(by_name, "connection")
    assert by_name["x-ingress-path"] == ["/api/hassio_ingress/#{token}"]
    assert [xff] = by_name["x-forwarded-for"]
    assert xff =~ "127.0.0.1"

    # [VERIFY] resolved empirically (contract §B2.2 step 4, `Host` not in
    # either strip list): Mint's HTTP/1 request builder only fills in a
    # default `Host` when one isn't already present
    # (`Headers.put_new("Host", ...)`, `deps/mint/lib/mint/http1.ex:1170`)
    # — a caller-supplied `Host` (here, the original inbound one) passes
    # through to the add-on completely untouched, exactly as the contract
    # describes, rather than being rejected or overridden with the
    # upstream connection's own authority.
    #
    # testing-phase7.md Warning: this is the HTTP-leg counterpart of the WS
    # leg's `length(by_name["host"]) == 1` assertion
    # (`ws_bridge_test.exs`) — untestable before this file's `/echo-headers`
    # route stopped collapsing duplicates via `Map.new/1`.
    assert by_name["host"] != nil
    assert length(by_name["host"]) == 1
  end

  test "an inbound x-forwarded-for is appended to, not overwritten (audit B1/B2.2)", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [
        cookie_header(session),
        {"x-forwarded-for", "203.0.113.9"}
      ])

    assert resp.status == 200
    by_name = headers_by_name(json(resp))

    # testing-phase7.md Warning: every other header test in this file sends
    # no inbound XFF, so `append_forwarded_for/2`'s `existing <> ", " <>
    # peer` branch (`ingress_proxy.ex:424`) — the actual audited
    # append-not-overwrite behavior (audit B1) — had zero coverage. Order
    # matters: existing hop(s) first, this hop's own peer view last.
    assert by_name["x-forwarded-for"] == ["203.0.113.9, 127.0.0.1"]
  end

  test "a client-sent content-length is stripped even with no body to buffer (GET)", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    # [VERIFY]: this can't be the "declares 99999, sends 5 bytes" shape
    # named in testing-phase7.md's Warning literally — verified empirically
    # (a throwaway Finch/Bandit probe) that a mismatched Content-Length vs.
    # actual wire bytes just hangs the CLIENT leg of this harness (Bandit
    # blocks reading the declared-but-never-sent remainder), which would
    # test this harness's own HTTP/1.1 framing, not `IngressProxy`. `0` is
    # framing-safe (matches the real empty body) while still being a
    # present, well-formed `content-length` header on a GET — exactly the
    # "GET-with-no-body" gap the Warning names — so a regression that
    # stopped stripping `@request_strip_extra` unconditionally (regardless
    # of `has_body?/1`'s branch) would still be caught here.
    resp =
      req(:get, "#{base}/ingress/#{token}/echo-headers", [
        cookie_header(session),
        {"content-length", "0"}
      ])

    assert resp.status == 200
    by_name = headers_by_name(json(resp))

    refute Map.has_key?(by_name, "content-length")
  end

  test "a client-sent content-encoding is stripped, not forwarded to the add-on", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    # Unlike `content-length`, `content-encoding` plays no role in HTTP/1.1
    # framing, so this one CAN be the literal shape testing-phase7.md names:
    # a real 5-byte, non-gzipped body with a lying `content-encoding: gzip`.
    resp =
      req(
        :post,
        "#{base}/ingress/#{token}/echo-headers",
        [cookie_header(session), {"content-encoding", "gzip"}],
        "hello"
      )

    assert resp.status == 200
    by_name = headers_by_name(json(resp))

    refute Map.has_key?(by_name, "content-encoding")
  end

  ## 5. Sliding renewal

  test "a proxied request slides the session's expiry rather than consuming it", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/echo-headers", [cookie_header(session)])
    assert resp.status == 200

    assert Vagus.Ingress.validate_session(session) == :ok
  end

  ## 6. Response streaming

  test "a chunked add-on response streams through to the client whole", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/stream3", [cookie_header(session)])

    assert resp.status == 200
    assert resp.body == "chunk1-chunk2-chunk3"
  end

  test "a 204 add-on response passes through with no body and no chunked-framing error", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/empty204", [cookie_header(session)])

    assert resp.status == 204
    assert resp.body == ""
  end

  ## 7. Path encoding + query string

  test "a percent-encoded space in the path reaches the add-on intact, query string passes through",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/a%20b/c?x=y&z=1", [cookie_header(session)])

    assert resp.status == 200
    # `conn.path_info`/`request_path` are never percent-decoded anywhere in
    # this pipeline (see `Vagus.API.IngressProxy.build_url/4`'s doc comment)
    # — "intact" means the `%20` survives verbatim end to end, not that it
    # becomes a literal space.
    assert %{"path" => "/a%20b/c", "query" => "x=y&z=1"} = json(resp)
  end

  ## 9. Multi-valued response headers (audit F2/B2)

  test "multiple same-named response headers (Set-Cookie, Link) are preserved, not collapsed",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/multi-headers", [cookie_header(session)])

    assert resp.status == 200
    assert resp_headers(resp, "set-cookie") == ["a=1", "b=2"]
    assert resp_headers(resp, "link") == ["</one>; rel=preload", "</two>; rel=preload"]
  end

  test "an add-on cannot overwrite the shared ingress_session cookie (security-phase7.md W3)",
       %{proxy_base: base, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/#{token}/session-fixation-attempt", [cookie_header(session)])

    assert resp.status == 200
    # F2 (preceding fix) means BOTH of the add-on's `Set-Cookie` headers
    # would otherwise ride through untouched; this proves the add-on's own
    # `sid` cookie still does (F2 not regressed) while its attempt to hand
    # the browser an `ingress_session` value of its own choosing does not
    # (the W3 divergence — see `strip_response_headers/1`'s
    # `ingress_session_cookie?/2`).
    assert resp_headers(resp, "set-cookie") == ["sid=ok"]
  end

  ## 10. Request body streaming vs buffering (audit F4/B7)

  test "a POST body is buffered by default: the add-on sees content-length, never chunked", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:post, "#{base}/ingress/#{token}/echo-headers", [cookie_header(session)], "hello")

    assert resp.status == 200
    by_name = headers_by_name(json(resp))

    assert by_name["content-length"] == ["5"]
    refute Map.has_key?(by_name, "transfer-encoding")
  end

  test "a POST to an add-on with ingress_stream: true is streamed (chunked), not buffered", %{
    proxy_base: base,
    token: token,
    slug: slug
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    Application.put_env(:vagus, :ingress_stream_fun, fn
      ^slug -> true
      _other -> false
    end)

    on_exit(fn -> Application.delete_env(:vagus, :ingress_stream_fun) end)

    resp =
      req(:post, "#{base}/ingress/#{token}/echo-headers", [cookie_header(session)], "hello")

    assert resp.status == 200
    by_name = headers_by_name(json(resp))

    assert by_name["transfer-encoding"] == ["chunked"]
    refute Map.has_key?(by_name, "content-length")
  end

  test "a request body over the configured cap is rejected with 413, add-on never dialled", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    Application.put_env(:vagus, :ingress_request_body_cap, 10)
    on_exit(fn -> Application.delete_env(:vagus, :ingress_request_body_cap) end)

    resp =
      req(
        :post,
        "#{base}/ingress/#{token}/echo-body",
        [cookie_header(session)],
        String.duplicate("x", 1_000)
      )

    assert resp.status == 413
    assert resp.body == "Request Entity Too Large"
    assert HitCounter.count() == 0
  end

  test "security-phase7.md W1: the 413 leaves the connection genuinely reusable, not just answered",
       %{proxy_port: proxy_port, token: token} do
    {:ok, session} = Vagus.Ingress.create_session()

    Application.put_env(:vagus, :ingress_request_body_cap, 10)
    on_exit(fn -> Application.delete_env(:vagus, :ingress_request_body_cap) end)

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", proxy_port, [:binary, active: false, packet: :raw], 2_000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    # Request 1: an oversized POST over a socket this test owns end to end
    # (not `@client_finch` — see `raw_http_request/5`'s doc comment for why
    # a pooled client can't prove this). Before the fix, `read_buffered/4`'s
    # overflow branch discarded the updated conn and the 413 answered
    # through `proxy_http/5`'s ORIGINAL, pre-read one, so Bandit's adapter
    # still believed 0 bytes of this request's body had been consumed.
    #
    # [VERIFIED] the body has to be bigger than the 64_000-byte chunk size
    # `read_body/2` is called with (F4's fix, same file) for the bug to be
    # OBSERVABLE at all — confirmed empirically while developing this test
    # by temporarily reintroducing the stale-conn bug: at 1_000 bytes the
    # entire request (headers + body) arrives in Bandit's single initial
    # socket read, so even the STALE conn's own frozen buffer already
    # contains the full body and the phantom "drain" is instant — no
    # observable difference between broken and fixed. At 200_000 bytes, the
    # correctly-fixed code path only ever reads the FIRST 64_000-byte chunk
    # off the wire before erroring past the 10-byte cap, leaving ~136_000
    # real, genuinely-unread bytes sitting on the actual socket; the stale
    # conn doesn't know those 64_000 bytes were ever consumed, so
    # `ensure_completed/1` drains everything actually available and then
    # blocks waiting for the remaining ~64_000 bytes that will never come
    # (the client already sent its whole body) — a real, timing-independent
    # hang, not a race.
    req1 =
      raw_http_request(
        "POST",
        "/ingress/#{token}/echo-body",
        "127.0.0.1:#{proxy_port}",
        [{"Cookie", "ingress_session=#{session}"}],
        String.duplicate("x", 200_000)
      )

    :ok = :gen_tcp.send(socket, req1)
    resp1 = recv_http_response(socket, 2_000)

    assert resp1.status == 413
    assert resp1.body == "Request Entity Too Large"

    # Request 2, over the SAME socket, sent immediately after. With the bug
    # (see above), this socket is server-side wedged inside
    # `ensure_completed/1`'s phantom drain by the time these bytes arrive:
    # they get consumed as leftover body instead of being parsed as a new
    # request, and no second response ever comes back —
    # `recv_http_response/2` times out waiting for a status line. With the
    # fix, the connection is clean and this is answered normally and
    # promptly.
    req2 =
      raw_http_request(
        "GET",
        "/ingress/#{token}/echo-headers",
        "127.0.0.1:#{proxy_port}",
        [{"Cookie", "ingress_session=#{session}"}],
        nil
      )

    :ok = :gen_tcp.send(socket, req2)
    resp2 = recv_http_response(socket, 2_000)

    assert resp2.status == 200
    assert %{"headers" => _headers} = Jason.decode!(resp2.body)
  end

  ## 11. cache-control/vary never leak from Plug's defaults (audit F5/D8)

  test "a proxied response never carries Plug's default cache-control/vary", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/no-cache-header", [cookie_header(session)])

    assert resp.status == 200
    assert resp_header(resp, "cache-control") == nil
    assert resp_header(resp, "vary") == nil
  end

  test "an add-on's own cache-control header passes through untouched", %{
    proxy_base: base,
    token: token
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp = req(:get, "#{base}/ingress/#{token}/own-cache-control", [cookie_header(session)])

    assert resp.status == 200
    assert resp_header(resp, "cache-control") == "public, max-age=3600"
  end

  test "a plain-text refusal (bad token -> 503) carries neither cache-control nor vary", %{
    proxy_base: base
  } do
    {:ok, session} = Vagus.Ingress.create_session()

    resp =
      req(:get, "#{base}/ingress/no-such-token-1234567890/echo-headers", [
        cookie_header(session)
      ])

    assert resp.status == 503
    assert resp_header(resp, "cache-control") == nil
    assert resp_header(resp, "vary") == nil
  end

  ## 8. /ingress/panels and /ingress/session still hit the router

  test "/ingress/panels with a supervisor token hits the router (200 envelope), not the proxy", %{
    proxy_base: base
  } do
    resp =
      req(:get, "#{base}/ingress/panels", [{"authorization", "Bearer #{Token.get()}"}])

    assert resp.status == 200
    assert %{"data" => %{"panels" => %{}}} = json(resp)
  end

  test "/ingress/panels without auth is rejected by the router, not proxied (never a 503)", %{
    proxy_base: base
  } do
    resp = req(:get, "#{base}/ingress/panels")

    assert resp.status == 401
    # The router's `Vagus.API.Envelope`-wrapped rejection, not the proxy's
    # plain-text one — proves this request never reached `IngressProxy`.
    assert %{"message" => _} = json(resp)
  end

  test "/ingress/session with a supervisor token hits the router, not the proxy", %{
    proxy_base: base
  } do
    resp =
      req(:post, "#{base}/ingress/session", [
        {"authorization", "Bearer #{Token.get()}"},
        {"content-type", "application/json"}
      ])

    assert resp.status == 200
    assert %{"data" => %{"session" => session}} = json(resp)
    assert session =~ ~r/\A[0-9a-f]{128}\z/
  end

  # `default_target/1`'s bridge branch needs a real docker daemon (out of
  # scope here), but the `host_network: true` branch short-circuits before
  # the docker inspect — regression test for the P5-T1 on-device 502
  # (ESPHome is host-networked; its ingress port is bound on the emulator's
  # own loopback, not a `hassio` bridge IP).
  test "default_target resolves a host_network add-on to 127.0.0.1" do
    slug = "ingress_hostnet_#{System.unique_integer([:positive])}"

    {:ok, config} =
      required_config(slug)
      |> Map.put("host_network", true)
      |> Vagus.Addon.Config.parse()

    :ok = State.put(config, :started)
    on_exit(fn -> State.delete(slug) end)

    assert {:ok, {"127.0.0.1", 8099}} = Vagus.API.IngressProxy.default_target(slug)
  end
end
