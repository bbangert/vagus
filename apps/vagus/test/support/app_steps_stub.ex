defmodule Vagus.App.StepsStub do
  @moduledoc """
  Stands in for `Vagus.App.Steps` when a test sets `:app_steps` to it: every
  step is handed to the process named by `:app_steps_test_pid` as
  `{:step, name, input, task}`, and returns whatever that process sends the
  task as `{:outcome, outcome}`. The test decides each outcome and how long
  each step takes.
  """

  @spec run(atom(), map()) :: term()
  def run(name, input) do
    send(Application.fetch_env!(:vagus, :app_steps_test_pid), {:step, name, input, self()})

    receive do
      {:outcome, outcome} -> outcome
    end
  end
end
