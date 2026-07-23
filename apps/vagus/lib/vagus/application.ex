defmodule Vagus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Top-level supervisor for the `vagus` app.

  On target (not `:host`) this starts the engine-supervision machinery: a
  `DynamicSupervisor` to hold the balena-engine daemon once it's started, and
  `Vagus.Engine.Manager`, which waits for VintageNet internet connectivity
  before writing `/run/resolv.conf` and starting the daemon. See
  `Vagus.Engine.Manager` and `Vagus.Engine` for the rest of the runtime engine
  -supervision skeleton (originally spiked in `vagus_spike`, plan.md Phase 2,
  tasks 2.1-2.3).

  On both `:host` and real targets, `Vagus.API.Supervisor` starts the
  Supervisor-API emulator's HTTP surface (see that module for the isolation
  rationale), and `Vagus.Core.Supervisor` starts the Core-facing token
  handshake and event-push machinery (`Vagus.Core.TokenStore`,
  `Vagus.Core.Client`, `Vagus.Core.EventPusher` — see that module for the
  isolation rationale).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Add-on identity + service registries (M4). Started before the HTTP
        # surface so `Vagus.API.Auth` can resolve add-on tokens and the
        # `/services` endpoints have their store the moment requests arrive.
        Vagus.Addon.Registry,
        Vagus.Addon.State,

        # Boot-time reconciliation (M4-P8-T1): restarts `boot: auto` add-ons
        # left `:started` in the persisted state file. Sits unconditionally
        # here on both :host and target — `start_link/1` returns `:ignore`
        # unless `config :vagus, :addon_boot_start` is set (only target.exs
        # sets it; :host/:test stay ephemeral). Started right after
        # `Vagus.Addon.State` so it never races the store it reads from.
        Vagus.Addon.BootStarter,
        Vagus.Addon.Store,
        Vagus.Backups,
        Vagus.Services,
        Vagus.Discovery,
        Vagus.Auth,

        # Holds the native "virtual add-on" BEAM subtrees (M5, the mqttx
        # broker) once `Vagus.Addon.Backend.Native.start/1` starts them —
        # mirrors `Vagus.Engine.DaemonSupervisor`. Started unconditionally on
        # both :host and target (unlike the Docker engine, native add-ons run
        # in dev/host too), empty until an add-on is started. A dedicated
        # DynamicSupervisor keeps a broker crash-loop's restart intensity
        # isolated from the rest of the app's tree.
        {DynamicSupervisor,
         name: Vagus.Addon.Backend.Native.Supervisor,
         strategy: :one_for_one,
         max_restarts: 5,
         max_seconds: 30},

        # Keeps `Vagus.Addon.State` honest for native add-ons: demotes a broker
        # subtree to `:stopped` if OTP supervision exhausts its restart budget
        # (no Docker `die` event fires for a BEAM crash). Started after the
        # DynamicSupervisor it watches children of, and after `Vagus.Addon.State`.
        Vagus.Addon.Backend.Native.Sentinel
      ] ++
        dns_children() ++
        events_children() ++
        watchdog_children() ++
        ingress_children() ++
        [
          # Supervisor-API emulator's HTTP surface (Bandit + Plug.Router),
          # isolated with its own restart budget so a crash there can't take
          # down the rest of the app. Started on both :host and real targets
          # — see `Vagus.API.Supervisor` for the isolation rationale.
          {Vagus.API.Supervisor, []},

          # Core-facing token handshake + event-push machinery (TokenStore,
          # Finch, Client, EventPusher), isolated the same way. Started on
          # both :host and real targets — see `Vagus.Core.Supervisor` for the
          # isolation rationale.
          {Vagus.Core.Supervisor, []},

          # Boot-time Core adoption (CL-P1-T2): polls the engine, then adopts
          # (never creates) the HA Core container, same unconditional-child/
          # config-gated-:ignore convention as `Vagus.Addon.BootStarter`
          # above — see `Vagus.Core.Boot` for the poll/adopt rationale.
          # Started after `Vagus.Core.Supervisor` so `Vagus.Core.Versions` (the
          # seed target) is already up.
          Vagus.Core.Boot,

          # Auto-installs + boots the default native provider (the mqttx broker,
          # M5-P5). `:ignore` unless `config :vagus, :default_native_addon` is set
          # (only target.exs sets it). Placed last so `Native.Supervisor`,
          # `Services`, `Discovery`, and `Vagus.DNS` are all up before it installs
          # + starts the broker (which needs none of the container engine).
          Vagus.Addon.DefaultProvider
        ] ++ target_children()

    # Explicit restart budget (was the OTP default 3/5s): the top level now
    # holds several independent failure sources (DNS, engine, ingress,
    # Vagus.Bluetooth, ...) that share this budget, and the isolated subtrees
    # (Engine.DaemonSupervisor, Native.Supervisor, Vagus.Bluetooth) already
    # budget their own crash-looping internally before escalating here —
    # 3-in-5s of *escalated* exits would take the whole app down too eagerly.
    # 5/30 mirrors the budget those isolation supervisors use themselves.
    opts = [strategy: :one_for_one, name: Vagus.Supervisor, max_restarts: 5, max_seconds: 30]
    Supervisor.start_link(children, opts)
  end

  # The `hassio` DNS server (M4-P1-T2), gated by `:dns_enabled` (false in
  # test.exs so `mix test` never binds :53). On :host dev the .3 anchor / :53
  # bind fails gracefully (logged, idle) since there's no hassio bridge; it
  # does its real work on target.
  defp dns_children do
    if Application.get_env(:vagus, :dns_enabled, true), do: [Vagus.DNS], else: []
  end

  # The docker-events stream (M4B-IW-P1-T1), gated by `:events_enabled` (false
  # in test.exs) — mirrors `:dns_enabled`. `mix test` has no real engine
  # socket to stream from; unit tests start their own instance against a fake
  # unix-socket server instead.
  defp events_children do
    if Application.get_env(:vagus, :events_enabled, true), do: [Vagus.Runtime.Events], else: []
  end

  # Both halves of the add-on watchdog (§B6 container-event +
  # M4B-IW-P1-T3's §B7 application probe), gated together by
  # `:watchdog_enabled` (false in test.exs) — mirrors `:events_enabled`.
  # §B6.5: the two are independent code paths with independent state, but
  # they share a single on/off switch since neither is useful without the
  # other in practice. Isolated under `Vagus.Addon.Watchdog.Supervisor`
  # (review W2) rather than as bare children here — see that module for the
  # isolation rationale. Unit tests start their own instances with injected
  # fakes instead of subscribing to the real `Vagus.Runtime.Events`/engine/
  # `Vagus.Addon.State`.
  defp watchdog_children do
    if Application.get_env(:vagus, :watchdog_enabled, true) do
      [Vagus.Addon.Watchdog.Supervisor]
    else
      []
    end
  end

  # Ingress sessions + token resolution + dynamic-port allocator
  # (M4B-IW-P2-T1, §B1/§B3), gated by `:ingress_enabled` (false in test.exs)
  # — mirrors `:watchdog_enabled`. Router/unit tests `start_supervised` their
  # own instance under the default name, which would clash with an
  # app-started one.
  defp ingress_children do
    if Application.get_env(:vagus, :ingress_enabled, true), do: [Vagus.Ingress], else: []
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children do
      [
        # Holds the balena-engine daemon once Vagus.Engine.Manager starts
        # it. A dedicated DynamicSupervisor (rather than starting the
        # MuonTrap.Daemon directly under Vagus.Supervisor) keeps the
        # daemon's restart/crash-loop intensity isolated from the rest of
        # the app's supervision tree.
        {DynamicSupervisor,
         name: Vagus.Engine.DaemonSupervisor,
         strategy: :one_for_one,
         max_restarts: 5,
         max_seconds: 30},

        # Waits for VintageNet internet connectivity, then writes
        # /run/resolv.conf and starts the balena-engine daemon. Only runs on
        # the target — VintageNet isn't present/meaningful on :host.
        {Vagus.Engine.Manager, []},

        # Bluetooth daemons (dbus-daemon --system + bluetoothd -E), the
        # daemons-only slice of the Bluez stack. HA Core consumes the
        # adapter through the /run/dbus bind on its container; Vagus runs
        # no BLE clients of its own. `:ignore` when the system was built
        # without BlueZ. See Vagus.Bluetooth.
        Vagus.Bluetooth
      ]
    end
  end
end
