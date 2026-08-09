defmodule Vagus.API.CoreProxy do
  @moduledoc """
  The `/core/api/*` and legacy `/homeassistant/api/*` REST proxy leg
  (`.claude/plans/vagus-core-api-proxy/plan.md`), reached only via
  `Vagus.API.Dispatcher`'s `["core","api"|rest]` / `["homeassistant","api"|rest]`
  routing rule — **never** through `Vagus.API.Router`, for the same reason
  `Vagus.API.IngressProxy` isn't: `Router` runs `Plug.Parsers` with a 64 KB
  limit ahead of `:match`/`:dispatch` for every request it handles, and upstream
  streams the proxied body (`request.content`) with no size cap on this leg at
  all. Deciding "router or proxy" has to happen one level up, before either
  pipeline touches the body — see `Dispatcher`'s moduledoc for the fuller
  argument, which applies here unchanged.

  ## These paths bypass ordinary token validation upstream (plan fact 1)

  Upstream's `no_security_check` lists `/homeassistant/api/.*`,
  `/homeassistant/websocket`, `/core/api/.*`, `/core/websocket` — so
  `token_validation` never runs for them and `request[REQUEST_FROM]` is left
  `None`. **The proxy authenticates itself**, via `_check_access`, not via the
  caller model every other route family uses. `Vagus.API.Auth`/`Vagus.API.Tiers`
  never run on this leg either; `check_access/1` below is the whole gate.

  ## The auth model is INVERTED from every other add-on-facing route (fact 2)

  Everywhere else in this emulator, a caller presents a token, `Vagus.API.Auth`
  resolves it to `:supervisor` or `{:addon, identity}`, and `Vagus.API.Tiers`
  grades the identity's `hassio_role` against the path. Here there is no
  grading and no role lattice: the token must resolve to an **installed
  add-on** in `Vagus.Addon.Registry`, and that add-on's identity must carry
  `homeassistant_api: true` (`config.yaml`'s `homeassistant_api:`, plumbed
  through `Vagus.Addon.Config` since M4 but only reaching
  `Vagus.Addon.Registry.identity_from_config/1`'s output as of this feature —
  see that module's moduledoc). Anything else is refused with 401, including
  a token that resolves fine but lacks the flag.

  **The supervisor token is deliberately NOT accepted here** — it simply
  doesn't resolve in `Vagus.Addon.Registry` (that registry only ever holds
  add-on tokens), so it falls through to the same 401 as any other unknown
  token. There is no special-case rejection to get wrong, which is itself the
  point: the one route family where Core's own token — normally the highest
  tier there is — must be refused, and an add-on's token — normally the
  lowest — must be treated as admin-on-Core, is exactly the shape of mistake
  that is easiest to get backwards. Getting the predicate wrong either breaks
  every add-on that legitimately calls the HA API or hands Core's admin rights
  to an add-on that never declared `homeassistant_api`.

  ## Why the proxy calls Core as the Supervisor user (fact 3)

  On the Supervisor↔Core unix socket (`Vagus.Core.Transport`) that
  credential is the connection itself: Core reads every socket request as
  the Supervisor user, so no `Authorization` header is sent and no access
  token is resolved at all (the request no longer fails with 502 just
  because no refresh token has been posted yet). On the TCP fallback the
  bearer token below is still what makes the call Supervisor-privileged.
  Either way the caller's own credential never reaches Core.

  Upstream issues the proxied request via `sys_homeassistant.api.make_request`
  — the Supervisor's own credentials, not the caller's. So an add-on holding
  `homeassistant_api: true` acts on Core's REST API **as the Supervisor**,
  i.e. with admin rights, regardless of what tier that add-on would otherwise
  hold. That is the entire reason `Vagus.API.Tiers.blacklisted?/1` denies
  Core's whole `/api/hassio…` namespace (PR #34, landed before this feature so
  the deny could not be forgotten; widened from the two literal `hassio/`
  paths to the namespace after the upstream `hassio_auth/password_reset`
  account-takeover — see `Vagus.Core.Reserved`). This module still has no idea
  a path is blacklisted: that check runs entirely in `Vagus.API.Dispatcher`
  (`dispatch_core_proxy/2`), BEFORE this module is ever reached, using the same
  `Vagus.API.Auth`-shaped 403 every other blacklisted request gets, and it
  stays there — a second policy check *here* would be the same rule
  reimplemented in a second place, free to drift.

  What DOES back it up is one layer further in, at
  `Vagus.Core.Transport.build/6`: this module builds its request with
  `origin: :proxied`, and a reserved path built under that tag raises rather
  than reaching Core. That is not a policy decision duplicated — it is the
  same rule asserted where Vagus's credential is actually conferred, so a
  routing regression, or some future leg that reaches Core without passing
  through `Vagus.API.Dispatcher` at all, fails loudly instead of silently
  handing an add-on the Supervisor's identity. Upstream reached the same
  shape from the other direction, adding a `CORE_API_DENY` guard inside
  `APIProxy.api` after its own blacklist proved to have a hole in it.

  ## Response handling: buffer, SSE-stream, or the dedicated `/stream` leg (facts 6, 7)

  Transport is `Finch.stream_while/5` (mirroring `Vagus.API.IngressProxy`'s
  own response-streaming idiom), and the `{:headers, headers}` event decides
  which of three shapes the rest of the response takes:

  - `text/event-stream` (fact 6, media type only — the header value up to
    any `;` parameter, trimmed and lowercased, mirroring aiohttp's
    `client.content_type`, which strips params the same way) streams via
    `send_chunked`/`chunk` as each `{:data, _}` event arrives: Core's full
    content-type value survives verbatim (params included), `cache-control`/
    `mcp-session-id` are copied if Core sent them
    (`@response_header_allowlist`, same allowlist the buffered branch uses),
    and `x-accel-buffering: no` is set so nothing between here and the
    caller re-buffers the chunks.
  - Everything else is still buffered exactly as phase 1 left it —
    `{:data, _}` events accumulate as iodata and the whole thing is answered
    in one `send_resp/3` once the stream ends — so non-SSE behavior stays
    byte-identical to phase 1.
  - `GET /core/api/stream` / `GET /homeassistant/api/stream` (fact 7,
    matched as `rest == ["stream"]`) is neither of the above: the response
    is ALWAYS streamed regardless of what content-type Core's own response
    declares, `check_route/2` 405s any method but GET before auth even runs
    (fact 9 — upstream registers this literal path as a dedicated resource
    ahead of the generic `{path:.+}` route), there is no receive timeout
    (`timeout=None` upstream), and the streamed response's content-type is
    taken from the REQUEST's own `content-type` header instead of Core's —
    an upstream quirk, mirrored here rather than fixed, defaulting to
    `application/octet-stream` when the caller sent none (matching
    aiohttp's `request.content_type` default). This route copies neither
    `x-accel-buffering` nor `cache-control`/`mcp-session-id` — upstream's
    `stream` handler copies nothing from Core's response at all, unlike the
    SSE branch above — so the two streaming branches deliberately don't
    share a header-copying helper.

  WebSocket (`GET /core/api/websocket`, `GET /core/websocket`, and their
  `/homeassistant/*` aliases, fact 8) is a third leg entirely, handled by
  `call_websocket/1` below rather than falling into the REST/SSE pipeline:
  `Vagus.API.Dispatcher` forwards both the bare two-segment path and the
  `.../api/websocket` alias here, `call_websocket/1` checks method (GET
  only) and that the request is a genuine WS upgrade (400 otherwise — an
  aiohttp `WebSocketResponse.prepare` on a non-upgrade request raises
  `HTTPBadRequest`, mirrored here rather than 404ing it), then hands off to
  `WebSockAdapter.upgrade/4` with `Vagus.API.CoreProxy.WSBridge`. This is the
  one branch where `check_access/1` deliberately does **not** run before the
  upgrade: fact 8's handshake — `WSBridge`'s own `:awaiting_auth` →
  `:relaying` state machine — **is** the auth here, run against the caller
  over the WebSocket itself instead of a header, exactly like the rest of
  this module's inverted model (fact 1). See `Vagus.API.CoreProxy.WSBridge`'s
  moduledoc for the full handshake and relay design.

  ## Route/method policy runs before auth (fact 9)

  Upstream's `no_security_check` paths are matched by an aiohttp route table
  keyed on method + path *before* any auth code executes at all — a request
  for a method nobody registered 405s with no credential ever inspected.
  `check_route/2` mirrors that ordering: wrong method, the bare
  (non-slash-terminated) `/core/api`/`/homeassistant/api` literal, and any
  non-GET on `rest == ["stream"]` (fact 7's dedicated resource, registered
  ahead of the generic route — see above) are all answered before
  `check_access/1` runs.
  """

  @behaviour Plug

  import Plug.Conn

  alias Vagus.Addon.Registry
  alias Vagus.Core.{Client, Health, Transport}

  @finch Vagus.API.CoreProxy.Finch

  # Upstream's REST-leg timeout (fact 6). Long on purpose: a slow Core-side
  # handler (e.g. a big `/api/config/core/check_config`) must not be cut off
  # by the proxy itself.
  @receive_timeout 300_000

  # FORWARD_HEADERS (fact 4) — an ALLOWLIST, not a strip list. Everything not
  # named here is dropped, including the caller's own `authorization`/
  # `x-ha-access`: this is what stops a caller's credential (irrelevant to
  # Core, meaningful only to this proxy) or anything else it sent from ever
  # reaching Core. `content-type` is handled separately below, matching
  # upstream passing it as its own `content_type=` argument rather than via
  # the header list.
  @request_header_allowlist ~w(x-speech-content accept last-event-id mcp-session-id mcp-protocol-version)

  # The response side of fact 6's buffered branch: status + content-type are
  # always preserved (handled directly in `send_buffered_response/1`), and
  # these two are the ONLY further headers upstream copies. Everything else Core sent —
  # its own `cache-control` if any is NOT unconditionally copied (only these
  # two names are), `set-cookie`, `x-frame-options`, whatever — is dropped.
  @response_header_allowlist ~w(cache-control mcp-session-id)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.path_info do
      ["core", "websocket"] ->
        call_websocket(conn)

      ["homeassistant", "websocket"] ->
        call_websocket(conn)

      [family, "api", "websocket"] when family in ["core", "homeassistant"] ->
        call_websocket(conn)

      [family, "api" | rest] ->
        call_rest(conn, family, rest)

      # Unreachable via the only real entry point: `Dispatcher.
      # dispatch_core_proxy/2` forwards only the four exact path shapes
      # the clauses above already match. Kept as defensive coding for a
      # `@behaviour Plug` module that could in principle be invoked
      # directly (a narrow test, or some future caller) rather than
      # evidence of a routing gap that needs closing.
      _other ->
        send_plain(conn, 404, "Not Found")
    end
  end

  # The REST/SSE/`/stream` leg (phases 1-2) — unchanged from before phase 3
  # except for being pulled out of `call/2` itself, so the WS branch above
  # can intercept `rest == ["websocket"]` before it ever reaches
  # `check_route/2`'s generic clause.
  defp call_rest(conn, family, rest) do
    # Resolved once per request and threaded through, so the URL, the
    # credential decision and the pool can't disagree about which transport
    # this request is on (`Vagus.Core.Transport`).
    transport = Transport.current()

    with :ok <- check_route(conn, family, rest),
         {:ok, token} <- extract_token(conn),
         {:ok, identity} <- resolve_addon(token),
         :ok <- check_homeassistant_api(identity),
         :ok <- check_core_health(),
         {:ok, credential} <- core_credential(transport) do
      proxy_request(conn, rest, credential, transport)
    else
      {:error, :not_found} -> send_plain(conn, 404, "Not Found")
      {:error, :method_not_allowed} -> send_plain(conn, 405, "Method Not Allowed")
      {:error, :unauthorized} -> send_plain(conn, 401, "Unauthorized")
      {:error, :bad_gateway} -> send_plain(conn, 502, "Bad Gateway")
    end
  end

  ## WebSocket leg (fact 8) — see moduledoc.

  # Fact 9: GET only, registered nowhere else — a method check upstream's own
  # aiohttp route table would answer with 405 before any handler code runs,
  # mirrored here before `websocket_upgrade?/1` even looks at the headers.
  # A GET that isn't actually a WS upgrade gets a plain 400 (aiohttp's
  # `WebSocketResponse.prepare/1` raises `HTTPBadRequest` on exactly this
  # case) rather than being treated as some other kind of request — there is
  # no non-WS meaning for this path at all.
  defp call_websocket(conn) do
    cond do
      conn.method != "GET" ->
        send_plain(conn, 405, "Method Not Allowed")

      not websocket_upgrade?(conn) ->
        send_plain(conn, 400, "Bad Request")

      true ->
        # No `check_access/1` here — deliberately. `WSBridge`'s own
        # `:awaiting_auth` → `:relaying` handshake against the caller *is*
        # the auth for this leg (fact 1/8); running the REST leg's header
        # check here would be answering a question this route was never
        # asked. `timeout: 900_000` mirrors `Vagus.API.IngressProxy`'s own
        # WS upgrade (both Thousand Island's `read_timeout` and this
        # `WebSockAdapter` idle timeout need to agree, same reasoning as
        # that module's own comment). `max_frame_size: 4_194_304`: upstream's
        # `WebSocketResponse` here takes no `max_msg_size` override, so it
        # gets aiohttp's own default (4 MiB) — unlike the ingress bridge's
        # 16 MiB, which mirrors THAT route's own explicit override.
        WebSockAdapter.upgrade(
          conn,
          Vagus.API.CoreProxy.WSBridge,
          %{},
          timeout: 900_000,
          max_frame_size: 4_194_304
        )
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

  ## Route/method policy (fact 9) — runs before any auth check.

  # Upstream registers exactly `GET /core/api/` and `GET /homeassistant/api/`
  # for the empty-`rest` case (note the trailing slash) — nothing is
  # registered for the bare `/core/api`/`/homeassistant/api` literal, so
  # aiohttp's router has no match at all and answers 404, not 405. `path_info`
  # can't distinguish the two (Plug's segment split drops empty trailing
  # segments either way — see `Plug.Conn.Adapter.split_path/1`), so this reads
  # `conn.request_path`, the raw, never-resplit path string, exactly like
  # `Vagus.API.IngressProxy.build_url/4`'s own reliance on raw path bytes.
  defp check_route(conn, _family, []) do
    cond do
      not String.ends_with?(conn.request_path, "/") -> {:error, :not_found}
      conn.method != "GET" -> {:error, :method_not_allowed}
      true -> :ok
    end
  end

  # `GET /core/api/stream` / `GET /homeassistant/api/stream` (fact 7 + 9):
  # upstream registers a dedicated GET-only aiohttp resource for the literal
  # `stream` path BEFORE the generic `{path:.+}` route below, so a
  # POST/DELETE to it matches THIS resource and 405s, rather than falling
  # through to the generic handler's own (wider) method table.
  defp check_route(conn, _family, ["stream"]) do
    if conn.method == "GET", do: :ok, else: {:error, :method_not_allowed}
  end

  defp check_route(conn, family, _rest) do
    if conn.method in allowed_methods(family), do: :ok, else: {:error, :method_not_allowed}
  end

  # `{GET,POST,DELETE} /core/api/{path:.+}` vs `{GET,POST} /homeassistant/api/{path:.+}`
  # (fact 9) — upstream never registered DELETE on the legacy alias.
  defp allowed_methods("core"), do: ~w(GET POST DELETE)
  defp allowed_methods("homeassistant"), do: ~w(GET POST)

  ## Auth (`_check_access`, fact 2) — see moduledoc for the inverted model.

  # Token: `Authorization`'s LAST space-separated part (upstream
  # `bearer.split(' ')[-1]`, not a strict `"Bearer " <> token` match — a
  # malformed or extra-token header still yields *a* candidate string, which
  # then simply fails to resolve below) — or, absent that header, the legacy
  # `X-Ha-Access` value verbatim. Neither present is a 401.
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] ->
        {:ok, value |> String.split(" ") |> List.last()}

      [] ->
        case get_req_header(conn, "x-ha-access") do
          [value | _] -> {:ok, value}
          [] -> {:error, :unauthorized}
        end
    end
  end

  # Registry may be absent in narrow test setups — same guard
  # `Vagus.API.Auth.addon_identity/1` uses: treat as "no add-on tokens", not a
  # crash.
  defp resolve_addon(token) do
    if Process.whereis(Registry) do
      case Registry.identity_for_token(token) do
        {:ok, identity} -> {:ok, identity}
        :error -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  # Default `false` — the most restrictive reading, same convention
  # `Vagus.API.Tiers.caller_tier/1` uses for `hassio_api` — so an identity
  # built before this field existed (or a narrow test's hand-built map) is
  # closed, never accidentally admin-on-Core.
  defp check_homeassistant_api(identity) do
    if Map.get(identity, :homeassistant_api, false), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  The `_check_access` predicate (fact 2), extracted for reuse by
  `Vagus.API.CoreProxy.WSBridge` — fact 8's handshake needs the exact same
  resolve-then-flag-check, just fed a token pulled from the caller's WS auth
  message instead of a header. `resolve_addon/1` and `check_homeassistant_api/1`
  already return the same `:ok | {:error, :unauthorized}` shape this needs, so
  this is a thin `with` over the two rather than a second implementation that
  could drift from the REST leg's.
  """
  @spec check_access(String.t()) :: :ok | {:error, :unauthorized}
  def check_access(token) do
    with {:ok, identity} <- resolve_addon(token) do
      check_homeassistant_api(identity)
    end
  end

  # No logging on any branch above, deliberately. This whole path runs
  # pre-auth from the caller's point of view — same primitive
  # `Vagus.API.Dispatcher`'s `report_filtered/2` and `Vagus.API.Auth`'s
  # `refuse_blacklisted/1` both already decline to log per-request for: an
  # unauthenticated or wrongly-scoped caller can repeat this at will, and a
  # `Logger.warning` per attempt would let it push real evidence out of
  # `RingLogger`'s fixed-size ring, the only forensic record on a Nerves
  # device. Nothing here is attacker-controlled bytes the way a filtered path
  # is, but the volume argument alone is enough — see PR #34's history for why
  # this project already learned that lesson once.

  ## Core health gate (fact 5)

  # Injectable so tests don't need a real Core. Upstream's
  # `check_api_state()` is an authenticated probe against Core's own API,
  # called fresh per request; Vagus reuses `Vagus.Core.Health.check/1` — the
  # established "is Core up" primitive already relied on by the Core watchdog
  # — rather than adding a second Core-liveness probe with its own drift risk.
  # `Health.check/1`'s frontend probe and upstream's authenticated API probe
  # can in principle disagree (frontend up, API down or vice versa); that gap
  # is accepted rather than built around, same tradeoff the watchdog already
  # made.
  defp check_core_health do
    fun = Application.get_env(:vagus, :core_api_state_fun, &default_api_state/0)
    if fun.(), do: :ok, else: {:error, :bad_gateway}
  end

  @doc "Default `:core_api_state_fun` — see moduledoc/`check_core_health/0`."
  @spec default_api_state() :: boolean()
  def default_api_state, do: Health.check() == :healthy

  ## Credential (fact 3)

  # Injectable so tests don't need a live token exchange. Deliberately NOT
  # `Vagus.Core.Client.request/3` — that function is a `GenServer.call`, so
  # every proxied request would serialise through one process and a 300s-timeout
  # request could stall every other Core call behind it
  # (plan's "Vagus-specific decisions"). `Client.access_token/1` alone (a
  # cheap cached-token read) is the only thing borrowed from `Client`;
  # transport for the proxied request itself is a per-request
  # `Finch.stream_while/5` call, below.
  # A3: the socket IS the credential (implicit Supervisor-user auth), so
  # there is nothing to resolve and nothing that can fail — `nil` here means
  # "send no `authorization` header", not "unauthenticated".
  defp core_credential({:socket, _path}), do: {:ok, nil}

  defp core_credential({:tcp, _base_url}) do
    fun = Application.get_env(:vagus, :core_proxy_access_token_fun, &default_access_token/0)

    case fun.() do
      {:ok, token} -> {:ok, token}
      # Can't authenticate to Core ~ Core unavailable, from this proxy's point
      # of view — the same 502 the health gate above answers with.
      {:error, _reason} -> {:error, :bad_gateway}
    end
  end

  @doc "Default `:core_proxy_access_token_fun` — see moduledoc/`core_access_token/0`."
  @spec default_access_token() :: {:ok, String.t()} | {:error, term()}
  def default_access_token, do: Client.access_token()

  @doc """
  The WS leg's shared handshake deadline (fact 8: "upstream uses 10 s for
  both") — `Vagus.API.CoreProxy.WSBridge` arms it while waiting for the
  caller's auth message, and `WSBridge.Upstream` arms it while dialing +
  authenticating against Core, so both timers agree without either module
  hardcoding the default separately. `config :vagus, :core_ws_auth_timeout`,
  tests shrink it to exercise the timeout path without a real 10s wait.
  """
  @spec ws_auth_timeout_ms() :: pos_integer()
  def ws_auth_timeout_ms, do: Application.get_env(:vagus, :core_ws_auth_timeout, 10_000)

  @doc """
  Bound on the caller-side `GenServer.call/3` `WSBridge.handle_in/2` makes to
  `Upstream` for every relayed frame once past `:awaiting_auth` (issue #37) —
  the backstop for a wedged Core-side send that the smaller
  `:core_ws_send_timeout` (`Upstream`'s own Mint socket, resolved first in the
  normal case) somehow didn't already resolve. `config
  :vagus, :core_ws_handoff_timeout`, tests shrink it to exercise the backstop
  path without a real 10s wait.
  """
  @spec ws_handoff_timeout_ms() :: pos_integer()
  def ws_handoff_timeout_ms, do: Application.get_env(:vagus, :core_ws_handoff_timeout, 10_000)

  ## The proxied request itself

  # `rest == ["stream"]` (fact 7) gets `:infinity` instead of `@receive_timeout`
  # (upstream `timeout=None`) and is flagged in `acc` so `do_handle_event/2`
  # knows to force-stream with the request's own content-type rather than
  # deciding via Core's response (see moduledoc).
  defp proxy_request(conn, rest, credential, transport) do
    {conn, body, ref} = build_request_body(conn)
    path = build_path(rest, conn.query_string)
    headers = build_request_headers(conn, credential)
    request = Transport.build(transport, :proxied, conn.method, path, headers, body)
    stream_route? = rest == ["stream"]

    acc = %{
      conn: conn,
      ref: ref,
      resolved?: ref == nil,
      status: nil,
      mode: nil,
      data: [],
      resp_headers: [],
      stream_route?: stream_route?,
      request_content_type: if(stream_route?, do: request_content_type(conn))
    }

    timeout = if stream_route?, do: :infinity, else: @receive_timeout

    request
    |> Finch.stream_while(finch_pool(), acc, &handle_event/2, receive_timeout: timeout)
    |> finish()
  end

  # fact 7's quirk, mirrored not fixed: upstream's `/core/api/stream` handler
  # sets the response `content_type` from the REQUEST's own `Content-Type`,
  # never from Core's response — and specifically from the RAW header,
  # `request.headers.get(CONTENT_TYPE, "")` (`supervisor/api/proxy.py`'s
  # `stream()`), NOT aiohttp's parsed `request.content_type` property. So any
  # `; charset=...` parameter the caller sent is preserved verbatim rather than
  # stripped, and the no-`Content-Type` default is upstream's literal `""`
  # (aiohttp then emits an empty `Content-Type` on the event stream — the quirk
  # mirrored, not "fixed" up to `application/octet-stream`).
  defp request_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] -> ct
      [] -> ""
    end
  end

  # "/api/" <> the `rest` segments, joined VERBATIM — never
  # percent-decoded/re-encoded. Same [VERIFIED] reasoning as
  # `Vagus.API.IngressProxy.build_url/4`: `path_info` arrives already exactly
  # as percent-encoded as the original request line (`Plug.Conn.Adapter`'s
  # `split_path/1` never calls `URI.decode`), so re-encoding here would
  # double-encode any existing `%XX` escape. `rest == []` joins to `""`,
  # giving Core the path `/api/` for `GET /core/api/` — matching fact 9's
  # bare-root route exactly. The origin (socket or `:core_base_url`) is
  # `Vagus.Core.Transport.build/5`'s half of this.
  defp build_path(rest, query_string) do
    path = "/api/" <> Enum.join(rest, "/")
    if query_string == "", do: path, else: path <> "?" <> query_string
  end

  # One Finch instance, but Finch keys its pools by
  # `{scheme, host, port, tag}` — and a `unix_socket:` request's host is
  # `{:local, path}` — so socket-borne proxied requests get their own
  # dedicated pool inside this same supervisor, never sharing connections
  # with the TCP fallback's.
  defp finch_pool, do: Application.get_env(:vagus, :core_proxy_finch, @finch)

  # Fact 4's allowlist, plus `content-type` (passed separately upstream) plus
  # the credential this proxy itself supplies. The caller's own
  # `authorization`/`x-ha-access` is never in `@request_header_allowlist`, so
  # it is dropped here rather than forwarded — Core must only ever see the
  # Supervisor's own credential, never the caller's.
  defp build_request_headers(conn, credential) do
    allowed =
      Enum.filter(conn.req_headers, fn {k, _v} -> k in @request_header_allowlist end)

    content_type =
      case get_req_header(conn, "content-type") do
        [ct | _] -> [{"content-type", ct}]
        [] -> []
      end

    # `nil` credential = the socket path's implicit Supervisor-user auth
    # (fact 3 + A3): no header at all, exactly as upstream sends none.
    authorization =
      if credential, do: [{"authorization", "Bearer " <> credential}], else: []

    allowed ++ content_type ++ authorization
  end

  # Same detection `Vagus.API.IngressProxy.has_body?/1` uses: an HTTP/1.1
  # request with neither a positive `content-length` nor
  # `transfer-encoding: chunked` has no body at all (RFC 7230 §3.3), so there
  # is nothing to read.
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

  # Unlike `Vagus.API.IngressProxy.build_request_body/2`, there is no buffered
  # branch and no size cap here: upstream streams `request.content`
  # unconditionally on this leg (no `ingress_stream`-style opt-in to mirror),
  # so a body-carrying request is always streamed. `ref` is `nil` only for
  # the no-body case; a streamed body always gets one (see `resolve_conn/1`).
  defp build_request_body(conn) do
    if has_body?(conn) do
      build_stream_body(conn)
    else
      {conn, nil, nil}
    end
  end

  # Identical mechanism to `Vagus.API.IngressProxy.build_stream_body/1` —
  # see that function's doc for the full safety argument. In short:
  # `Stream.resource/3` over `Plug.Conn.read_body/2` (both `length:` and
  # `read_length:` pinned to 64_000 — security-phase7.md W2, `:read_length`
  # alone bounds only the per-socket recv, not the per-call return) holds at
  # most one 64KB chunk in memory, and the final `conn` — the one that
  # actually reflects Bandit's adapter having consumed the body — is threaded
  # back out via a message rather than returned normally, because the
  # `next_fun` below runs inside whichever process calls `Finch.stream_while/5`
  # (this same process), not in `call/2`'s own stack frame. That send is safe
  # specifically because Finch/Mint's request/response exchange is
  # request-then-stream-response, never duplex: the entire body is drained
  # before the first `{:status, _}` response event ever reaches
  # `handle_event/2`, so the message is always already sitting in this
  # process's mailbox by the time `resolve_conn/1` looks for it — this never
  # blocks.
  defp build_stream_body(conn) do
    ref = make_ref()
    parent = self()

    stream =
      Stream.resource(
        fn -> conn end,
        fn
          :done ->
            {:halt, :done}

          conn ->
            case read_body(conn, length: 64_000, read_length: 64_000) do
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

    {conn, {:stream, stream}, ref}
  end

  # Resolves the conn that actually reflects Bandit's adapter having consumed
  # the request body (see `build_stream_body/1`) before this module answers
  # through it — answering through the stale pre-read conn would leave
  # Bandit believing the body was never touched, corrupting its read state on
  # a keep-alive connection (the exact W1 hazard
  # `Vagus.API.IngressProxy.read_buffered/4`'s doc describes). Threaded
  # through `acc` (`Vagus.API.IngressProxy.resolve_conn/1`'s own shape)
  # rather than as a bare `conn`/`ref` pair now that the response side is
  # `Finch.stream_while/5`-driven: `resolved?` makes re-resolution on every
  # subsequent event a no-op instead of a second (harmless but pointless)
  # `receive`. The `after 0` is a defensive fallback, not something expected
  # to ever miss — see `build_stream_body/1`'s moduledoc note for why the
  # message is always already there by the time the first response event
  # arrives.
  defp resolve_conn(%{resolved?: true} = acc), do: acc

  defp resolve_conn(%{ref: ref, conn: conn} = acc) do
    final_conn =
      receive do
        {^ref, final_conn} -> final_conn
      after
        0 -> conn
      end

    %{acc | conn: final_conn, resolved?: true}
  end

  ## Response streaming (`Finch.stream_while/5`, mirroring
  ## `Vagus.API.IngressProxy`'s own `handle_event/2`/`do_handle_event/2`/
  ## `finish/1` idiom) — the three shapes are decided entirely in
  ## `do_handle_event/2`'s `{:headers, _}` clauses; see the moduledoc.

  defp handle_event(event, acc) do
    acc = resolve_conn(acc)
    do_handle_event(event, acc)
  end

  defp do_handle_event({:status, status}, acc) do
    {:cont, %{acc | status: status}}
  end

  # fact 7: `/core/api/stream` ALWAYS streams, using the REQUEST's
  # content-type (`acc.request_content_type`, computed once in
  # `proxy_request/3`) rather than deciding from Core's own response —
  # deliberately checked before the SSE clause below so a `/stream` request
  # can never accidentally fall into the SSE branch's header-copying
  # behavior instead.
  defp do_handle_event({:headers, _headers}, %{stream_route?: true} = acc) do
    start_stream(acc, acc.request_content_type, & &1)
  end

  # fact 6: SSE detected by media type only (the header value up to any
  # `;` parameter, trimmed and lowercased — mirroring aiohttp's
  # `client.content_type`); Core's full content-type value (params
  # included) is what actually reaches the caller.
  defp do_handle_event({:headers, headers}, acc) do
    content_type = header_value(headers, "content-type")

    if sse_media_type?(content_type) do
      start_stream(acc, content_type, fn conn ->
        conn
        |> put_resp_header("x-accel-buffering", "no")
        |> copy_allowed_response_headers(headers)
      end)
    else
      {:cont, %{acc | mode: :buffer, resp_headers: headers, data: []}}
    end
  end

  defp do_handle_event({:data, chunk}, %{mode: :buffer} = acc) do
    {:cont, %{acc | data: [chunk | acc.data]}}
  end

  defp do_handle_event({:data, chunk}, acc) do
    case chunk(acc.conn, chunk) do
      {:ok, conn} -> {:cont, %{acc | conn: conn}}
      # The caller hung up mid-stream — nothing more to do but stop, same as
      # `Vagus.API.IngressProxy.do_handle_event/2`'s `{:data, _}` clause.
      {:error, _reason} -> {:halt, %{acc | conn: halt(acc.conn)}}
    end
  end

  defp do_handle_event({:trailers, _trailers}, acc), do: {:cont, acc}

  # Shared by both streaming branches (fact 6 and fact 7) — `header_fun` is
  # the one thing that differs between them (SSE's allowlist copy + accel
  # header vs. fact 7's "copy nothing"), everything else (defaults deletion,
  # empty-body-status handling, `send_chunked`) is identical.
  defp start_stream(acc, content_type, header_fun) do
    conn =
      acc.conn
      |> delete_resp_header("cache-control")
      |> delete_resp_header("vary")
      |> put_resp_header("content-type", content_type)
      |> header_fun.()

    # `conn.method == "HEAD"` is unreachable by construction: fact 9's route
    # table lists no HEAD for this route family, and `check_route/2` gates
    # every request ahead of `proxy_request/3`/`start_stream/3`, so no HEAD
    # request can ever reach this clause. Kept anyway (mirrors
    # `Vagus.API.IngressProxy`'s own equivalent branch, where HEAD may
    # actually be reachable) rather than deleted.
    if empty_body_status?(acc.status) or conn.method == "HEAD" do
      conn = send_resp(conn, acc.status, "")
      {:halt, %{acc | conn: conn, mode: :empty}}
    else
      conn = send_chunked(conn, acc.status)
      {:cont, %{acc | conn: conn, mode: :chunked}}
    end
  end

  defp sse_media_type?(nil), do: false

  defp sse_media_type?(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("text/event-stream")
  end

  defp empty_body_status?(status) when status in [204, 304], do: true
  defp empty_body_status?(status) when status >= 100 and status < 200, do: true
  defp empty_body_status?(_status), do: false

  defp finish({:ok, acc}) do
    acc = resolve_conn(acc)

    case acc.mode do
      :buffer -> send_buffered_response(acc)
      _already_sent -> acc.conn
    end
  end

  defp finish({:error, _finch_error, acc}) do
    acc = resolve_conn(acc)

    if acc.mode in [nil, :buffer] do
      # Nothing sent to the caller yet (buffering, or the request failed
      # before any response event ever arrived) — an honest 502 is always
      # safe here.
      send_plain(acc.conn, 502, "Bad Gateway")
    else
      # Already mid-response (`send_chunked` already called) — a second
      # response would raise `Plug.Conn.AlreadySentError`; just halt, same
      # as `Vagus.API.IngressProxy.finish/1`.
      halt(acc.conn)
    end
  end

  ## Response (fact 6's buffered branch — phase 1's byte-identical behavior)

  # Status + content-type are always preserved; `cache-control`/`mcp-session-id`
  # are copied only if Core actually sent them (`@response_header_allowlist`)
  # — nothing else Core's response carried is forwarded. `%Plug.Conn{}`'s own
  # default `cache-control`/`vary` are deleted FIRST (audit F5/D8, the same
  # hygiene `Vagus.API.IngressProxy.do_handle_event/2` applies), so nothing
  # leaks unless Core itself sent one.
  # Sobelow's XSS.SendResp heuristic fires on any variable body reaching
  # `send_resp/3`. Here the body is CORE's own API response, relayed verbatim
  # with Core's own content-type (typically `application/json`) — a reverse
  # proxy's one job. It is not request-derived input this module renders into
  # HTML; escaping or re-encoding it would corrupt the proxied response. The
  # chunked branches above relay the same bytes via `chunk/2`, which Sobelow
  # simply has no check for — the trust story is identical.
  # sobelow_skip ["XSS.SendResp"]
  defp send_buffered_response(acc) do
    # `acc.data` is the response chunks newest-first (O(1) prepend in the
    # `{:data, _}` buffer clause); reversed it is a correctly-ordered iolist.
    # Handed straight to `send_resp/3` (whose body is `iodata`) rather than
    # flattened with `IO.iodata_to_binary/1`: this server runs Bandit with
    # compression off (`Vagus.API.Supervisor`), so Bandit writes the iolist to
    # the socket as-is — `IO.iodata_length/1` for the content-length, no copy
    # (`deps/bandit/lib/bandit/adapter.ex` `send_resp/4`). Pre-flattening would
    # be a redundant full-body allocation on every buffered proxied response.
    body = Enum.reverse(acc.data)

    conn =
      acc.conn
      |> delete_resp_header("cache-control")
      |> delete_resp_header("vary")
      |> maybe_put_resp_header("content-type", header_value(acc.resp_headers, "content-type"))
      |> copy_allowed_response_headers(acc.resp_headers)

    send_resp(conn, acc.status, body)
  end

  defp copy_allowed_response_headers(conn, headers) do
    Enum.reduce(@response_header_allowlist, conn, fn name, conn ->
      maybe_put_resp_header(conn, name, header_value(headers, name))
    end)
  end

  defp maybe_put_resp_header(conn, _name, nil), do: conn
  defp maybe_put_resp_header(conn, name, value), do: put_resp_header(conn, name, value)

  # Mint's header names arrive already lowercased (same property
  # `Vagus.API.IngressProxy.strip_response_headers/1` relies on), so a plain
  # equality check is enough.
  defp header_value(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)
  end

  # Bare plain-text refusal, no JSON envelope — this runs outside
  # `Vagus.API.Router`, so there is no `Vagus.API.Envelope` to wrap it, and
  # upstream's own equivalents (`HTTPUnauthorized`/`HTTPNotFound`/
  # `HTTPMethodNotAllowed`/`HTTPBadGateway`) are plain aiohttp text responses
  # too. `cache-control`/`vary` are stripped here as well (audit F5/D8), same
  # as every plain-text refusal `Vagus.API.IngressProxy.send_plain/3` sends.
  defp send_plain(conn, status, body) do
    conn
    |> delete_resp_header("cache-control")
    |> delete_resp_header("vary")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
