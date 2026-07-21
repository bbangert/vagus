defmodule Vagus.Addon.Watchdog.SupervisorTest do
  @moduledoc """
  W2: minimal proof that `Vagus.Addon.Watchdog.Supervisor` actually
  supervises both watchdog halves under one isolated restart budget (no
  dedicated test exists for the `Vagus.API.Supervisor`/`Vagus.Core.Supervisor`
  precedent either — this mirrors that same test-light approach). Started
  with default opts: `Vagus.Addon.State` is itself an unconditional app
  child (see `config/test.exs`), and both watchdogs' `init/1` only reads
  `Vagus.Addon.State`/`Vagus.Runtime.Events` on demand or if already running
  (`config :vagus, :events_enabled` is false in test.exs) — no injected
  fakes are needed just to prove both children start and stay alive.
  """

  use ExUnit.Case, async: false

  alias Vagus.Addon.Watchdog

  test "both watchdog halves start and stay alive under the isolating supervisor" do
    pid = start_supervised!(Watchdog.Supervisor)

    children = Supervisor.which_children(pid)
    assert length(children) == 2

    assert Enum.all?(children, fn {_id, child_pid, _type, _modules} ->
             is_pid(child_pid) and Process.alive?(child_pid)
           end)

    assert is_pid(Process.whereis(Vagus.Addon.Watchdog))
    assert is_pid(Process.whereis(Vagus.Addon.Watchdog.Probe))
  end
end
