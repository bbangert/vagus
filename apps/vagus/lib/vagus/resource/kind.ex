defmodule Vagus.Resource.Kind do
  @moduledoc """
  What the store has to know about a kind before any controller exists:
  how to admit a spec, and how to get the kind's own shapes through JSON,
  which has no atoms, tuples or structs. Kinds are static, so the store is
  given these when it starts and can read its file before anything registers.

  The `encode_*` hooks return something `Jason` can encode; the `decode_*`
  hooks get the decoded form back, string keys and all. Both default to
  identity. Stamps need no hook: the store carries them itself.
  """

  defstruct validators: [],
            encode_spec: &Function.identity/1,
            decode_spec: &Function.identity/1,
            encode_progress: &Function.identity/1,
            decode_progress: &Function.identity/1

  @typedoc "May also fill in defaults: the spec it returns is the one stored."
  @type validator :: (map() -> {:ok, map()} | {:error, term()})

  @type t :: %__MODULE__{
          validators: [validator()],
          encode_spec: (map() -> term()),
          decode_spec: (term() -> map()),
          encode_progress: (map() -> term()),
          decode_progress: (term() -> map())
        }

  @spec new(t() | keyword() | map()) :: t()
  def new(%__MODULE__{} = kind), do: kind
  def new(fields), do: struct!(__MODULE__, fields)
end
