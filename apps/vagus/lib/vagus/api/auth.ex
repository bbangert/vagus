defmodule Vagus.API.Auth do
  @moduledoc """
  Token auth + caller resolution for the Supervisor-API emulator.

  Every request must carry a token — either `Authorization: Bearer <token>` or
  `X-Supervisor-Token: <token>` (bashio/add-ons use the latter) — with two
  exceptions: the icon/logo GETs Core's proxy forwards with no `Authorization`
  header at all, and `GET /supervisor/ping` (upstream's `no_security_check`
  lists it literally — `security.py`'s `_V1_PATTERNS.no_security_check`
  alternation — so it is answered before token validation and
  `request[REQUEST_FROM]` is left `None`). Both carve-outs are recognised by
  this module itself via `unauthenticated?/1`.

  That decision is deliberately made HERE and nowhere else. An earlier
  revision had the router set a `conn.assigns[:auth_bypass]` flag that this
  module honored; assigns are a channel any plug can write, so trusting one
  at the auth boundary meant a future plug could disable authentication for
  any route by accident. There is now no flag to set.

  Before any of that, `call/2` checks upstream's `BLACKLIST` — every caller,
  Core included, refused with 403 on `/core/api/hassio/…` and
  `/homeassistant/api/hassio/…` regardless of token or role. See
  `Vagus.API.Tiers.blacklisted?/1`'s doc for why this predates token
  resolution and is not expressed as a tier requirement.

  The token is resolved to a **caller**, assigned on `conn.assigns.caller`, so
  add-on-facing endpoints can authorize:

    * the token `Vagus.API.Token` resolves (constant-time
      `Plug.Crypto.secure_compare/2`, checked first so Core's polling never
      touches the registry) → `:supervisor`;
    * a token registered in `Vagus.Addon.Registry` (a running add-on's
      per-start token) → `{:addon, identity}`;
    * otherwise a 401 error envelope, halted before dispatch.

  ## The role gate

  An authenticated caller is then graded against `Vagus.API.Tiers`: its tier
  is assigned on `conn.assigns.tier`, and a path demanding more than the
  caller holds is refused with 403 (upstream raises `HTTPForbidden`) before
  `:match` ever runs.

  That check lives here rather than in a second router plug for the same
  reason the icon/logo carve-out does. This module is the authorisation
  boundary; splitting reachability across two plugs means two places to get it
  wrong, and the audit that produced this gate found exactly that failure —
  `supervisor_only/2` was applied by hand and 26 routes never got it. The
  *table* is separate and diffable (`Vagus.API.Tiers`); applying it is not.

  `conn.assigns.caller` is unchanged. Every existing handler guard still runs
  — the gate is a coarse pre-filter, and the per-caller grants
  (`services_role`, `discovery`, `resolve_info_slug/2`) remain the finer rule.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Vagus.Addon.Registry
  alias Vagus.API.{Envelope, Tiers, Token}

  @impl Plug
  def init(opts), do: opts

  # Kinds served without a token. See `unauthenticated?/1`.
  @unauthenticated_asset_kinds ~w(icon logo)

  @impl Plug
  def call(conn, opts)

  def call(%Plug.Conn{path_info: path_info} = conn, _opts) do
    cond do
      Tiers.blacklisted?(path_info) -> refuse_blacklisted(conn)
      unauthenticated?(conn) -> conn
      true -> authenticate(conn)
    end
  end

  @doc """
  Whether `conn` is one of the two GETs that must be served with no token at
  all: an add-on's icon/logo, or `/supervisor/ping`.

  Computed here rather than read from an assign set by an earlier plug. An
  assign is a channel any plug in the pipeline could write, so trusting one
  at the auth boundary would mean a future plug could disable authentication
  for *any* route by accident. Nothing outside this module decides that a
  request skips auth.

  The icon/logo exemption is forced, not chosen: Core's proxy forwards these
  GETs with no `Authorization` header at all
  (`homeassistant/components/hassio/http.py` — when `PATHS_NO_AUTH` matches,
  the branch short-circuits before the header is set, for admins too), and
  Supervisor skips its own middleware for them (`no_security_check` splices
  in `_V1_FRONTEND_PATHS`, i.e. `|/(store/)?addons/<RE_SLUG>/(logo|icon)`).
  Requiring a token here means permanently broken images, whatever the
  frontend does.

  `/supervisor/ping` is exempted for the same upstream reason, via a
  different member of the same set: it is listed literally in
  `no_security_check` (`security.py` L166,
  `_V1_PATTERNS.no_security_check`'s alternation), so upstream answers it
  before `token_validation` runs at all and leaves `request[REQUEST_FROM]`
  as `None`. Audit B1: Vagus previously routed this through the normal
  token gate and 401ed a caller pinging before it holds one — a health-check
  probe, a supervised-installer script, or `bashio::supervisor.ping` from an
  add-on with `hassio_api: false`, all of which the real Supervisor answers
  200. Because this short-circuits *before* token handling, exactly like
  upstream, a ping that DOES carry a token is not graded either — no tier
  check runs for it, matching `request[REQUEST_FROM] = None` rather than
  resolving a caller. This does not widen LAN exposure: `Vagus.API.SourceGuard`
  still fronts every route ahead of this plug, ping included.

  Deliberately narrow: GET only, exact `path_info` match (never a regex over
  the raw path), and for the asset case a slug that passes
  `Vagus.Addon.Config.valid_slug?/1`. Core itself 405s a non-GET on either
  family of paths, so the method restriction matches upstream rather than
  merely being cautious.
  """
  @spec unauthenticated?(Plug.Conn.t()) :: boolean()
  def unauthenticated?(%Plug.Conn{method: "GET", path_info: ["supervisor", "ping"]}), do: true

  def unauthenticated?(%Plug.Conn{method: "GET", path_info: path_info}),
    do: asset_path?(path_info)

  def unauthenticated?(%Plug.Conn{}), do: false

  defp asset_path?(["addons", slug, kind]), do: asset?(kind, slug)
  defp asset_path?(["store", "addons", slug, kind]), do: asset?(kind, slug)
  defp asset_path?(_path_info), do: false

  defp asset?(kind, slug),
    do: kind in @unauthenticated_asset_kinds and Vagus.Addon.Config.valid_slug?(slug)

  # Mirrors upstream's `_LOGGER.error("%s is blacklisted!", request.path)`,
  # but deliberately without the path: an attacker-controlled path is exactly
  # the per-request byte string phase 7 identified as a pre-auth
  # RingLogger-flush primitive (`Vagus.API.SourceGuard`'s `record_refusal/1`
  # doc; `Vagus.API.Dispatcher`'s `report_filtered/2` sanitizes for the same
  # reason before it will log one). `Dispatcher`'s sanitizer is private to
  # that module and reused nowhere else, so rather than exporting it for one
  # call site, this logs a static message — which of the two blacklisted
  # patterns matched carries no more information than the 403 itself already
  # gives a prober, so nothing is lost by leaving it out.
  defp refuse_blacklisted(conn) do
    Logger.error("Vagus.API.Auth: request path is blacklisted")
    Envelope.send_error(conn, "unauthorized", 403)
  end

  defp authenticate(conn) do
    case token(conn) do
      nil -> unauthorized(conn)
      token -> resolve(conn, token)
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        token

      _other ->
        case get_req_header(conn, "x-supervisor-token") do
          [token | _] -> token
          [] -> nil
        end
    end
  end

  defp resolve(conn, token) do
    cond do
      Plug.Crypto.secure_compare(token, Token.get()) ->
        authorize(conn, :supervisor)

      match?({:ok, _}, addon_identity(token)) ->
        {:ok, identity} = addon_identity(token)
        authorize(conn, {:addon, identity})

      true ->
        unauthorized(conn)
    end
  end

  # Grade the caller, record both halves on the conn, and refuse a path it
  # cannot reach. `:tier` is assigned even on the refusal path so a handler or
  # a test observing a halted conn sees why.
  defp authorize(conn, caller) do
    tier = Tiers.caller_tier(caller)

    conn =
      conn
      |> assign(:caller, caller)
      |> assign(:tier, tier)

    if Tiers.allows?(tier, Tiers.required(conn.path_info)) do
      conn
    else
      # 403, matching upstream's `HTTPForbidden` for a token that resolves but
      # has no role for the path (`security.py`'s final `raise`), and matching
      # the router's own wrong-caller shape (`supervisor_only/2`).
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  # Registry may be absent in narrow test setups — treat as "no add-on tokens".
  defp addon_identity(token) do
    if Process.whereis(Registry), do: Registry.identity_for_token(token), else: :error
  end

  defp unauthorized(conn), do: Envelope.send_error(conn, "unauthorized", 401)
end
