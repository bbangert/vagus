defmodule Vagus.Runtime.Stats do
  @moduledoc """
  The Supervisor stats shape (`aiohasupervisor` `ContainerStats` / the M2
  `CoreStats` model) every engine's `stats/2` answers in.
  """

  @zero %{
    cpu_percent: 0.0,
    memory_usage: 0,
    memory_limit: 0,
    memory_percent: 0.0,
    network_rx: 0,
    network_tx: 0,
    blk_read: 0,
    blk_write: 0
  }

  @doc "The all-zero stats map (for a stopped/absent container)."
  @spec zero() :: map()
  def zero, do: @zero
end
