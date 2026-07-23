defmodule Vagus.Core.Watchdog.SupervisorTest do
  # async: false — mutates the :core_watchdog app env the supervisor's
  # init/1 reads, and (when gated on) starts the pair under their default
  # global names.
  use ExUnit.Case, async: false

  setup do
    original = Application.fetch_env(:vagus, :core_watchdog)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:vagus, :core_watchdog, value)
        :error -> Application.delete_env(:vagus, :core_watchdog)
      end
    end)

    :ok
  end

  test "returns :ignore when :core_watchdog is unset (off-target default)" do
    Application.delete_env(:vagus, :core_watchdog)
    assert :ignore = Vagus.Core.Watchdog.Supervisor.start_link(name: :cw_sup_ignore_test)
  end

  test "starts both halves when :core_watchdog is set" do
    Application.put_env(:vagus, :core_watchdog, true)

    pid = start_supervised!({Vagus.Core.Watchdog.Supervisor, name: :cw_sup_gated_on_test})

    children = Supervisor.which_children(pid)
    ids = children |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert ids == [Vagus.Core.Watchdog, Vagus.Core.Watchdog.Probe]
    assert Enum.all?(children, fn {_id, child, _type, _mods} -> is_pid(child) end)
  end
end
