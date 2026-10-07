defmodule Vagus.Resource do
  @moduledoc """
  One stored object of the reconciliation model: `spec` is what is wanted,
  `status` is what was last observed. See `docs/app-lifecycle.md`.

  Only `Vagus.Resource.Store` writes these. `status` never reaches flash and
  is rebuilt by observation after an application restart; every other field
  is persisted.
  """

  @enforce_keys [:kind, :name, :uid]
  defstruct [
    :kind,
    :name,
    :uid,
    generation: 1,
    spec: %{},
    status: %{},
    progress: %{},
    finalizers: [],
    owner_refs: [],
    managed_fields: %{},
    deleting?: false
  ]

  @type kind :: atom()
  @type name :: String.t()
  @type key :: {kind(), name()}

  @typedoc """
  Names a uid as well as a key, so a re-created resource does not inherit the
  children of its predecessor.
  """
  @type ref :: %{kind: kind(), name: name(), uid: pos_integer()}

  @typedoc "Identity of whoever makes a write: a controller module, or a tuple naming one resource."
  @type writer :: atom() | String.t() | integer() | tuple()

  @type path :: [atom() | String.t() | integer()]

  @typedoc """
  `observed_generation` is the generation the writer had read when it decided
  this, so a reader can tell a verdict on the current spec from a leftover.
  """
  @type condition :: %{
          type: atom(),
          status: boolean(),
          reason: atom(),
          message: String.t() | nil,
          observed_generation: pos_integer()
        }

  @type t :: %__MODULE__{
          kind: kind(),
          name: name(),
          uid: pos_integer(),
          generation: pos_integer(),
          spec: map(),
          status: map(),
          progress: map(),
          finalizers: [atom()],
          owner_refs: [ref()],
          managed_fields: %{optional(path()) => writer()},
          deleting?: boolean()
        }

  @spec ref(t()) :: ref()
  def ref(%__MODULE__{kind: kind, name: name, uid: uid}), do: %{kind: kind, name: name, uid: uid}

  @spec condition(atom(), boolean(), atom(), pos_integer(), String.t() | nil) :: condition()
  def condition(type, status, reason, observed_generation, message \\ nil)
      when is_atom(type) and is_boolean(status) and is_atom(reason) do
    %{
      type: type,
      status: status,
      reason: reason,
      message: message,
      observed_generation: observed_generation
    }
  end

  @spec get_condition(t(), atom()) :: condition() | nil
  def get_condition(%__MODULE__{status: status}, type), do: conditions(status)[type]

  @spec put_condition(t(), condition()) :: t()
  def put_condition(%__MODULE__{status: status} = resource, %{type: type} = condition) do
    %{
      resource
      | status: Map.put(status, :conditions, Map.put(conditions(status), type, condition))
    }
  end

  defp conditions(status), do: Map.get(status, :conditions, %{})
end
