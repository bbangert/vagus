defmodule Vagus.App.StepsStub do
  @moduledoc """
  Stands in for `Vagus.App.Steps` when a test sets `:app_steps` to it: every
  step is handed to the process named by `:app_steps_test_pid` as
  `{:step, name, input, task}`, and returns whatever that process sends the
  task as `{:outcome, outcome}`. The test decides each outcome and how long
  each step takes.

  `:ensure_image` answers `{:ok, image}` itself, so the many tests about
  what follows it need not: a test about it sets `:app_steps_ensure_image`
  to `:manual` and is handed it like any other step.
  """

  @spec run(atom(), map()) :: term()
  def run(:ensure_image, input) do
    if Application.get_env(:vagus, :app_steps_ensure_image) == :manual,
      do: ask(:ensure_image, input),
      else: {:ok, input.config.image}
  end

  def run(name, input), do: ask(name, input)

  defdelegate health_schedule(id, engine_opts), to: Vagus.App.Steps

  defp ask(name, input) do
    send(Application.fetch_env!(:vagus, :app_steps_test_pid), {:step, name, input, self()})

    receive do
      {:outcome, outcome} -> outcome
    end
  end
end
