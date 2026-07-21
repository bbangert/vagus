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
        Vagus.Services,
        Vagus.Discovery,
        Vagus.Auth,

        # Supervisor-API emulator's HTTP surface (Bandit + Plug.Router),
        # isolated with its own restart budget so a crash there can't take
        # down the rest of the app. Started on both :host and real targets
        # — see `Vagus.API.Supervisor` for the isolation rationale.
        {Vagus.API.Supervisor, []},

        # Core-facing token handshake + event-push machinery (TokenStore,
        # Finch, Client, EventPusher), isolated the same way. Started on
        # both :host and real targets — see `Vagus.Core.Supervisor` for the
        # isolation rationale.
        {Vagus.Core.Supervisor, []}
      ] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Vagus.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
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
        {Vagus.Engine.Manager, []}
      ]
    end
  end
end
