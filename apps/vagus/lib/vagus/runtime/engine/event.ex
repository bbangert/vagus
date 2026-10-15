defmodule Vagus.Runtime.Engine.Event do
  @moduledoc """
  A container lifecycle event, as `Vagus.Runtime.Events` delivers it.

  `managed` is the engine's word that the container carries Vagus's
  `supervisor_managed` label; only the engine knows how its events report
  labels. `health` is set only on a `:health` event.
  """

  @type action :: :start | :die | :health | :create | :destroy | :other

  @type t :: %__MODULE__{
          action: action(),
          name: String.t() | nil,
          id: String.t() | nil,
          exit_code: integer() | nil,
          health: Vagus.Runtime.Engine.Container.health() | nil,
          time_ns: integer() | nil,
          managed: boolean()
        }

  defstruct [:action, :name, :id, :exit_code, :health, :time_ns, managed: false]
end
