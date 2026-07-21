defmodule Vagus.Addon.Backend.Native do
  @moduledoc """
  Placeholder for the `:native` backend — BEAM-subtree "virtual add-ons" (e.g.
  the mqttx broker) presented to Core as add-ons without a container. Declared
  now so the `Vagus.Addon.Backend` seam is honest and additive; implemented in
  a later milestone (handoff `vagus-mqtt`). Every callback raises.
  """

  @behaviour Vagus.Addon.Backend

  @not_impl "Vagus.Addon.Backend.Native is not implemented yet"

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
