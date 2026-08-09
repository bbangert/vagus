defmodule Vagus.API.Tiers do
  @moduledoc """
  The authorisation ladder: which caller may reach which path.

  This is the emulator's mirror of `supervisor/api/middleware/security.py`
  (upstream `2026.07.5`, V1 pattern set — Vagus serves the V1 surface). It
  exists as a **table** rather than as a guard inside each handler for one
  reason: the 2026-07-29 audit found 26 routes that were admin-tier to any
  installed add-on purely because `Vagus.API.Router`'s `supervisor_only/2` is
  applied by hand and those routes never got it. A hand-placed guard cannot be
  diffed against upstream; `@table` below can be read side-by-side with
  `security.py`'s alternatives, and a route added later that nobody thinks
  about falls through to `:admin` — closed — instead of open.

  ## The two halves

  `caller_tier/1` turns the caller `Vagus.API.Auth` resolved into a tier.
  `required/1` turns a request path into the tier that path demands.
  `allows?/2` decides. `Vagus.API.Auth` is the only caller of all three.

  ## Tiers

  Upstream's `role_access` map is a lattice, not a line — `ROLE_BACKUP` and
  `ROLE_HOMEASSISTANT` are siblings, both above `ROLE_DEFAULT` and both below
  `ROLE_MANAGER`:

      :supervisor            Core's own token; above everything, never role-checked
      :admin                 role_access[admin] = `.*`
      :manager               role_access[manager]
      :backup  :homeassistant  role_access[backup] / role_access[homeassistant]
      :default               role_access[default] = `^(?:|/.+/info)$`
      :none                  an add-on with `hassio_api: false`

  `:none` has no upstream name. Upstream keeps `access_hassio_api` and
  `hassio_role` as separate checks (`security.py` L360: `elif app and
  app.access_hassio_api`), but the only paths reachable *without*
  `access_hassio_api` are the `api_bypass` ones, and those are tier-independent
  — so an add-on that never asked for API access is exactly "satisfies
  `:bypass`, nothing else". Collapsing it into the tier keeps
  `conn.assigns.tier` honest: a `hassio_api: false, hassio_role: admin` add-on
  is not an admin caller, and nothing downstream may treat it as one.

  ## Requirements

  Same vocabulary, plus `:bypass` at the bottom and `:supervisor` at the top:

    * `:bypass` — upstream's `api_bypass`: **any** installed add-on's token,
      even one with `hassio_api: false`. The handler does its own finer check
      (`/services`, `/discovery`, `/auth` all grant per-caller).
    * `:supervisor` — Core only. This is the `:supervisor` case of the
      router's `supervisor_only/2`, and covers the ~40 routes where Vagus is
      deliberately **stricter** than upstream (install/update/lifecycle-by-slug,
      core lifecycle, changelog/documentation). The audit's standing rule is
      that stricter is fine; those stay as they were.

  ## Method is deliberately not consulted

  Upstream's regexes are matched against `request.path` alone —
  `token_validation` never looks at `request.method`. Adding a method
  dimension here would be a divergence that reads like a hardening, so the
  table is path-only and the handlers keep whatever method-specific rules they
  already had.

  ## Pattern language

  A pattern is a list of segments matched against `conn.path_info`:

    * a binary — that literal segment
    * `:_` — exactly one segment, any value
    * `:+` — one or more segments
    * `:*` — zero or more segments

  `:+`/`:*` backtrack, so `[:+, "info"]` is upstream's `/.+/info`.

  First match wins, so ordering is meaningful and the table is grouped
  accordingly: bypass, then Vagus's stricter-than-upstream overrides, then
  `/.+/info`, then the role families.
  """

  alias Vagus.Core.Reserved

  @type tier ::
          :supervisor | :admin | :manager | :backup | :homeassistant | :default | :none

  @type requirement ::
          :bypass | :default | :homeassistant | :backup | :manager | :admin | :supervisor

  @type caller :: :supervisor | {:addon, map()}

  # fmt: mirrors `security.py`'s own `# fmt: off` block. Read this beside it.
  @table [
    # -- api_bypass (security.py L95-104) -------------------------------------
    # `^(?:|/addons/self/(?!security|update)[^/]+|/addons/self/options/config
    #    |/info|/services.*|/discovery.*|/auth)$`
    #
    # Any installed add-on's token, `hassio_api` or not. The two negative
    # lookaheads come first because first-match-wins is how they are expressed
    # here; both land on `:supervisor` rather than falling through, since
    # Vagus keeps self-update supervisor-only (see `handle_update/2`) and has
    # no `/addons/{slug}/security` route at all.
    {["addons", "self", "security"], :supervisor},
    {["addons", "self", "update"], :supervisor},
    # `[^/]+` is a *single* segment: `/addons/self/logs` is bypassed,
    # `/addons/self/logs/latest` is not (it needs manager, below). That
    # asymmetry is upstream's, and closing it is audit finding F8.
    {["addons", "self", "options", "config"], :bypass},
    # The bypassable third segments are ENUMERATED, not wildcarded.
    #
    # Upstream writes this as a negative lookahead over `[^/]+`, and the
    # obvious transcription — `{["addons", "self", :_], :bypass}` — is wrong
    # here in a way that took a review to catch. A wildcard swallows every
    # later `["addons", :_, X]` row whenever the slug is the literal `self`,
    # so `/addons/self/{install,changelog,documentation,sys_options}` graded
    # `:bypass` while the block below claimed `:supervisor`. Nothing was
    # reachable, because those handlers still carry their own
    # `caller == :supervisor` check — which is precisely the problem: the
    # table had quietly delegated back to the hand-placed guard whose absence
    # on 26 routes was this whole plan's root cause.
    #
    # Enumerated, an `/addons/self/X` nobody thought about falls through to
    # `["addons", :_, :+]` ⇒ `:manager` — closed, the same invariant every
    # other row keeps. Upstream serves more of these than Vagus does
    # (`rebuild`, `stdin`, …); when a route for one lands, add it here
    # deliberately rather than discovering it was already open.
    {["addons", "self", "info"], :bypass},
    {["addons", "self", "options"], :bypass},
    {["addons", "self", "logs"], :bypass},
    {["addons", "self", "stats"], :bypass},
    {["addons", "self", "start"], :bypass},
    {["addons", "self", "stop"], :bypass},
    {["addons", "self", "restart"], :bypass},
    {["addons", "self", "uninstall"], :bypass},
    {["info"], :bypass},
    {["services", :*], :bypass},
    {["discovery", :*], :bypass},
    {["auth"], :bypass},

    # -- no_security_check ----------------------------------------------------
    # `/supervisor/ping` WAS here as `:bypass` (audit B1's interim state: still
    # token-gated, but not role-graded on top). Phase 8 made it genuinely
    # token-free — `Vagus.API.Auth.unauthenticated?/1` now short-circuits it
    # before this table is ever consulted, same as the icon/logo GETs, the
    # other `no_security_check` member Vagus serves — so the row is DELETED
    # rather than left behind: a route answered pre-table has no tier to pin,
    # and a leftover `:bypass` entry reads as "still needs a token, just no
    # role", which is no longer true. If you are diffing this file against
    # `security.py` and expected to find `/supervisor/ping` here, it is not
    # missing — see `Vagus.API.Auth`'s moduledoc instead.

    # -- Vagus stricter than upstream: supervisor-only (deliberate) -----------
    # Every entry here is a route the router already gated with
    # `supervisor_only/2` or an inline `caller == :supervisor`. Upstream would
    # admit `ROLE_MANAGER`; the audit's standing rule is that stricter is
    # fine, so these keep the tier they shipped with. They are listed rather
    # than left to fall through because the family rules below would otherwise
    # widen them to `:manager`.
    {["os", "datadisk", "list"], :supervisor},
    {["host", "disks", "default", "usage"], :supervisor},
    {["store", "addons", :_, "changelog"], :supervisor},
    {["store", "addons", :_, "documentation"], :supervisor},
    {["store", "addons", :_, "install"], :supervisor},
    {["store", "addons", :_, "update", :*], :supervisor},
    {["addons", :_, "changelog"], :supervisor},
    {["addons", :_, "documentation"], :supervisor},
    {["addons", :_, "install"], :supervisor},
    {["addons", :_, "update"], :supervisor},
    # `/addons/{slug}/options/validate` is two segments, so upstream's bypass
    # never covered it; Vagus keeps it supervisor-only alongside the
    # lifecycle routes. `/addons/self/options` (one segment) IS bypassed
    # above — upstream's own asymmetry between saving and dry-running.
    {["addons", :_, "options", "validate"], :supervisor},
    {["addons", :_, "start"], :supervisor},
    {["addons", :_, "stop"], :supervisor},
    {["addons", :_, "restart"], :supervisor},
    {["addons", :_, "uninstall"], :supervisor},
    {["addons", :_, "options"], :supervisor},
    {["core", "start"], :supervisor},
    {["core", "stop"], :supervisor},
    {["core", "restart"], :supervisor},
    {["core", "rebuild"], :supervisor},
    {["core", "check"], :supervisor},
    {["core", "update"], :supervisor},
    {["homeassistant", "start"], :supervisor},
    {["homeassistant", "stop"], :supervisor},
    {["homeassistant", "restart"], :supervisor},
    {["homeassistant", "rebuild"], :supervisor},
    {["homeassistant", "check"], :supervisor},
    {["homeassistant", "update"], :supervisor},

    # -- core_only (security.py L106-110) -------------------------------------
    # `/addons/{slug}/sys_options`. Vagus does not serve it; the entry keeps
    # the catch-all from ever handing it to an admin-role add-on if it lands.
    {["addons", :_, "sys_options"], :supervisor},

    # -- role_access[default] (security.py L111-115) --------------------------
    # `^(?:|/.+/info)$` — note `.+` spans `/`, so `/network/interface/eth0/info`
    # matches. Placed after the overrides above so a supervisor-only route
    # ending in `info` could never be widened by it.
    {[], :default},
    {[:+, "info"], :default},

    # -- role_access[homeassistant] (security.py L116-122) --------------------
    # `/core/.+` and `/homeassistant/.+`. Everything in these two families that
    # Vagus does not hold at `:supervisor` above — `/core/options`,
    # `/core/logs*`, `/core/stats`, `/homeassistant/options`,
    # `/homeassistant/logs*`. `ROLE_MANAGER` also matches them, which
    # `allows?/2`'s lattice handles.
    {["core", :+], :homeassistant},
    {["homeassistant", :+], :homeassistant},

    # -- role_access[backup] (security.py L123-128) ---------------------------
    # `/backups.*` — note `.*`, so bare `/backups` matches too. `ROLE_MANAGER`
    # matches the same alternative. `/backups/info` and
    # `/backups/{slug}/info` already matched `/.+/info` above, exactly as they
    # do upstream.
    {["backups", :*], :backup},

    # -- role_access[manager] (security.py L129-157) --------------------------
    # One entry per upstream alternative, in upstream's order. Families Vagus
    # does not serve (`/cli`, `/docker`, `/observer`, `/security`,
    # `/snapshots`) are kept so the diff stays one-to-one and a future route
    # lands on the right tier by default.
    {["addons"], :manager},
    {["addons", "reload"], :manager},
    # `/addons/{slug}/(?!security).+` — the negative lookahead is the
    # `["addons", :_, "security"]` entry at the top of the table.
    {["addons", :_, "security", :*], :admin},
    {["addons", :_, :+], :manager},
    {["audio", :+], :manager},
    {["auth", "cache"], :manager},
    {["available_updates"], :manager},
    {["cli", :+], :manager},
    {["dns", :+], :manager},
    {["docker", :+], :manager},
    {["jobs", :+], :manager},
    {["hardware", :+], :manager},
    {["host", :+], :manager},
    {["mounts", :*], :manager},
    {["multicast", :+], :manager},
    {["network", :+], :manager},
    {["observer", :+], :manager},
    # `/os/(?!datadisk/wipe).+`
    {["os", "datadisk", "wipe"], :admin},
    {["os", :+], :manager},
    {["refresh_updates"], :manager},
    {["resolution", :+], :manager},
    {["security", :+], :manager},
    {["snapshots", :*], :manager},
    {["store", :*], :manager},
    {["supervisor", :+], :manager}

    # -- role_access[admin] = `.*` --------------------------------------------
    # Everything unlisted, via `required/1`'s fallback. That is upstream's
    # behaviour and it is also the safe default for a route added tomorrow:
    # `/ingress/panels` (audit A5) and `/reload_updates` are admin-tier here
    # for exactly this reason — neither appears in the V1 manager list.
  ]

  # `security.py`'s `BLACKLIST`, checked before EVERYTHING else — before
  # `no_security_check`, before `token_validation`'s Core-token branch, before
  # a caller is even identified:
  #
  #     BLACKLIST: Final = re.compile(
  #         r"^(?:/v2)?(?:"
  #         r"|/homeassistant/api/hassio(?:/|_).*"
  #         r"|/core/api/hassio(?:/|_).*"
  #         r")$"
  #     )
  #     ...
  #     if BLACKLIST.match(request.path):
  #         _LOGGER.error("%s is blacklisted!", request.path)
  #         raise HTTPForbidden
  #
  # Both families are Supervisor's proxy *into* Core's REST API, and Core's
  # `/api/hassio…` views are the private Supervisor↔Core RPC surface on the
  # far side — reached through this proxy, they arrive wearing Vagus's own
  # Supervisor identity. `Vagus.Core.Reserved`'s moduledoc has the full
  # argument, including why this is expressed as a namespace reservation
  # rather than the endpoint list upstream shipped (that list said `hassio/`
  # only, and silently missed `hassio_auth/password_reset` — an add-on →
  # owner account takeover, fixed upstream in August 2026).
  #
  # `:v2` prefixing is upstream's; Vagus serves only the V1 surface (see this
  # module's moduledoc), so `path_info` never carries a leading `v2` segment
  # and the match below omits it — nothing is served under it to blacklist.
  @proxy_families ["core", "homeassistant"]

  @doc """
  Whether `path_info` is one of upstream's `BLACKLIST` paths — refused for
  EVERY caller, Core included, before a token is even read.

  Deliberately a separate predicate, not a `requirement` fed through
  `allows?/2`. `allows?(:supervisor, _requirement)` is that function's FIRST
  clause — any requirement is satisfied by the supervisor caller — so a deny
  expressed as a requirement would need its check inserted ABOVE that clause,
  a lattice-ordering detail a future edit could reorder by accident without
  the compiler ever complaining. Upstream itself checks `BLACKLIST` before
  `token_validation` identifies a caller at all, i.e. structurally before the
  lattice exists for this request; a separate predicate, checked first by
  `Vagus.API.Auth.call/2`, is the same shape and cannot be weakened by a
  change to `allows?/2`'s clause order.

  Dropping the family segment is what turns a Supervisor-side path into the
  Core-side one `Vagus.Core.Reserved.view?/1` judges: `/core/api/hassio_auth`
  and `/homeassistant/api/hassio_auth` are both Core's `/api/hassio_auth`.
  """
  @spec blacklisted?([String.t()]) :: boolean()
  def blacklisted?([family | core_path]) when family in @proxy_families do
    Reserved.view?(core_path)
  end

  def blacklisted?(path_info) when is_list(path_info), do: false

  @doc """
  The tier a request path demands.

  Unlisted paths are `:admin`, mirroring `role_access[ROLE_ADMIN] = .*` and
  keeping a newly-added route closed rather than open.
  """
  @spec required([String.t()]) :: requirement()
  def required(path_info) when is_list(path_info) do
    Enum.find_value(@table, :admin, fn {pattern, requirement} ->
      if match_path?(pattern, path_info), do: requirement
    end)
  end

  @doc """
  The tier a resolved caller holds.

  `hassio_api: false` is `:none` regardless of the declared `hassio_role` — see
  the moduledoc. Both fields are read with a default so an identity built
  before they existed (or by hand in a narrow test) grades as the most
  restrictive thing it could be, never the least.
  """
  @spec caller_tier(caller()) :: tier()
  def caller_tier(:supervisor), do: :supervisor

  def caller_tier({:addon, identity}) when is_map(identity) do
    if Map.get(identity, :hassio_api, false) do
      role_tier(Map.get(identity, :hassio_role, "default"))
    else
      :none
    end
  end

  @doc """
  Whether `tier` satisfies `requirement`.

  The lattice, not a line: `:backup` and `:homeassistant` are siblings — each
  is above `:default` and below `:manager`, and neither implies the other.
  """
  @spec allows?(tier(), requirement()) :: boolean()
  # Core's own token is never role-checked (security.py L338-341 sets
  # `request_from` and every later branch is an `elif`).
  def allows?(:supervisor, _requirement), do: true
  # api_bypass runs before `access_hassio_api`, so even `:none` passes.
  def allows?(_tier, :bypass), do: true
  # Nothing below `:supervisor` reaches a supervisor-only route.
  def allows?(_tier, :supervisor), do: false
  def allows?(:admin, _requirement), do: true
  def allows?(:manager, requirement), do: requirement in ~w(manager backup homeassistant default)a
  def allows?(:backup, requirement), do: requirement in ~w(backup default)a
  def allows?(:homeassistant, requirement), do: requirement in ~w(homeassistant default)a
  def allows?(:default, requirement), do: requirement == :default
  def allows?(:none, _requirement), do: false

  @doc """
  May this caller see an add-on's effective `options` in an info payload?

  Upstream's `expose_options` (`supervisor/api/apps.py::info_data`, "User
  options may contain secrets"): Home Assistant Core and other non-app
  internals, the add-on itself, or an add-on holding the manager/admin role.
  Everyone else reads `%{}` — the key stays, empty, which is upstream's shape
  and what the frontend's config form expects to find.

  Lives here, taking explicit arguments, rather than as a private predicate in
  the router — **because in Vagus the false branch is currently unreachable**.
  `Vagus.API.Router`'s `resolve_info_slug/2` refuses an add-on any slug but its
  own, so no caller ever reaches another add-on's info to have its options
  redacted (Vagus is stricter than upstream, which admits any `/.+/info` at
  default role). A rule that no route can exercise is a rule no end-to-end test
  can pin: deleting it outright broke nothing. Exposed and unit-tested instead,
  so widening that guard later cannot silently take the redaction with it.
  """
  @spec expose_options?(caller(), tier(), String.t()) :: boolean()
  def expose_options?(:supervisor, _tier, _addon_slug), do: true
  def expose_options?({:addon, %{slug: slug}}, _tier, slug), do: true
  def expose_options?({:addon, _identity}, tier, _addon_slug), do: tier in [:manager, :admin]

  defp role_tier("admin"), do: :admin
  defp role_tier("manager"), do: :manager
  defp role_tier("backup"), do: :backup
  defp role_tier("homeassistant"), do: :homeassistant
  # `Vagus.Addon.Config` already clamps `hassio_role` to the five upstream
  # values with `"default"` as the fallback; this clause is the same fallback
  # for an identity that never went through it.
  defp role_tier(_other), do: :default

  # `:*`/`:+` backtrack (`match_suffix?/2` tries every split), which is what
  # makes `[:+, "info"]` behave like upstream's `/.+/info` rather than only
  # matching a two-segment path.
  defp match_path?([], []), do: true
  defp match_path?([], _segments), do: false
  defp match_path?([:* | pattern], segments), do: match_suffix?(pattern, segments)
  defp match_path?([:+ | pattern], [_segment | rest]), do: match_suffix?(pattern, rest)
  defp match_path?([:+ | _pattern], []), do: false
  defp match_path?([:_ | pattern], [_segment | rest]), do: match_path?(pattern, rest)
  defp match_path?([:_ | _pattern], []), do: false

  defp match_path?([literal | pattern], [literal | rest]) when is_binary(literal),
    do: match_path?(pattern, rest)

  defp match_path?(_pattern, _segments), do: false

  # Does `pattern` match `segments` or any suffix of it?
  defp match_suffix?(pattern, segments) do
    match_path?(pattern, segments) or
      case segments do
        [] -> false
        [_dropped | rest] -> match_suffix?(pattern, rest)
      end
  end
end
