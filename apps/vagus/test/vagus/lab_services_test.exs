defmodule Vagus.LabServicesTest do
  use ExUnit.Case, async: false

  test "on the default flavor every child is ignored" do
    assert Vagus.Flavor.get() == :default
    sup = start_supervised!(Vagus.LabServices)

    children = Supervisor.which_children(sup)
    assert length(children) == 3
    assert Enum.all?(children, fn {_id, pid, _type, _mods} -> pid == :undefined end)
    assert %{active: 0} = Supervisor.count_children(sup)
  end

  test "restart budget is its own" do
    {:ok, {flags, _children}} = Vagus.LabServices.init([])
    assert %{strategy: :one_for_one, intensity: 3, period: 60} = flags
  end
end
