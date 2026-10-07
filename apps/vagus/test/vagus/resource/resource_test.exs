defmodule Vagus.ResourceTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource

  defp resource, do: %Resource{kind: :thing, name: "t", uid: 7, generation: 3}

  test "a condition is read back by type and records the generation it was observed at" do
    ready = Resource.condition(:ready, true, :running, 3)
    resource = Resource.put_condition(resource(), ready)

    assert Resource.get_condition(resource, :ready) == %{
             type: :ready,
             status: true,
             reason: :running,
             message: nil,
             observed_generation: 3
           }

    assert Resource.get_condition(resource, :dns_ready) == nil
    assert Resource.get_condition(resource(), :ready) == nil
  end

  test "putting a condition replaces its own type and leaves the others" do
    resource =
      resource()
      |> Resource.put_condition(Resource.condition(:ready, false, :starting, 2))
      |> Resource.put_condition(Resource.condition(:dns_ready, true, :registered, 2))
      |> Resource.put_condition(Resource.condition(:ready, true, :running, 3, "up"))

    assert %{status: true, observed_generation: 3, message: "up"} =
             Resource.get_condition(resource, :ready)

    assert %{status: true, reason: :registered} = Resource.get_condition(resource, :dns_ready)
  end

  test "a reference names the uid, not only the key" do
    assert Resource.ref(resource()) == %{kind: :thing, name: "t", uid: 7}
  end
end
