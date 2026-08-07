defmodule Vagus.API.CoreProxyTest.HitCounter do
  @moduledoc "Counts requests the fake Core Bandit actually received — proves a refused request never reaches it."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def bump, do: Agent.update(__MODULE__, &(&1 + 1))
  def count, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.CoreProxyTest.Recorder do
  @moduledoc "Captures the last request the fake Core Bandit received (method/path/query/headers/body)."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def record(request), do: Agent.update(__MODULE__, fn _ -> request end)
  def last, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.CoreProxyTest.Script do
  @moduledoc "The scripted {status, headers, body} the fake Core Bandit answers every request with."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> {200, [], ""} end, name: __MODULE__)

  def set(status, headers, body),
    do: Agent.update(__MODULE__, fn _ -> {status, headers, body} end)

  def get, do: Agent.get(__MODULE__, & &1)
end

defmodule Vagus.API.CoreProxyTest.SSEGate do
  @moduledoc """
  Lets the test process release the fake Core's SSE handler mid-stream —
  the incremental-delivery test's synchronization primitive. The handler
  itself runs in a per-connection Bandit process the test has no `pid` for
  until that process registers itself here first.
  """
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def register(pid), do: Agent.update(__MODULE__, fn _ -> pid end)

  def release do
    case Agent.get(__MODULE__, & &1) do
      nil -> :error
      pid -> send(pid, :release)
    end

    :ok
  end
end

defmodule Vagus.API.CoreProxyTest.FakeCore do
  @moduledoc """
  Stands in for Home Assistant Core's REST API: no `Plug.Parsers` (this
  proxy leg never uses one either — see `Vagus.API.CoreProxy`'s moduledoc),
  just enough to record what it received and answer with whatever
  `Vagus.API.CoreProxyTest.Script` was told to reply, plus a few dedicated
  SSE routes (below) the phase-2 streaming tests need real chunked framing
  from, which `Script`'s single-shot `{status, headers, body}` shape can't
  express.
  """
  use Plug.Router

  alias Vagus.API.CoreProxyTest.{HitCounter, Recorder, Script, SSEGate}

  plug(:match)
  plug(:dispatch)

  # Sends one chunk, registers itself with `SSEGate` so the test can release
  # it, blocks (the `after` is a safety net so a bug elsewhere can't hang the
  # suite forever), then sends a second chunk — the real-incrementality
  # proof's fake upstream half.
  get "/api/sse-incremental" do
    SSEGate.register(self())

    conn =
      conn
      |> delete_resp_header("cache-control")
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("mcp-session-id", "sess-abc")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: one\n\n")

    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end

    {:ok, conn} = chunk(conn, "data: two\n\n")
    conn
  end

  # `text/event-stream; charset=utf-8` — proves the SSE decision compares
  # media type only, ignoring the `;` parameter.
  get "/api/sse-charset" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "data: hello\n\n")
    conn
  end

  # Sends one chunk then dies mid-response (headers already committed, so
  # neither this Plug.Router nor Bandit can answer a clean 500) — the
  # mid-stream-death regression's fake upstream half.
  get "/api/sse-crash" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)

    {:ok, _conn} = chunk(conn, "data: one\n\n")
    raise "simulated Core crash mid-SSE-stream"
  end

  match _ do
    HitCounter.bump()
    {body, conn} = read_full_body(conn)

    Recorder.record(%{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      headers: conn.req_headers,
      body: body
    })

    {status, headers, resp_body} = Script.get()

    conn =
      conn
      # A real Core is not a Plug server and never sets this default — see
      # `Vagus.API.IngressProxyTest.FakeAddon`'s `/no-cache-header` route for
      # the same reasoning. Deleted unconditionally so a test that scripts NO
      # `cache-control` genuinely proves `Vagus.API.CoreProxy` added none of
      # its own, rather than accidentally observing Plug's own default.
      |> delete_resp_header("cache-control")
      |> then(fn conn ->
        Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      end)

    send_resp(conn, status, resp_body)
  end

  defp read_full_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, data, conn} -> {acc <> data, conn}
      {:more, data, conn} -> read_full_body(conn, acc <> data)
    end
  end
end

defmodule Vagus.API.CoreProxyTest do
  @moduledoc """
  REST-leg (phase 1) and SSE/stream-leg (phase 2) tests for
  `Vagus.API.CoreProxy` (`.claude/plans/vagus-core-api-proxy/plan.md`),
  driven through `Vagus.API.Dispatcher.call/2` — never `CoreProxy` directly
  — because the plan's own risk section is explicit that the blacklist test
  must run against the real dispatcher path, not the predicate alone;
  running everything through `Dispatcher` also covers the routing rule
  itself (`["core","api"|rest]` / `["homeassistant","api"|rest]`).

  Most phase-1 cases use `Plug.Test` conns into `Dispatcher` — the caller
  side of this proxy has no streaming/chunking behaviour of its own to
  exercise for a buffered response (unlike `Vagus.API.IngressProxy`, this
  leg reads the *whole* caller request before doing anything auth-relevant),
  so an in-memory conn is faithful. `Vagus.API.CoreProxy`'s own outbound call
  to the fake Core below is always real `Finch`/`Bandit`, regardless of how
  the inbound conn was built — the proxy has no idea whether its caller
  arrived via a socket or `Plug.Test`. The >64KB streamed-body test and every
  phase-2 SSE/stream test need a real Bandit + Finch client in front of
  `Dispatcher` too, since `Plug.Test`'s in-memory conn can't exercise
  chunked-transfer framing on either side, and the incremental-delivery test
  specifically needs a genuine socket so the client can observe partial data
  while the fake Core is still mid-response (same precedent as
  `Vagus.API.IngressProxyTest`'s equivalent tests).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.Registry
  alias Vagus.API.CoreProxyTest.{FakeCore, HitCounter, Recorder, Script, SSEGate}
  alias Vagus.API.{Dispatcher, Token}

  @opts Dispatcher.init([])
  @client_finch Vagus.API.CoreProxyTest.ClientFinch

  setup do
    start_supervised!(HitCounter)
    start_supervised!(Recorder)
    start_supervised!(Script)
    start_supervised!(SSEGate)
    start_supervised!({Finch, name: Vagus.API.CoreProxy.Finch})

    fake_core_pid =
      start_supervised!(
        {Bandit,
         plug: FakeCore,
         port: 0,
         thousand_island_options: [num_acceptors: 1],
         http_options: [compress: false]},
        id: :fake_core_bandit
      )

    fake_core_port = listening_port(fake_core_pid)

    prev_base_url = Application.get_env(:vagus, :core_base_url)
    Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{fake_core_port}")
    Application.put_env(:vagus, :core_api_state_fun, fn -> true end)

    Application.put_env(:vagus, :core_proxy_access_token_fun, fn -> {:ok, "core-access-token"} end)

    on_exit(fn ->
      # `is_nil/1`, not a truthiness check — same convention
      # `dispatcher_source_guard_test.exs` uses: an explicitly-`nil` prior
      # value is impossible here (this key has no compile-time config), but
      # matching the convention keeps this restore correct if that ever
      # changes.
      if is_nil(prev_base_url),
        do: Application.delete_env(:vagus, :core_base_url),
        else: Application.put_env(:vagus, :core_base_url, prev_base_url)

      Application.delete_env(:vagus, :core_api_state_fun)
      Application.delete_env(:vagus, :core_proxy_access_token_fun)
    end)

    Script.set(200, [{"content-type", "application/json"}], Jason.encode!(%{"ok" => true}))

    %{fake_core_port: fake_core_port}
  end

  ## Helpers

  defp listening_port(bandit_pid) do
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  defp call(method, path, headers \\ []) do
    conn = Plug.Test.conn(method, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    Dispatcher.call(conn, @opts)
  end

  # Case-sensitive equality is enough — Mint's header names arrive already
  # lowercased (same property `Vagus.API.CoreProxy.header_value/2` relies
  # on), and this is used against both `Finch.Response.headers` and the raw
  # list `Finch.stream/5`'s `{:headers, headers}` event hands the caller.
  defp find_header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)
  end

  defp finch_req(method, url, headers \\ [], body \\ nil) do
    Finch.build(method, url, headers, body)
    |> Finch.request(@client_finch, receive_timeout: 5_000)
  end

  defp addon_token(slug, grants \\ %{}) do
    token = "core-proxy-tok-#{System.unique_integer([:positive])}"

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

  defp bearer(token), do: {"authorization", "Bearer #{token}"}

  ## 1. Auth (fact 2 — the inverted model)

  describe "auth" do
    test "no token -> 401, fake Core never hit" do
      conn = call(:get, "/core/api/states")

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
      assert HitCounter.count() == 0
    end

    test "the supervisor token -> 401 (not special-cased — it simply doesn't resolve in the registry)" do
      conn = call(:get, "/core/api/states", [bearer(Token.get())])

      assert conn.status == 401
      assert HitCounter.count() == 0
    end

    test "a registered add-on token with homeassistant_api: false -> 401" do
      token = addon_token("cp_auth_no_flag")
      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 401
      assert HitCounter.count() == 0
    end

    test "a registered add-on token with homeassistant_api: true -> 200, fake Core hit" do
      token = addon_token("cp_auth_flag", %{homeassistant_api: true})
      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 200
      assert HitCounter.count() == 1
    end

    test "the same success via X-Ha-Access instead of Authorization" do
      token = addon_token("cp_auth_xha", %{homeassistant_api: true})
      conn = call(:get, "/core/api/states", [{"x-ha-access", token}])

      assert conn.status == 200
      assert HitCounter.count() == 1
    end

    # `extract_token/1`'s documented quirk (`bearer.split(' ')[-1]`, not a
    # strict `"Bearer " <> token` match): the LAST space-separated part of
    # the header is what resolves, regardless of extra spaces or stray
    # tokens before it.
    test "a malformed Authorization header (extra spaces, an extra token) still resolves via the LAST space-separated part -> 200" do
      token = addon_token("cp_auth_malformed_ok", %{homeassistant_api: true})
      conn = call(:get, "/core/api/states", [{"authorization", "Bearer  x  #{token}"}])

      assert conn.status == 200
      assert HitCounter.count() == 1
    end

    # Same quirk, the other side: a genuinely valid token earlier in the
    # header does NOT save it — only the LAST part is ever consulted.
    test "a malformed Authorization header whose LAST space-separated part is garbage -> 401" do
      token = addon_token("cp_auth_malformed_bad", %{homeassistant_api: true})

      conn =
        call(:get, "/core/api/states", [{"authorization", "Bearer #{token} not-a-real-token"}])

      assert conn.status == 401
      assert HitCounter.count() == 0
    end
  end

  ## 2. Blacklist (checked in the Dispatcher, before this leg is ever reached)

  describe "blacklist" do
    test "GET /core/api/hassio/app -> 403 blacklist envelope, fake Core never hit" do
      token = addon_token("cp_blacklist_core", %{homeassistant_api: true})
      conn = call(:get, "/core/api/hassio/app", [bearer(token)])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"result" => "error", "message" => "unauthorized"}
      assert HitCounter.count() == 0
    end

    test "GET /homeassistant/api/hassio/app -> 403 blacklist envelope, fake Core never hit" do
      token = addon_token("cp_blacklist_ha", %{homeassistant_api: true})
      conn = call(:get, "/homeassistant/api/hassio/app", [bearer(token)])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"result" => "error", "message" => "unauthorized"}
      assert HitCounter.count() == 0
    end

    # security review Blocker: `%68assio` percent-decodes to `hassio`, which
    # is exactly the segment the blacklist exists to deny. A literal-segment
    # match alone lets this straight through to Core with the Supervisor's
    # own credential; `Dispatcher.core_proxy_blacklisted?/1`'s decoded check
    # is what catches it.
    test "GET /core/api/%68assio/config -> 403 blacklist envelope, fake Core never hit" do
      token = addon_token("cp_blacklist_encoded", %{homeassistant_api: true})
      conn = call(:get, "/core/api/%68assio/config", [bearer(token)])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"result" => "error", "message" => "unauthorized"}
      assert HitCounter.count() == 0
    end

    # `%2f` is an encoded slash — a per-segment decode would leave this as
    # the single segment `"hassio/config"`, which does not match
    # `["core","api","hassio",:*]`. Decoding the whole path and re-splitting
    # on "/" is what catches it.
    test "GET /core/api/hassio%2fconfig -> 403 blacklist envelope, fake Core never hit" do
      token = addon_token("cp_blacklist_encoded_slash", %{homeassistant_api: true})
      conn = call(:get, "/core/api/hassio%2fconfig", [bearer(token)])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"result" => "error", "message" => "unauthorized"}
      assert HitCounter.count() == 0
    end

    test "GET /homeassistant/api/%68assio/x -> 403 blacklist envelope, fake Core never hit" do
      token = addon_token("cp_blacklist_encoded_ha", %{homeassistant_api: true})
      conn = call(:get, "/homeassistant/api/%68assio/x", [bearer(token)])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"result" => "error", "message" => "unauthorized"}
      assert HitCounter.count() == 0
    end

    # Positive control: the decode gate must deny only the blacklist, not
    # every encoded path. `%61` decodes to `a`, so the DECODED form is
    # `/api/states` — nowhere near `hassio` — and must still proxy through
    # normally. `build_url/2` forwards `rest` verbatim (never re-encoded),
    # so Core sees the request at the still-encoded path exactly as sent —
    # the decode only ever feeds the blacklist comparison, never the
    # forwarded URL.
    test "GET /core/api/st%61tes (a non-hassio encoded path) still proxies through, fake Core hit at the raw (still-encoded) path" do
      token = addon_token("cp_blacklist_encoded_control", %{homeassistant_api: true})
      conn = call(:get, "/core/api/st%61tes", [bearer(token)])

      assert conn.status == 200
      assert HitCounter.count() == 1
      assert Recorder.last().path == "/api/st%61tes"
    end

    # `URI.decode/1` is lenient — a bare, dangling `%` with no following hex
    # digits is left as-is rather than raising — so the blacklist check
    # itself never crashes on this path. It also isn't a blacklist match
    # (nowhere near `hassio`), so the dispatcher hands it to `CoreProxy`,
    # which forwards the still-raw `%config` segment verbatim; Mint's own
    # HTTP/1 client then refuses to send a request line containing an
    # invalid percent-escape (`{:invalid_request_target, ...}`), which
    # `CoreProxy.finish/1`'s `{:error, _, acc}` clause turns into an honest
    # 502 — a legitimate answer, not a crash, and the fake Core is never
    # even reached.
    test "GET /core/api/%config (a bare, invalid percent-escape) doesn't crash the dispatcher" do
      token = addon_token("cp_blacklist_bare_percent", %{homeassistant_api: true})
      conn = call(:get, "/core/api/%config", [bearer(token)])

      assert conn.status == 502
      assert HitCounter.count() == 0
    end
  end

  ## 3. Request header allowlist (fact 4)

  describe "request header allowlist" do
    test "only the allowlisted headers + content-type reach Core; the caller's own credential does not" do
      token = addon_token("cp_headers", %{homeassistant_api: true})

      conn =
        call(:get, "/core/api/states", [
          {"accept", "application/json"},
          {"last-event-id", "42"},
          {"mcp-session-id", "sess-1"},
          {"x-speech-content", "hello"},
          {"mcp-protocol-version", "1.0"},
          {"content-type", "application/json"},
          {"x-supervisor-token", "should-never-arrive"},
          {"cookie", "should-never-arrive"},
          {"x-forwarded-for", "should-never-arrive"},
          bearer(token)
        ])

      assert conn.status == 200
      by_name = Map.new(Recorder.last().headers)

      assert by_name["accept"] == "application/json"
      assert by_name["last-event-id"] == "42"
      assert by_name["mcp-session-id"] == "sess-1"
      assert by_name["x-speech-content"] == "hello"
      assert by_name["mcp-protocol-version"] == "1.0"
      assert by_name["content-type"] == "application/json"
      # This proxy's own credential — not the caller's — is what Core sees.
      assert by_name["authorization"] == "Bearer core-access-token"

      refute Map.has_key?(by_name, "x-supervisor-token")
      refute Map.has_key?(by_name, "cookie")
      refute Map.has_key?(by_name, "x-forwarded-for")
    end
  end

  ## 3b. Socket transport + implicit auth (A2/A3)

  describe "over the Supervisor↔Core unix socket" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "vagus_core_proxy_#{System.unique_integer([:positive])}.sock"
        )

      start_supervised!(
        {Bandit,
         plug: FakeCore,
         port: 0,
         thousand_island_options: [
           num_acceptors: 1,
           transport_options: [ip: {:local, path}]
         ],
         http_options: [compress: false]},
        id: :fake_core_socket_bandit
      )

      # The TCP fake Core stays up on `:core_base_url`; picking the socket
      # over it is the whole point, and `HitCounter`/`Recorder` are shared,
      # so a request landing on the wrong listener would still be visible.
      Application.put_env(:vagus, :core_socket_path, path)

      on_exit(fn ->
        Application.put_env(:vagus, :core_socket_path, nil)
        File.rm(path)
      end)

      %{socket: path}
    end

    test "the request rides the socket and carries NO authorization header" do
      token = addon_token("cp_socket", %{homeassistant_api: true})

      # A token function that would blow up if it were consulted: on the
      # socket path no credential is resolved at all.
      Application.put_env(:vagus, :core_proxy_access_token_fun, fn ->
        raise "access token resolved on the socket path"
      end)

      conn = call(:get, "/core/api/states?filter=a%20b", [bearer(token)])

      assert conn.status == 200
      assert HitCounter.count() == 1

      last = Recorder.last()
      assert last.path == "/api/states"
      assert last.query == "filter=a%20b"
      refute Map.has_key?(Map.new(last.headers), "authorization")
    end

    test "a missing refresh token no longer 502s a socket-borne request" do
      token = addon_token("cp_socket_no_token", %{homeassistant_api: true})

      Application.put_env(:vagus, :core_proxy_access_token_fun, fn ->
        {:error, :no_refresh_token}
      end)

      assert call(:get, "/core/api/states", [bearer(token)]).status == 200
    end

    test "auth is still the add-on's own — an unflagged caller never reaches the socket" do
      token = addon_token("cp_socket_unflagged")

      assert call(:get, "/core/api/states", [bearer(token)]).status == 401
      assert HitCounter.count() == 0
    end

    test "a socket that disappears falls straight back to the TCP base URL", %{socket: path} do
      token = addon_token("cp_socket_gone", %{homeassistant_api: true})
      File.rm!(path)

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 200
      # TCP again ⇒ the bearer credential is back.
      assert Map.new(Recorder.last().headers)["authorization"] == "Bearer core-access-token"
    end
  end

  ## 4. Query forwarding

  describe "query forwarding" do
    test "the raw query string reaches Core verbatim" do
      token = addon_token("cp_query", %{homeassistant_api: true})
      conn = call(:get, "/core/api/states?filter=a%20b", [bearer(token)])

      assert conn.status == 200
      assert Recorder.last().query == "filter=a%20b"
    end
  end

  ## 5. Request body streamed, not parsed (>64KB, real Bandit + Finch)

  describe "request body streamed not parsed" do
    setup do
      proxy_pid =
        start_supervised!(
          {Bandit,
           plug: Dispatcher,
           port: 0,
           thousand_island_options: [num_acceptors: 1],
           http_options: [compress: false]},
          id: :proxy_bandit
        )

      start_supervised!({Finch, name: @client_finch})

      %{proxy_base: "http://127.0.0.1:#{listening_port(proxy_pid)}"}
    end

    test "a >64KB POST body reaches Core byte-for-byte, never truncated by Plug.Parsers", %{
      proxy_base: base
    } do
      token = addon_token("cp_stream", %{homeassistant_api: true})
      payload = :crypto.strong_rand_bytes(100_000)

      request =
        Finch.build(:post, "#{base}/core/api/states", [bearer(token)], payload)

      {:ok, resp} = Finch.request(request, @client_finch, receive_timeout: 5_000)

      assert resp.status == 200
      assert Recorder.last().body == payload
      assert Recorder.last().method == "POST"
    end

    # `has_body?/1`'s OTHER branch: absent a `content-length` header, a
    # `transfer-encoding: chunked` header alone is what marks a request as
    # having a body. `{:stream, ...}` with neither header set explicitly
    # makes Mint pick implicit chunked transfer-encoding itself (`Mint.
    # HTTP1`'s own doc: "if you don't set transfer-encoding to chunked and
    # don't provide a content-length header, Mint will do implicit chunked
    # transfer encoding") — a real client shape `Finch.build/4` with a plain
    # binary body never produces (that always computes a `content-length`).
    # If `has_body?/1` failed to detect this as a body, `build_request_body/1`
    # would treat it as bodiless and Core would receive nothing — so a
    # byte-for-byte match here is what proves the chunked branch actually
    # fired, not just that the request round-tripped.
    test "a chunked-transfer-encoded POST (no Content-Length) is detected and streamed to Core",
         %{
           proxy_base: base
         } do
      token = addon_token("cp_chunked", %{homeassistant_api: true})
      payload = :crypto.strong_rand_bytes(5_000)

      request =
        Finch.build(:post, "#{base}/core/api/states", [bearer(token)], {:stream, [payload]})

      {:ok, resp} = Finch.request(request, @client_finch, receive_timeout: 5_000)

      assert resp.status == 200
      assert Recorder.last().body == payload
      assert Recorder.last().method == "POST"
    end
  end

  ## 6. Core down (fact 5)

  describe "Core down" do
    test "core_api_state_fun false -> 502, fake Core never hit" do
      token = addon_token("cp_down_state", %{homeassistant_api: true})
      Application.put_env(:vagus, :core_api_state_fun, fn -> false end)

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 502
      assert HitCounter.count() == 0
    end

    test "a refused connection (closed port) -> 502" do
      token = addon_token("cp_down_refused", %{homeassistant_api: true})
      # A well-known closed port, same idiom `Vagus.Core.ClientTest` uses for
      # "nothing is listening here".
      Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:1")

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 502
    end
  end

  ## 7. Response shape (fact 6 — the buffered branch)

  describe "response shape" do
    test "status/content-type/cache-control/mcp-session-id are copied; everything else Core sent is dropped" do
      token = addon_token("cp_response", %{homeassistant_api: true})

      Script.set(
        201,
        [
          {"content-type", "application/json"},
          {"cache-control", "no-store"},
          {"mcp-session-id", "abc"},
          {"x-something-else", "leak"}
        ],
        Jason.encode!(%{"ok" => true})
      )

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 201
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "mcp-session-id") == ["abc"]
      assert Plug.Conn.get_resp_header(conn, "x-something-else") == []
      assert conn.resp_body == Jason.encode!(%{"ok" => true})
    end

    test "Plug's own default cache-control/vary never leak through when Core sends none" do
      token = addon_token("cp_response_nocc", %{homeassistant_api: true})
      Script.set(200, [], "ok")

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "cache-control") == []
      assert Plug.Conn.get_resp_header(conn, "vary") == []
    end

    test "a buffered (non-SSE) response never carries x-accel-buffering — only the SSE branch sets it" do
      token = addon_token("cp_response_no_accel", %{homeassistant_api: true})
      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "x-accel-buffering") == []
    end

    # `start_stream/3`'s `empty_body_status?/1` guard (204/304, no body) only
    # covers the SSE and `/stream` branches — `send_buffered_response/1` has
    # no equivalent guard, so this exercises the buffered path with the same
    # statuses to prove it doesn't need one (no crash, empty body through).
    test "Core replying 204 with no body -> caller sees 204, empty body, no crash (buffered path)" do
      token = addon_token("cp_response_204", %{homeassistant_api: true})
      Script.set(204, [], "")

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "Core replying 304 with no body -> caller sees 304, empty body, no crash (buffered path)" do
      token = addon_token("cp_response_304", %{homeassistant_api: true})
      Script.set(304, [], "")

      conn = call(:get, "/core/api/states", [bearer(token)])

      assert conn.status == 304
      assert conn.resp_body == ""
    end
  end

  ## 8. Route/method policy (fact 9) — runs before auth, so a wrong method
  ## or the no-route-registered case answers with no token present at all.

  describe "route/method policy" do
    test "DELETE /core/api/states/x is proxied" do
      token = addon_token("cp_delete", %{homeassistant_api: true})
      conn = call(:delete, "/core/api/states/x", [bearer(token)])

      assert conn.status == 200
      assert Recorder.last().method == "DELETE"
    end

    test "DELETE /homeassistant/api/states/x -> 405 (never registered on the legacy alias)" do
      token = addon_token("cp_delete_legacy", %{homeassistant_api: true})
      conn = call(:delete, "/homeassistant/api/states/x", [bearer(token)])

      assert conn.status == 405
      assert HitCounter.count() == 0
    end

    test "PUT /core/api/states -> 405" do
      token = addon_token("cp_put", %{homeassistant_api: true})
      conn = call(:put, "/core/api/states", [bearer(token)])

      assert conn.status == 405
      assert HitCounter.count() == 0
    end

    test "a wrong method 405s with NO token at all — the method check runs before auth" do
      conn = call(:put, "/core/api/states")

      assert conn.status == 405
    end

    test "GET /core/api/ proxies to Core's path /api/" do
      token = addon_token("cp_root", %{homeassistant_api: true})
      conn = call(:get, "/core/api/", [bearer(token)])

      assert conn.status == 200
      assert Recorder.last().path == "/api/"
    end

    test "GET /core/api (no trailing slash) -> 404, with NO token at all" do
      conn = call(:get, "/core/api")

      assert conn.status == 404
      assert HitCounter.count() == 0
    end
  end

  ## 9. Legacy /homeassistant/api alias

  describe "legacy alias" do
    test "GET /homeassistant/api/states behaves like /core/api/states" do
      token = addon_token("cp_legacy", %{homeassistant_api: true})
      conn = call(:get, "/homeassistant/api/states?x=1", [bearer(token)])

      assert conn.status == 200
      assert Recorder.last().path == "/api/states"
      assert Recorder.last().query == "x=1"
    end
  end

  ## 10. SSE / stream leg (phase 2) — needs a real Bandit-served Dispatcher
  ## and a real Finch client, not `Plug.Test`, so the client can observe
  ## partial data while the fake Core is still mid-response.

  describe "SSE / stream leg (phase 2)" do
    setup do
      proxy_pid =
        start_supervised!(
          {Bandit,
           plug: Dispatcher,
           port: 0,
           thousand_island_options: [num_acceptors: 1],
           http_options: [compress: false]},
          id: :proxy_bandit
        )

      start_supervised!({Finch, name: @client_finch})

      %{proxy_base: "http://127.0.0.1:#{listening_port(proxy_pid)}"}
    end

    test "a real SSE response streams incrementally — chunk 1 arrives while the fake Core is still blocked",
         %{proxy_base: base} do
      token = addon_token("cp_sse_incremental", %{homeassistant_api: true})
      test_pid = self()

      task =
        Task.async(fn ->
          request = Finch.build(:get, "#{base}/core/api/sse-incremental", [bearer(token)])

          Finch.stream(
            request,
            @client_finch,
            %{status: nil, headers: []},
            fn
              {:status, status}, acc ->
                %{acc | status: status}

              {:headers, headers}, acc ->
                %{acc | headers: headers}

              {:data, chunk}, acc ->
                send(test_pid, {:sse_chunk, chunk})
                acc

              {:trailers, _trailers}, acc ->
                acc
            end,
            receive_timeout: 5_000
          )
        end)

      assert_receive {:sse_chunk, "data: one\n\n"}, 2_000

      # The fake Core (`FakeCore`'s `/api/sse-incremental` route) is still
      # parked in its own `receive`, having sent nothing further — this is
      # the actual incrementality proof: if the response had been buffered
      # anywhere along the way, "two" could only ever arrive bundled with
      # "one", never held back until `SSEGate.release/0` below runs.
      refute_receive {:sse_chunk, "data: two\n\n"}, 200

      :ok = SSEGate.release()

      assert_receive {:sse_chunk, "data: two\n\n"}, 2_000

      assert {:ok, %{status: 200, headers: headers}} = Task.await(task, 5_000)
      assert find_header(headers, "content-type") == "text/event-stream"
      assert find_header(headers, "x-accel-buffering") == "no"
      assert find_header(headers, "cache-control") == "no-cache"
      assert find_header(headers, "mcp-session-id") == "sess-abc"
    end

    test "SSE content-type WITH a parameter (charset) still streams — media-type-only comparison",
         %{proxy_base: base} do
      token = addon_token("cp_sse_charset", %{homeassistant_api: true})

      {:ok, resp} = finch_req(:get, "#{base}/core/api/sse-charset", [bearer(token)])

      assert resp.status == 200
      # Core's full content-type value (params included) survives verbatim.
      assert find_header(resp.headers, "content-type") == "text/event-stream; charset=utf-8"
      # Only the SSE branch ever sets this — proves classification as SSE,
      # not the buffered branch happening to still produce the right body.
      assert find_header(resp.headers, "x-accel-buffering") == "no"
      assert resp.body == "data: hello\n\n"
    end

    test "GET /core/api/stream: response content-type comes from the REQUEST, not from Core (fact 7)",
         %{proxy_base: base} do
      token = addon_token("cp_stream_ct", %{homeassistant_api: true})

      Script.set(
        200,
        [
          {"content-type", "application/xml"},
          {"cache-control", "no-store"},
          {"mcp-session-id", "leak"}
        ],
        "<not>used</not>"
      )

      {:ok, resp} =
        finch_req(:get, "#{base}/core/api/stream", [bearer(token), {"content-type", "text/plain"}])

      assert resp.status == 200
      assert find_header(resp.headers, "content-type") == "text/plain"
      # fact 7's handler copies nothing from Core's response — unlike the
      # SSE branch above, neither of these rides through even though Core
      # sent both.
      assert find_header(resp.headers, "cache-control") == nil
      assert find_header(resp.headers, "mcp-session-id") == nil
      assert find_header(resp.headers, "x-accel-buffering") == nil
    end

    test "GET /core/api/stream: no request content-type -> empty (upstream's raw-header quirk)",
         %{
           proxy_base: base
         } do
      token = addon_token("cp_stream_ct_default", %{homeassistant_api: true})
      Script.set(200, [{"content-type", "application/json"}], "{}")

      {:ok, resp} = finch_req(:get, "#{base}/core/api/stream", [bearer(token)])

      assert resp.status == 200
      # fact 7: upstream sets the `/stream` response content-type from the RAW
      # request header, `request.headers.get(CONTENT_TYPE, "")` — so with no
      # request content-type it is the empty string, NOT Core's own
      # `application/json`. Mirrored verbatim, not "fixed" to octet-stream.
      assert find_header(resp.headers, "content-type") == ""
    end

    test "POST /core/api/stream -> 405, fake Core never hit — the dedicated GET-only resource",
         %{proxy_base: base} do
      token = addon_token("cp_stream_post", %{homeassistant_api: true})

      {:ok, resp} = finch_req(:post, "#{base}/core/api/stream", [bearer(token)], "x")

      assert resp.status == 405
      assert HitCounter.count() == 0
    end

    test "GET /core/api/stream with no token -> 401, fake Core never hit", %{proxy_base: base} do
      {:ok, resp} = finch_req(:get, "#{base}/core/api/stream")

      assert resp.status == 401
      assert HitCounter.count() == 0
    end

    test "GET /homeassistant/api/stream behaves like the /core/api/stream alias", %{
      proxy_base: base
    } do
      token = addon_token("cp_stream_legacy", %{homeassistant_api: true})
      Script.set(200, [{"content-type", "application/json"}], "{}")

      {:ok, resp} = finch_req(:get, "#{base}/homeassistant/api/stream", [bearer(token)])

      assert resp.status == 200
      assert Recorder.last().path == "/api/stream"
    end

    test "a Core crash mid-SSE-stream doesn't crash the proxy; a subsequent request still succeeds",
         %{proxy_base: base} do
      token = addon_token("cp_sse_crash", %{homeassistant_api: true})

      request = Finch.build(:get, "#{base}/core/api/sse-crash", [bearer(token)])
      result = Finch.request(request, @client_finch, receive_timeout: 5_000)

      # The exact client-visible shape of a mid-stream abort (a short
      # `{:ok, _}` with a truncated body, or a transport `{:error, _}`) isn't
      # the point — either is a legitimate way for an abrupt Core-side death
      # to surface. What matters is that the proxy (a Bandit connection
      # process running `Vagus.API.CoreProxy`) doesn't take the listener
      # down with it, proven below by a completely unrelated request still
      # succeeding right after.
      assert match?({:ok, %Finch.Response{}}, result) or match?({:error, _}, result)

      token2 = addon_token("cp_sse_crash_followup", %{homeassistant_api: true})
      Script.set(200, [{"content-type", "application/json"}], Jason.encode!(%{"ok" => true}))

      {:ok, resp2} =
        finch_req(:get, "#{base}/core/api/states", [bearer(token2)])

      assert resp2.status == 200
    end
  end
end
