defmodule Vagus.Core.Reserved do
  @moduledoc """
  Core's `/api/hassio*` namespace — the private Supervisor↔Core RPC surface,
  which nothing but Vagus itself may address.

  Core reserves the `hassio` prefix for the views its Supervisor integration
  registers. As of Core 2026.8.1 that is `/api/hassio/{path:.+}` (Core's
  proxy back into the Supervisor API), `/api/hassio_auth`,
  `/api/hassio_auth/password_reset`, `/api/hassio_push/panel/{addon}`,
  `/api/hassio_push/discovery/{uuid}` and
  `/api/hassio_ingress/{token}/{path:.*}` — pinned in
  `test/fixtures/core-2026.8.1-hassio-views.json`.

  They do NOT share one authorization rule, and the reservation does not
  claim they do: the two `hassio_auth` views check "are you the Supervisor"
  (`HassIOBaseAuth._check_access`) and nothing more — no owner check, no
  per-caller identity; the push views are `@require_admin`; `hassio_ingress`
  is `requires_auth = False` and authenticates by ingress session token; the
  loopback view carries its own path policy. What they share is *who they
  were built for*. Every one of them assumes its caller is either the
  Supervisor or a browser talking to Core directly — never an add-on
  arriving through the Supervisor wearing the Supervisor's identity, which
  is the one caller `Vagus.API.CoreProxy` can manufacture.

  `Vagus.API.CoreProxy` breaks that assumption. It speaks to Core with
  Vagus's own credential *on behalf of an add-on* (`Vagus.Core.Transport`'s
  socket, where the connection itself is the credential), so anything an
  add-on can address through it arrives at Core wearing the Supervisor's
  identity. `hassio_auth/password_reset` then resets any HA user's password,
  owner included, for any add-on holding `homeassistant_api: true` — the
  upstream `home-assistant/supervisor` bug fixed in August 2026.

  ## The reservation has a WS-command half too

  Core's Supervisor integration owns command domains as well as URLs
  (`homeassistant/components/hassio/websocket_api.py`), and the proxy's WS
  leg performs the identical credential swap, so the same reservation has to
  hold there — `command?/1` is that half. It is not a theoretical parallel:
  `supervisor/api` takes an arbitrary endpoint + method from the caller and
  calls the SUPERVISOR API with Core's own token, which `Vagus.API.Auth`
  resolves as `:supervisor` — the top of the `Vagus.API.Tiers` lattice, held
  by an add-on that never rose above `:default`. `supervisor/event`
  (`ws_require_user(only_supervisor=True)`) would let the same add-on forge
  Supervisor events onto Core's bus, and `hassio/update/*` (`@require_admin`)
  would let it drive Core's add-on and Core updates.

  A path-shaped rule cannot reach this: a WS caller addresses Core by typed
  command, and the frames all arrive on one already-authorized socket. So
  `Vagus.API.CoreProxy.WSBridge` applies `command?/1` per relayed frame
  instead.

  ## Why a namespace, not a list of endpoints

  Upstream's original deny listed `/…/hassio/.*` — the loopback view — and
  missed `hassio_auth` for as long as it existed, because Core grew new
  `hassio_`-prefixed views on its own release cadence and nothing on the
  Supervisor side noticed. Enumerating endpoints means tracking another
  repo's route table forever and failing open when it moves. So the rule
  here is the *reservation*: any `/api/hassio…` view is Vagus's alone,
  including ones Core has not shipped yet. (Upstream's own fix stops at
  `hassio(?:/|_)`, leaving a hypothetical `hassiofoo` open; there is no
  reason to carve that out.)

  Vagus's own calls into the namespace are legitimate and unaffected —
  `Vagus.Auth` validating an add-on's login against `/api/hassio_auth` is
  exactly what it is for. The rule is about *origin*, not about the path
  being untouchable, which is why `Vagus.Core.Transport.build/6` demands an
  origin tag rather than refusing the path outright.

  ## Two applications of one rule

  `Vagus.API.Tiers.blacklisted?/1` applies it to the Supervisor-side request
  path (`/core/api/hassio_auth` → segments after the family), refusing with
  the 403 envelope before `Vagus.API.CoreProxy` is ever constructed.
  `Vagus.Core.Transport.build/6` applies it again to the Core-side path at
  the point Vagus's credential is attached, so a future route that reaches
  Core without passing `Vagus.API.Dispatcher` cannot quietly reintroduce the
  hole. `Vagus.API.CoreProxy.WSBridge` applies `command?/1` to every relayed
  frame. `test/vagus/core/reserved_contract_test.exs` pins all three against
  the views and commands Core actually registers.
  """

  @prefix "hassio"
  @command_domains ["hassio", "supervisor"]

  @doc """
  Whether Core-side path `segments` address a reserved view.

  Segments are Core's own, `api` included (`["api", "hassio_auth",
  "password_reset"]`) — i.e. what a Supervisor-side `/core/api/...` or
  `/homeassistant/api/...` path becomes with its family segment dropped.
  """
  @spec view?([String.t()]) :: boolean()
  def view?(["api", view | _rest]), do: String.starts_with?(view, @prefix)
  def view?(_segments), do: false

  @doc """
  Whether a Core-side request path — as sent on the wire, query string and
  percent-escapes included — addresses a reserved view.

  Decoded exactly ONCE before matching, for the reason
  `Vagus.API.Dispatcher.core_proxy_blacklisted?/1` documents at length: the
  path reaches Core verbatim and aiohttp decodes it there, so
  `/api/%68assio_auth` and `/api/hassio%2fapp` are reserved paths spelled to
  evade a literal match, while `%2568` must stay `%68` on both sides.
  `URI.decode/1` is lenient (an invalid `%zz` is left alone, never raises).
  """
  @spec path?(String.t()) :: boolean()
  def path?(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> hd()
    |> URI.decode()
    |> String.split("/", trim: true)
    |> view?()
  end

  @doc """
  Whether a WebSocket command `type` names a reserved command.

  Matched on the DOMAIN — the part before the first `/`, HA's own
  `domain/action` command convention — so a future `hassio_backup/x` is
  covered while `config/auth/list` and `get_states` are untouched.

  Both domains are reserved, and the second one is the one that matters:
  `supervisor/*` (`hassio/const.py`'s `WS_TYPE_API`/`EVENT`/`SUBSCRIBE`) is
  where Core keeps the Supervisor-privileged commands, while `hassio/*` is
  its update platform (`hassio/update/addon` and friends, `@require_admin`).
  Reading the decorator without resolving the constant suggests the reverse
  — the guarded handlers are named `websocket_supervisor_*` but their type
  strings are what dispatch actually matches.

  Matched on the DECODED command string, never on the raw frame — see
  `Vagus.API.CoreProxy.WSBridge`'s `reserved_command/1` for why a substring
  pre-filter over the raw bytes would be a hole rather than an optimisation.
  """
  @spec command?(String.t()) :: boolean()
  def command?(type) when is_binary(type) do
    domain = type |> String.split("/", parts: 2) |> hd()
    Enum.any?(@command_domains, &String.starts_with?(domain, &1))
  end
end

defmodule Vagus.Core.Reserved.Error do
  @moduledoc """
  Raised when a proxied request is built against Core's reserved namespace —
  see `Vagus.Core.Reserved`.

  Unreachable in a correct system: `Vagus.API.Dispatcher` answers such a
  request with the ordinary 403 blacklist envelope long before a Finch
  request is built for it. Raising rather than returning an error is the
  point — this is the backstop for a routing regression, and a 500 with a
  stack trace in RingLogger is a louder, more diagnosable signal than a 403
  that reads like ordinary policy.
  """

  defexception [:path]

  @impl Exception
  def message(%__MODULE__{path: path}) do
    "refused to build a proxied Core request for the reserved /api/hassio* namespace: #{path}"
  end
end
