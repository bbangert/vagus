defmodule Vagus.App.Instances do
  @moduledoc """
  Starts and stops app processes under the `Vagus.App.Instances`
  DynamicSupervisor that `Vagus.App.Supervisor` names after this module.
  """

  @spec ensure(String.t()) :: {:ok, pid()} | :ignore | {:error, term()}
  def ensure(slug) do
    case DynamicSupervisor.start_child(__MODULE__, {Vagus.App.Server, slug}) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @spec stop(String.t()) :: :ok
  def stop(slug) do
    case Registry.lookup(Vagus.App.Directory, {:slug, slug}) do
      [{pid, _value}] -> :gen_statem.stop(pid, :normal, 5_000)
      [] -> :ok
    end
  rescue
    # The directory is restarting, and every app process with it.
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end
end
