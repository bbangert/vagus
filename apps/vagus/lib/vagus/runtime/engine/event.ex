defmodule Vagus.Runtime.Engine.Event do
  @moduledoc false

  @type action :: :start | :die | :health | :create | :destroy | :other

  @type t :: %__MODULE__{
          action: action(),
          name: String.t() | nil,
          id: String.t() | nil,
          exit_code: integer() | nil,
          health: Vagus.Runtime.Engine.Container.health() | nil,
          time_ns: integer() | nil
        }

  defstruct [:action, :name, :id, :exit_code, :health, :time_ns]
end
