defmodule Vagus.API.Dispatcher do
  @moduledoc """
  The Bandit entry-point plug (`Vagus.API.Supervisor`'s `plug:`), split out
  from `Vagus.API.Router` so the ingress reverse-proxy leg
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B2) can run with **no**
  `Plug.Parsers` in front of it.

  ## Why the split lives here, not inside the router

  `Vagus.API.Router` runs `plug(Plug.Parsers, parsers: [:json, :urlencoded],
  pass: ["*/*"], length: 65_536)` unconditionally, before `:match`/
  `:dispatch`, for **every** request the router handles — there is no way to
  make a `Plug.Router` pipeline conditional per-route. An ingress POST (e.g.
  a firmware/config upload to an add-on's dashboard) would get parsed and
  truncated at 64KB before any ingress logic ran, and `Plug.Conn.read_body/2`
  can't be called a second time to recover the raw bytes afterwards
  (`.claude/plans/vagus-m4-ingress-watchdog/research/proxy-approach.md` §3,
  gotcha 1). The only way to give the proxied body a byte-for-byte path to
  `Finch` is to keep it away from `Plug.Parsers` entirely — which means
  deciding "router or proxy" one level up, before either pipeline runs.

  ## Routing rule

  `["ingress", token | rest]` (`token` not one of `"panels"`, `"session"`,
  `"validate_session"`) is forwarded to `Vagus.API.IngressProxy`; everything
  else — including those three literals — goes to `Vagus.API.Router`
  unchanged. The three literals are excluded because they are real router
  routes reached with the normal `X-Supervisor-Token`/`Authorization`
  header auth (§B1.4: `/ingress/session`, `/ingress/validate_session`, and
  `/ingress/panels` are explicitly **not** in the real Supervisor's
  `no_security_check` bypass list — only the per-request proxy path
  `/ingress/{token}/.*` is). There is no real collision risk either way: a
  genuine ingress token is a 43-character URL-safe-base64 string
  (`Vagus.Addon.State`'s `generate_ingress_token/0`, 32 random bytes with no
  padding), so it can never literally equal one of these three short
  literals.

  `rest` may be empty — `GET /ingress/<token>/` arrives as
  `path_info == ["ingress", token]`, which still matches this clause and is
  forwarded with `rest == []` (the proxy builds the upstream root path `/`
  from that, see `Vagus.API.IngressProxy`).

  ## The exploit filter runs here too, for the same reason

  `Vagus.API.ExploitFilter` (audit B6) is upstream's `aiohttp` middleware
  `SecurityMiddleware.block_bad_requests`, which — being middleware — covers
  every request the process answers. Running the equivalent check as a
  router plug would leave `/ingress/{token}/…` unfiltered again, the same
  shape of gap the source allowlist above was moved here to close. So it
  runs in `call/2`, after the source check and before the ingress/router
  split, on both `request_path` and `query_string`.

  ## Filtered requests are counted, not logged one-per-request (security-phase7.md H1)

  `ExploitFilter` runs pre-auth, on attacker-chosen bytes, at a rate the
  caller fully controls — exactly the primitive `SourceGuard.record_refusal/1`
  already declines to hand out for refusals, for the same reason: a
  `Logger.warning` per blocked request would let an unauthenticated caller
  push real evidence out of `RingLogger`'s fixed-size ring (the only
  forensic record on a Nerves device) by repeating the request, and the
  interpolated bytes are the caller's own choice, so it could also plant a
  misleading line or ANSI/control bytes a serial-console `RingLogger` read
  would interpret. So a block is *counted*, via `SourceGuard.record_filtered/2`
  — mirroring `record_refusal/1` exactly — with the sample sanitized first
  (`sanitize_for_log/1`: truncated to 120 bytes, control bytes stripped)
  so neither the count nor the one retained sample can be abused the way a
  raw per-request log line could.

  The one exception is when `SourceGuard.enabled?/0` is false — the
  `:host`/`:test`/dev configuration. There, the counter GenServer isn't
  running (`SourceGuard.start_link/1` returns `:ignore`) and there is no
  fixed-size ring to protect either, but there IS a developer at a terminal
  who needs to know why a request just got a bare 400 — so that path keeps a
  per-request `Logger.warning`, still built from the sanitized sample, never
  the raw path/query. This asymmetry is deliberate, not an oversight: it is
  keyed on whether the ring-eviction primitive exists to protect, not on
  whether logging in general is a good idea. Upstream logs one line per
  blocked request unconditionally, but upstream logs into a container's
  rotated journald, never a fixed-size ring that is the only forensic record
  on the device.
  """

  @behaviour Plug

  require Logger

  alias Vagus.API.{ExploitFilter, IngressProxy, Router, SourceGuard}

  # `Plug.Router.init/1`'s default implementation is the identity function
  # (no state to precompute); `IngressProxy.init/1` is likewise a plain
  # pass-through. Resolving both once at compile time keeps `call/2` free of
  # any per-request `init/1` work.
  @router_opts Router.init([])
  @proxy_opts IngressProxy.init([])

  @impl Plug
  def init(opts), do: opts

  # The source allowlist lives HERE, not in the router, because this is what
  # Bandit is given (`Vagus.API.Supervisor`'s `plug:`) and the ingress clause
  # below never reaches the router's pipeline. A guard installed as a router
  # plug protects `/supervisor/ping` and leaves `/ingress/{token}/…` — an
  # authenticated-by-cookie reverse proxy into an add-on's web UI, with a
  # WebSocket upgrade — open to the whole LAN. That was the shape of this
  # code for one commit; the device said `403` on the router path and `401`
  # on the ingress path, which is how it was caught.
  #
  # Deciding it before either pipeline means a refused caller reaches neither
  # `Plug.Parsers` nor the proxy's body streaming.
  @impl Plug
  def call(conn, opts) do
    if SourceGuard.allowed?(conn.remote_ip) do
      filter(conn, opts)
    else
      refuse(conn)
    end
  end

  # Path and query are checked separately, like upstream's two
  # `FILTERS.search` calls, so the log line says which half of the request
  # tripped it. This runs before the ingress/router split — see the
  # moduledoc — so a blocked ingress request never reaches
  # `Vagus.API.IngressProxy`'s body streaming, and a blocked router request
  # never reaches `Plug.Parsers`.
  defp filter(conn, opts) do
    cond do
      ExploitFilter.harmful_path?(conn.request_path) ->
        report_filtered(:path, conn.request_path)
        block(conn)

      ExploitFilter.harmful_query?(conn.query_string) ->
        report_filtered(:query, conn.query_string)
        block(conn)

      true ->
        dispatch(conn, opts)
    end
  end

  # See the moduledoc's "Filtered requests are counted, not logged
  # one-per-request" section — this is the one call site for both branches.
  defp report_filtered(kind, value) do
    sample = sanitize_for_log(value)

    if SourceGuard.enabled?() do
      SourceGuard.record_filtered(kind, sample)
    else
      Logger.warning(
        "Vagus.API.Dispatcher: filtered a potential harmful request (#{kind}): " <> sample
      )
    end
  end

  # Bounds what an attacker-chosen path/query byte can cost a log line or
  # `SourceGuard`'s GenServer state before it ever reaches either: truncated
  # to 120 bytes (generous for diagnosing which shape tripped the filter,
  # bounded so a single sample can't grow unreasonably), then stripped of C0
  # and DEL control bytes. `String.printable?/1` is deliberately not used for
  # the control-byte check — same reasoning as `Vagus.API.Router`'s
  # `@control_char_re` (security-phase6.md W1): that Unicode data set treats
  # several C0 codes, notably ESC (the ANSI-escape lead byte), as
  # "printable", which is exactly the injection vector this exists to close
  # — an attacker-chosen ESC sequence read back over a serial-console
  # `RingLogger` tail would be interpreted, not merely displayed oddly.
  # `Regex.replace/4` on a plain (non-`u`) pattern operates on raw bytes, the
  # same property `ExploitFilter`'s own moduledoc relies on for its
  # invalid-UTF-8 subjects — this can't raise on a non-UTF-8 path either.
  @control_byte_re ~r/[\x00-\x1F\x7F]/
  defp sanitize_for_log(value) do
    value
    |> binary_part(0, min(byte_size(value), 120))
    |> then(&Regex.replace(@control_byte_re, &1, ""))
  end

  defp dispatch(%Plug.Conn{path_info: ["ingress", token | _rest]} = conn, _opts)
       when token not in ["panels", "session", "validate_session"] do
    IngressProxy.call(conn, @proxy_opts)
  end

  defp dispatch(conn, _opts) do
    Router.call(conn, @router_opts)
  end

  # Bare 403, no body: a caller we won't answer doesn't get told why. The
  # refusal is *counted* rather than logged here — `SourceGuard` folds them
  # into one periodic line, so a LAN attacker can't push real evidence out of
  # the log ring by hammering the port.
  defp refuse(conn) do
    SourceGuard.record_refusal(conn.remote_ip)

    conn |> Plug.Conn.send_resp(403, "") |> Plug.Conn.halt()
  end

  # Bare plain-text 400, no JSON envelope: this runs pre-router (same
  # convention as `refuse/1`'s bare 403), and mirrors upstream's aiohttp
  # `HTTPBadRequest`, which is plain text too.
  defp block(conn) do
    conn |> Plug.Conn.send_resp(400, "Bad Request") |> Plug.Conn.halt()
  end
end
