defmodule Vagus.Resource.Stamp do
  @moduledoc """
  A stored instant. The boards have no RTC and a monotonic reading means
  nothing in another VM, so an instant carries the incarnation it was read
  in and is only ever compared within it.
  """

  @enforce_keys [:incarnation, :at]
  defstruct [:incarnation, :at]

  @type t :: %__MODULE__{incarnation: integer(), at: integer()}

  @doc """
  Milliseconds from `stamp` to `now`, or 0 when they are from different
  incarnations: a restart can lengthen a deadline but never skip one.
  """
  @spec age(t(), t()) :: non_neg_integer()
  def age(%__MODULE__{incarnation: same, at: at}, %__MODULE__{incarnation: same, at: now}),
    do: max(now - at, 0)

  def age(%__MODULE__{}, %__MODULE__{}), do: 0

  # The tag keeps a stamp recognisable among plain maps in the resource file.
  @tag "$stamp"

  @doc false
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{incarnation: incarnation, at: at}), do: %{@tag => [incarnation, at]}

  @doc "Turns every stamp inside a JSON-decoded term back into a `t:t/0`."
  @spec revive(term()) :: term()
  def revive(%{@tag => [incarnation, at]} = map)
      when map_size(map) == 1 and is_integer(incarnation) and is_integer(at),
      do: %__MODULE__{incarnation: incarnation, at: at}

  def revive(%{} = map), do: Map.new(map, fn {key, value} -> {key, revive(value)} end)
  def revive(list) when is_list(list), do: Enum.map(list, &revive/1)
  def revive(other), do: other
end

defimpl Jason.Encoder, for: Vagus.Resource.Stamp do
  def encode(stamp, opts), do: Jason.Encode.map(Vagus.Resource.Stamp.to_json(stamp), opts)
end
