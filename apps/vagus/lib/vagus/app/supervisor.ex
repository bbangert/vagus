defmodule Vagus.App.Supervisor do
  @moduledoc """
  The app tree: the directory of app processes, the app processes themselves,
  and the orchestrator. `:rest_for_one` because a lost directory orphans every
  registration made in it, so everything after it restarts with it.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Vagus.App.Directory},
      # Wider than this tree's own budget so a few app processes crash-looping
      # on a bad State entry do not take the directory down with them; each
      # child's `:transient` restart is the first line.
      {DynamicSupervisor,
       name: Vagus.App.Instances, strategy: :one_for_one, max_restarts: 10, max_seconds: 60},
      Vagus.App.Orchestrator
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
