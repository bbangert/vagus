defmodule Vagus.Resource.Verdict do
  @moduledoc """
  What one `reconcile/2` pass concluded about a resource, and the only source
  of a status write.

  `conditions` holds an outcome for every condition type the controller
  declared, never a subset: the runtime writes them in the commit that marks
  the generation observed, so a type left out would stand beside that mark as
  a leftover from an earlier generation and read as current.

  `status` is the other status the kind's owner reports, such as the running
  instance or a diary of what it has counted. It is merged: a key left out
  keeps its last value. An attached controller reports conditions only.

  `terminal?` says the resource has finished for good. A kind with
  `retention/0` is collected by it.
  """

  alias Vagus.Resource

  @enforce_keys [:conditions]
  defstruct [:conditions, status: %{}, terminal?: false]

  @type outcome :: {boolean(), atom()} | {boolean(), atom(), String.t() | nil}

  @type t :: %__MODULE__{
          conditions: %{optional(atom()) => outcome()},
          status: map(),
          terminal?: boolean()
        }

  # The runtime's own: it stamps both from what the step read.
  @reserved [:conditions, :observed_generation, :finished]

  @doc "Options: `:status`, `:terminal?`."
  @spec new(%{optional(atom()) => outcome()} | keyword(outcome()), keyword()) :: t()
  def new(conditions, opts \\ []) do
    struct!(__MODULE__, [conditions: Map.new(conditions)] ++ opts)
  end

  @doc """
  Why the runtime would refuse `verdict` from a controller that declared
  `types`; `[]` when it would not. `owner?` is whether the controller owns
  the kind.
  """
  @spec problems(term(), [atom()], boolean()) :: [term()]
  def problems(
        %__MODULE__{conditions: %{} = conditions, status: %{} = status} = verdict,
        types,
        owner?
      ) do
    given = Map.keys(conditions)

    Enum.concat([
      for(type <- types -- given, do: {:missing, type}),
      for(type <- given -- types, do: {:undeclared, type}),
      for({type, outcome} <- conditions, not outcome?(outcome), do: {:bad_outcome, type}),
      for(key <- @reserved, is_map_key(status, key), do: {:reserved, key}),
      if(owner? or status == %{}, do: [], else: [:status_not_owned]),
      if(owner? or not verdict.terminal?, do: [], else: [:terminal_not_owned]),
      if(is_boolean(verdict.terminal?), do: [], else: [:bad_terminal])
    ])
  end

  def problems(_other, _types, _owner?), do: [:not_a_verdict]

  defp outcome?({status, reason}), do: is_boolean(status) and is_atom(reason)

  defp outcome?({status, reason, message}),
    do: outcome?({status, reason}) and (is_nil(message) or is_binary(message))

  defp outcome?(_other), do: false

  @doc "The conditions as the store takes them, each marked with the generation they are about."
  @spec conditions(t(), pos_integer()) :: [Resource.condition()]
  def conditions(%__MODULE__{conditions: conditions}, generation) do
    for {type, outcome} <- Enum.sort(conditions) do
      case outcome do
        {status, reason} -> Resource.condition(type, status, reason, generation)
        {status, reason, message} -> Resource.condition(type, status, reason, generation, message)
      end
    end
  end
end
