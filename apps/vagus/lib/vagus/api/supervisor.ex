defmodule Vagus.API.Supervisor do
  @moduledoc """
  Isolated supervisor for the Supervisor-API emulator's HTTP surface.

  Holds the `Bandit` server (`plug: Vagus.API.Dispatcher` — see that module
  for why the entry point is a small dispatcher rather than
  `Vagus.API.Router` directly, `docs/contract-2026.7-m4b-ingress-watchdog.md`
  §B2) under its own bounded restart budget, mirroring
  `Vagus.Engine.DaemonSupervisor`'s isolation rationale: a Bandit
  crash-loop must never escalate past this subtree and bring down the rest
  of `Vagus.Supervisor`.

  Bandit itself is *not* a static child here: on target it binds an address
  (`172.30.32.2`) that does not exist until balena-engine has created the
  hassio bridge, so it is started — with retries — by `Vagus.API.Listener`
  into `Vagus.API.ListenerSupervisor`. See that module for the race.

  Also holds `Vagus.Ingress.Finch`, the connection pool the ingress
  reverse-proxy leg (`Vagus.API.IngressProxy`) uses to reach add-on
  containers — started before Bandit so the pool exists the moment the
  first proxied request can arrive. `pools: %{default: [size: 4]}`: a small
  pool deliberately, matching the 1GB-device RAM discipline the rest of
  this module documents; ingress traffic is a handful of panel
  iframes/WS-adjacent polls at a time, not a fan-out workload.

  RAM discipline: `thousand_island_options: [num_acceptors: 2, read_timeout:
  900_000]` — no per-request processes or Registry/ETS are needed for this
  static-data Phase 2 surface. The 15-minute `read_timeout` (Thousand
  Island's default is 60s) is set deliberately, not left to coincidentally
  match anything: it mirrors the ingress session's own 15-minute sliding
  idle window (`Vagus.Ingress` §B1.2), so a legitimately idle-but-open
  ingress connection (a long-polling panel asset, a slow log tail) is never
  killed by the transport layer before the session itself would time the
  client out (research doc §3 gotcha 2).

  `config :vagus, :api_server_enabled` (default `true`) gates whether
  Bandit (and the Finch pool) are actually started — `false` in
  `config/test.exs` so `mix test` never binds a port at all (contract tests
  exercise `Vagus.API.Router`/`Vagus.API.IngressProxy` directly, either via
  `Plug.Test` or their own hermetic `start_supervised` stack, with no
  app-started listening server involved).
  """

  use Supervisor

  @doc "Starts the API supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children =
      if server_enabled?() do
        # Provision the bearer token eagerly so the persisted file exists
        # before anything (dev script, on-device Core launch) needs to read
        # it — lazy first-request provisioning left /data/vagus/token absent
        # until the first Bearer-carrying request (found on device 2026-07-20).
        _token = Vagus.API.Token.get()

        [
          {Finch,
           name: Vagus.Ingress.Finch,
           pools: %{
             default: [
               size: 4,
               # Originate add-on connections from the supervisor anchor
               # (.2), not the bridge gateway (.1) — see
               # `Vagus.Network.source_bind_opts/0`. Empty on :host/:test.
               conn_opts: [transport_opts: Vagus.Network.source_bind_opts()]
             ]
           }},
          # The same pool with NO source bind, for `host_network: true`
          # add-ons — they have no bridge address, so the proxy reaches them
          # on the host's own loopback, and binding a non-loopback source
          # there makes the add-on see a non-local peer and refuse (ESPHome's
          # device builder answers `403 Forbidden`; device-observed
          # 2026-07-29). Finch fixes `conn_opts` per pool at startup, so
          # "bind for bridge targets, don't for loopback" cannot be a
          # per-request option — it has to be a second instance.
          # `Vagus.API.IngressProxy` picks between them per request.
          {Finch, name: Vagus.Ingress.LocalFinch, pools: %{default: [size: 4]}},
          # `Vagus.API.CoreProxy`'s own pool, dedicated rather than sharing
          # `Vagus.Core.Finch` — that pool's other users (the Core watchdog
          # probe, `Vagus.Core.Client`'s token exchange) are frequent, cheap
          # calls, and a proxied request routed through `CoreProxy` can hold a
          # connection open for up to its own 300s REST timeout. Sharing a
          # pool would let one slow proxied call starve either of those. No
          # source bind here — Core is always reached on localhost, never the
          # `hassio` bridge, so there's no bridge-vs-loopback split to make
          # (unlike the two pools above).
          {Finch, name: Vagus.API.CoreProxy.Finch, pools: %{default: [size: 4]}},

          # Holds the Bandit listener once `Vagus.API.Listener` has managed to
          # bind it. A dedicated `DynamicSupervisor` (rather than Bandit
          # directly under this supervisor) is what lets the bind be retried
          # with a backoff instead of crash-looping this subtree — same shape
          # as `Vagus.Engine.DaemonSupervisor`/`Vagus.Engine.Manager`.
          {DynamicSupervisor,
           name: Vagus.API.ListenerSupervisor,
           strategy: :one_for_one,
           max_restarts: 5,
           max_seconds: 30},
          {Vagus.API.Listener, []}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end

  defp server_enabled?, do: Application.get_env(:vagus, :api_server_enabled, true)
end
