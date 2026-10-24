defmodule Vagus.Memory.Embedder.None do
  @moduledoc """
  The default until an engine is chosen: no vectors, so recall is
  keyword-only. Its 384 dims size the column for a small sentence model,
  so adopting one needs no column rebuild.
  """

  @behaviour Vagus.Memory.Embedder

  @impl true
  def embed(_text), do: {:error, :no_embedder}

  @impl true
  def model, do: "none"

  @impl true
  def dims, do: 384
end
