defmodule Vagus.Runtime.Engine.Container do
  @moduledoc """
  A container as the engine reports it, in engine-neutral terms.

  `exit_code` is only set once the container has exited (both engines report
  `0` for one that never ran). A `nil` field means the engine did not say: a
  `list/1` summary carries only `id`, `name`, `image`, `state`, `labels` and
  `exit_code`.
  """

  @type state ::
          :created | :running | :paused | :restarting | :stopping | :exited | :removing | :unknown

  @type health :: :healthy | :unhealthy | :starting

  @type healthcheck :: %{
          test: [String.t()],
          interval_ms: non_neg_integer() | nil,
          timeout_ms: non_neg_integer() | nil,
          start_period_ms: non_neg_integer() | nil,
          start_interval_ms: non_neg_integer() | nil,
          retries: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          image: String.t() | nil,
          state: state() | nil,
          exit_code: integer() | nil,
          health: health() | nil,
          labels: %{optional(String.t()) => String.t()} | nil,
          env: %{optional(String.t()) => String.t()} | nil,
          ips: %{optional(String.t()) => String.t()} | nil,
          healthcheck: healthcheck() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  # Docker's State.Running: moby keeps it true while paused or restarting.
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{state: state}), do: state in [:running, :paused, :restarting]

  defstruct [
    :id,
    :name,
    :image,
    :state,
    :exit_code,
    :health,
    :labels,
    :env,
    :ips,
    :healthcheck,
    :started_at,
    :finished_at
  ]
end
