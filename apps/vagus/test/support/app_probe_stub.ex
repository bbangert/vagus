defmodule Vagus.App.ProbeStub do
  @moduledoc """
  Stands in for `Vagus.App.Probe` when a test sets `:app_probe` to it: each
  probe is handed to the process named by `:app_steps_test_pid` as
  `{:probe, template, input, task}`, and returns whatever that process sends
  the task as `{:result, result}`.
  """

  @spec check(String.t() | nil, map()) :: :healthy | :unhealthy | :skip
  def check(template, input) do
    send(Application.fetch_env!(:vagus, :app_steps_test_pid), {:probe, template, input, self()})

    receive do
      {:result, result} -> result
    end
  end
end
