defmodule Vagus.Memory.Fusion do
  @moduledoc """
  Reciprocal rank fusion of the vector and keyword rankings: each list adds
  `1 / (k + rank)` to an id it ranks, so agreement between the two outranks
  a high place in one, and neither list's raw scores need comparing.
  """

  @k 60

  @doc """
  The top `limit` `{id, score}` of the ranked id lists, best first. Equal
  scores go to the newer (higher) id.
  """
  @spec merge([[integer()]], pos_integer()) :: [{integer(), float()}]
  def merge(rankings, limit) do
    rankings
    |> Enum.reduce(%{}, fn ids, acc ->
      ids
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {id, rank}, acc ->
        Map.update(acc, id, 1 / (@k + rank), &(&1 + 1 / (@k + rank)))
      end)
    end)
    |> Enum.sort_by(fn {id, score} -> {score, id} end, :desc)
    |> Enum.take(limit)
  end
end
