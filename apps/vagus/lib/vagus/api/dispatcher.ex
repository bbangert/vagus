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
  """

  @behaviour Plug

  alias Vagus.API.{IngressProxy, Router, SourceGuard}

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
      dispatch(conn, opts)
    else
      refuse(conn)
    end
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
end
