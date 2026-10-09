defmodule Vagus.App.Orchestrator do
  @moduledoc """
  Sequences app lifecycles. For now it only brings up one process per
  installed app.
  """

  use GenServer

  require Logger

  alias Vagus.App.Instances

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # In `init/1`, not a continue, so this tree is not reported started until
  # every app process exists. A `State.list/0` exit crashes it: State is a
  # durable sibling started before this tree, so its absence must be loud.
  @impl GenServer
  def init(_opts) do
    Enum.each(Vagus.Addon.State.list(), &ensure(&1.config.slug))
    {:ok, %{}}
  end

  # One app whose process cannot start must not take the others down with it.
  defp ensure(slug) do
    case Instances.ensure(slug) do
      {:ok, _pid} -> :ok
      :ignore -> :ok
      {:error, reason} -> Logger.warning("App #{slug} process did not start: #{inspect(reason)}")
    end
  end
end
