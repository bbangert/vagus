defmodule Vagus.Resource.RuntimeEnqueueTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource.{Runtime, Store}
  alias Vagus.Resource.Toys.{Follower, Probe, Stall}

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

    assert %{hinted: ["f1"], dirty: [], in_flight: %{"f1" => ^step}} = enqueued(sys, "f1")

    put_fact(sys, {:follow, "f1"}, nil)
    send(step, :go)
    settle(sys)

    assert notes(sys) == [{:followed, "f1", 1}, {:followed, "f1", 1}]
  end

  describe "while the resource's pass is failing" do
    # A pass that will crash is parked, with a back-off long enough never to
    # fire: whatever runs after it was not brought by the timer.
    setup do
      sys = start_system(controllers: [Stall], runtime: [backoff: {600_000, 600_000}])
      {:ok, _} = Store.create(:stall, "s", %{}, sys.i)
      assert_receive {:stalled, "s", step}, sys.wait
      %{sys: sys, step: step}
    end

    test "an enqueue gets its pass as soon as that one has failed", %{sys: sys, step: step} do
      :ok = Runtime.enqueue(Stall, "s", sys.i)
      assert %{hinted: ["s"]} = Runtime.info(Stall, sys.i)

      send(step, :go)

      assert_receive {:stalled, "s", next}, sys.wait
      assert next != step
    end

    test "a change in the store waits for the back-off", %{sys: sys, step: step} do
      {:ok, _} = Store.update_spec(:stall, "s", %{"n" => 2}, sys.i)
      assert %{dirty: ["s"], hinted: []} = info(sys, Stall)

      send(step, :go)
      settle(sys)

      assert %{steps: 1, timers: ["s"], failures: %{"s" => 1}, queued: [], dirty: []} =
               Runtime.info(Stall, sys.i)
    end
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
