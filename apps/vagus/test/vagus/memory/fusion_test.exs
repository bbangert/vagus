defmodule Vagus.Memory.FusionTest do
  use ExUnit.Case, async: true

  alias Vagus.Memory.Fusion

  test "an id both lists rank beats one ranked first by only one" do
    assert [{2, both}, {1, _}, {3, _}] = Fusion.merge([[1, 2], [2, 3]], 3)
    assert_in_delta both, 1 / 62 + 1 / 61, 1.0e-12
  end

  test "equal scores go to the newer id" do
    assert Fusion.merge([[1], [2]], 2) == [{2, 1 / 61}, {1, 1 / 61}]
  end

  test "disjoint lists interleave by rank" do
    assert Enum.map(Fusion.merge([[10, 11], [20, 21]], 4), &elem(&1, 0)) == [20, 10, 21, 11]
  end

  test "only the top k are returned, and empty lists fuse to nothing" do
    assert [{1, _}] = Fusion.merge([[1, 2, 3], []], 1)
    assert Fusion.merge([[], []], 8) == []
  end
end
