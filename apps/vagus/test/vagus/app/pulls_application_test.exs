defmodule Vagus.App.PullsApplicationTest do
  @moduledoc "The application's own resource instance runs the pull worker, where it must stand."

  use ExUnit.Case, async: true

  alias Vagus.App.Pulls
  alias Vagus.Resource.{Controllers, Lanes}

  test "the worker and its tasks stand after the lanes and before the controllers" do
    # Newest first, as a supervisor lists its children.
    started =
      for {id, pid, _type, _modules} <- Supervisor.which_children(Vagus.Resource.Supervisor),
          do: {id, pid}

    order = started |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    place = fn id -> Enum.find_index(order, &(&1 == id)) end

    assert place.(Lanes) < place.(Pulls)
    assert place.(Pulls) < place.(Pulls.tasks(Vagus.Resource))
    assert place.(Pulls.tasks(Vagus.Resource)) < place.(Controllers.Supervisor)

    assert started[Pulls] == Process.whereis(Pulls.name(Vagus.Resource))
    assert Pulls.state("nothing:asked", []) == :idle
  end
end
