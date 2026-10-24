defmodule Vagus.Memory.Embedder do
  @moduledoc """
  Turns text into the vector `Vagus.Memory` stores and searches by. Chosen
  with `config :vagus, Vagus.Memory, embedder: Module`; `model/0` and
  `dims/0` are recorded in the schema, so a different engine's vectors are
  never compared with another's (`Vagus.Memory.reembed/2` switches).
  """

  @callback embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  @callback model() :: String.t()
  @callback dims() :: pos_integer()
end
