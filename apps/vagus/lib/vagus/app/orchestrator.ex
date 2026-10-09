defmodule Vagus.App.Orchestrator do
  @moduledoc """
  Sequences app lifecycles. For now it only brings up one process per
  installed app.
  """

  use GenServer

  alias Vagus.App.Instances

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # In `init/1`, not a continue: `:rest_for_one` restarts this after a directory
  # crash with `Instances` empty, and the API must not see an empty app list in
  # that window, so the tree is not up until every app process is back.
  @impl GenServer
  def init(_opts) do
    Enum.each(installed(), &Instances.ensure(&1.config.slug))
    {:ok, %{}}
  end

  # Narrow test setups run without State; that is no apps, not a crashed tree.
  defp installed do
    Vagus.Addon.State.list()
  catch
    :exit, _reason -> []
  end
end
