defmodule Vagus.Core.Watchdog.Supervisor do
  @moduledoc """
  Isolating supervisor for the Core watchdog pair (`Vagus.Core.Watchdog`
  container-event half + `Vagus.Core.Watchdog.Probe` API-probe half) —
  the same structure as `Vagus.Addon.Watchdog.Supervisor`, and the same
  `:one_for_one, max_restarts: 5, max_seconds: 30` budget: both halves do
  I/O against the engine/Core and a crash-loop in either must burn its own
  budget here rather than escalate into `Vagus.Supervisor`'s.

  The two halves are independent (separate counters, separate rate
  limits — see each module), so `:one_for_one`, not `:rest_for_one`.

  Sits unconditionally in `Vagus.Application`'s children and follows the
  `Vagus.Core.Boot`/`Vagus.Addon.BootStarter` convention: `init/1` returns
  `:ignore` unless `config :vagus, :core_watchdog` is set (only
  `config/target.exs` sets it — there is no real Core container to watch
  on `:host`/test). The runtime on/off switch is separate: the persisted
  `TokenStore` `watchdog` option gates *actions* live; this flag gates
  whether the processes exist at all.
  """

  use Supervisor

  @doc "Starts the Core watchdog pair's isolating supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(_opts) do
    if Application.get_env(:vagus, :core_watchdog, false) do
      children = [Vagus.Core.Watchdog, Vagus.Core.Watchdog.Probe]
      Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
    else
      :ignore
    end
  end
end
