defmodule Vagus.Addon.Backend.Microvm do
  @moduledoc """
  Placeholder for the `:microvm` backend — the Firecracker/Cloud-Hypervisor
  isolation tier for capability-granted add-ons (handoff: deferred, but the
  seam must exist from day one). Declared now so `Vagus.Addon.Backend` carries
  `:container | :native | :microvm` additively; every callback raises.
  """

  @behaviour Vagus.Addon.Backend

  @not_impl "Vagus.Addon.Backend.Microvm is not implemented yet"

  @impl true
  def pull(_spec), do: raise(@not_impl)
  @impl true
  def create(_spec), do: raise(@not_impl)
  @impl true
  def start(_id), do: raise(@not_impl)
  @impl true
  def stop(_id, _opts \\ []), do: raise(@not_impl)
  @impl true
  def remove(_id, _opts \\ []), do: raise(@not_impl)
  @impl true
  def state(_id), do: raise(@not_impl)
end
