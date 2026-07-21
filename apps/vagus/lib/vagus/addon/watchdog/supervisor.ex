defmodule Vagus.Addon.Watchdog.Supervisor do
  @moduledoc """
  Isolated supervisor for the add-on watchdog pair (`Vagus.Addon.Watchdog` +
  `Vagus.Addon.Watchdog.Probe`,
  `docs/contract-2026.7-m4b-ingress-watchdog.md` §B6/§B7).

  Both watchdogs do network I/O (docker events / TCP-or-HTTP probes) and act
  on live `Vagus.Addon.State` entries; a crash-loop in either one exceeding
  the default 3-restarts/5s budget would otherwise escalate and take down
  the rest of `Vagus.Supervisor` (review W2) — the same scenario
  `Vagus.API.Supervisor`/`Vagus.Core.Supervisor` already got their own
  isolating supervisors for. `max_restarts: 5, max_seconds: 30` mirrors
  those two modules' budget exactly.
  """

  use Supervisor

  @doc "Starts the watchdog pair's isolating supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [Vagus.Addon.Watchdog, Vagus.Addon.Watchdog.Probe]
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end
end
