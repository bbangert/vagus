defmodule Vagus.Memory.FakeEmbedder do
  @moduledoc """
  Deterministic bag-of-words vectors for the memory tests: texts sharing
  words are close, whatever else they say. A floor on every dimension keeps
  a vector from ever being zero, whose cosine distance is undefined.
  """

  defmacro __using__(opts) do
    quote do
      @behaviour Vagus.Memory.Embedder
      @impl true
      def model, do: unquote(opts[:model])
      @impl true
      def dims, do: unquote(opts[:dims])
      @impl true
      def embed(text), do: {:ok, Vagus.Memory.FakeEmbedder.vector(text, dims())}
    end
  end

  @spec vector(String.t(), pos_integer()) :: [float()]
  def vector(text, dims) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z]+/, trim: true)
      |> Enum.frequencies_by(&:erlang.phash2(&1, dims))

    for i <- 0..(dims - 1), do: 0.01 + Map.get(counts, i, 0)
  end
end

defmodule Vagus.Memory.FakeEmbedder.A do
  @moduledoc false
  use Vagus.Memory.FakeEmbedder, model: "fake-a", dims: 64
end

defmodule Vagus.Memory.FakeEmbedder.B do
  @moduledoc false
  use Vagus.Memory.FakeEmbedder, model: "fake-b", dims: 64
end

defmodule Vagus.Memory.FakeEmbedder.Narrow do
  @moduledoc false
  use Vagus.Memory.FakeEmbedder, model: "fake-narrow", dims: 32
end

defmodule Vagus.Memory.FakeEmbedder.Wrong do
  @moduledoc "Claims the A model but answers the wrong width."
  @behaviour Vagus.Memory.Embedder
  @impl true
  def model, do: "fake-a"
  @impl true
  def dims, do: 64
  @impl true
  def embed(_text), do: {:ok, [1.0, 2.0]}
end
