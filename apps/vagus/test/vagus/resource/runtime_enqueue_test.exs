defmodule Vagus.Resource.RuntimeEnqueueTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource.{Runtime, Store}
  alias Vagus.Resource.Toys.{Follower, Probe}

  @moduletag :capture_log

  # Followers write nothing, so nothing but the test brings one back, and
  # each pass leaves one note.
  defp followers(names) do
    sys = start_system(controllers: [Probe, Follower])
    given_ready(sys, {:probe, "p", %{}})
    for name <- names, do: {:ok, _} = Store.create(:follower, name, %{"target" => "p"}, sys.i)
    settle(sys)
    notes(sys)
    sys
  end

  # The cast and this call leave the same process for the same runtime, so
  # the answer is from after the cast.
  defp enqueued(sys, name) do
    :ok = Runtime.enqueue(Follower, name, sys.i)
    Runtime.info(Follower, sys.i)
  end

  test "enqueue runs one pass for the named resource" do
    sys = followers(["f1"])

    enqueued(sys, "f1")
    settle(sys)

    assert notes(sys) == [{:followed, "f1", 1}]
  end

  test "enqueue leaves every other resource of the kind alone" do
    sys = followers(["f1", "f2"])

    enqueued(sys, "f2")
    settle(sys)

    assert notes(sys) == [{:followed, "f2", 1}]
  end

  test "enqueue during the resource's pass runs it once more afterwards" do
    sys = followers(["f1"])
    put_fact(sys, {:follow, "f1"}, :block)

    enqueued(sys, "f1")
    assert_receive {:following, "f1", step}, sys.wait

    assert %{dirty: ["f1"], in_flight: %{"f1" => ^step}} = enqueued(sys, "f1")

    put_fact(sys, {:follow, "f1"}, nil)
    send(step, :go)
    settle(sys)

    assert notes(sys) == [{:followed, "f1", 1}, {:followed, "f1", 1}]
  end

  test "enqueue of a name the kind does not hold starts nothing and is not kept" do
    sys = followers(["f1"])
    %{steps: steps} = Runtime.info(Follower, sys.i)

    assert %{queued: [], in_flight: in_flight, steps: ^steps} = enqueued(sys, "nobody")
    assert in_flight == %{}
  end

  test "enqueue with no runtime is a no-op for the caller" do
    assert :ok = Runtime.enqueue(Follower, "f1", instance: __MODULE__.Nowhere)
  end
end
