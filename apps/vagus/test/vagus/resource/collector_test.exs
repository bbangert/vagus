defmodule Vagus.Resource.CollectorTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.{Collector, Runtime, Stamp, Store, TestClock}
  alias Vagus.Resource.Toys.{Kept, OneShot, Probe, Tagger}

  @moduletag :capture_log
  @moduletag :scenario

  describe "owners" do
    test "removing an owner deletes what it owned, through the finalizers" do
      sys = start_system(controllers: [Probe, Kept])
      owner = given_ready(sys, {:probe, "o", %{}})
      given_ready(sys, {:kept, "child", %{}}, owner_refs: [Resource.ref(owner)])
      given_ready(sys, {:kept, "bystander", %{}})

      {:ok, _} = Store.delete(:probe, "o", sys.i)
      await!(sys, :kept, "child", :gone)
      settle(sys)

      assert journal(sys) |> Enum.filter(&(elem(&1, 0) == {:kept, "child"})) ==
               [{{:kept, "child"}, :make}, {{:kept, "child"}, :unmake}]

      assert fact(sys, {:made, "child"}) == false
      assert %Resource{deleting?: false} = Store.get(:kept, "bystander", sys.i)
    end

    test "ownership is by uid: a new resource under the owner's name owns nothing" do
      sys = start_system(controllers: [Probe, Kept])
      old = given_ready(sys, {:probe, "o", %{}})
      {:ok, _} = Store.delete(:probe, "o", sys.i)
      new = given_ready(sys, {:probe, "o", %{}})
      assert new.uid != old.uid

      {:ok, _} = Store.create(:kept, "orphan", %{}, [owner_refs: [Resource.ref(old)]] ++ sys.i)
      given_ready(sys, {:kept, "child", %{}}, owner_refs: [Resource.ref(new)])

      await!(sys, :kept, "orphan", :gone)
      settle(sys)
      assert %Resource{deleting?: false} = Store.get(:kept, "child", sys.i)
    end

    test "a resource with several owners goes with the last of them" do
      sys = start_system(controllers: [Probe, Kept])
      owners = for name <- ["o1", "o2"], do: given_ready(sys, {:probe, name, %{}})
      given_ready(sys, {:kept, "shared", %{}}, owner_refs: Enum.map(owners, &Resource.ref/1))

      {:ok, _} = Store.delete(:probe, "o1", sys.i)
      settle(sys)
      assert %Resource{deleting?: false} = Store.get(:kept, "shared", sys.i)

      {:ok, _} = Store.delete(:probe, "o2", sys.i)
      await!(sys, :kept, "shared", :gone)
    end
  end

  describe "an orphan" do
    test "is only deleted: a release beside the delete could be refused and keep it" do
      sys = start_system(controllers: [Probe, Kept])
      shutdown(sys, true)
      gone = %{kind: :probe, name: "gone", uid: 99}
      writer = {:probe, "gone", 99}

      {:ok, _} = Store.create(:kept, "k", %{}, [owner_refs: [gone]] ++ sys.i)

      {:ok, orphan} =
        Store.update_spec(:kept, "k", [{:put, ["holds", "x"], true}], [writer: writer] ++ sys.i)

      assert Collector.dependencies(orphan) == [probe: "gone"]
      assert Collector.ops(orphan, sys.i) == [{:delete, :kept, "k"}]

      # Owned, the same dead writer is released.
      {:ok, _} = Store.create(:kept, "free", %{}, sys.i)

      {:ok, held} =
        Store.update_spec(
          :kept,
          "free",
          [{:put, ["holds", "x"], true}],
          [writer: writer] ++ sys.i
        )

      assert Collector.ops(held, sys.i) == [{:release_writer, :kept, "free", writer}]
    end
  end

  describe "field writers" do
    test "when a resource that wrote another's fields is removed, its paths are released" do
      sys = start_system(controllers: [Probe, Kept])
      writer = given_ready(sys, {:probe, "w", %{}})
      given_ready(sys, {:kept, "k", %{}})
      as_writer = [writer: Resource.writer(writer)] ++ sys.i

      {:ok, _} =
        Store.update_spec(
          :kept,
          "k",
          [{:put, ["holds", "w"], true}, {:put, ["pin"], 3}],
          as_writer
        )

      {:ok, _} = Store.update_spec(:kept, "k", [{:put, ["holds", "user"], true}], sys.i)
      settle(sys)

      {:ok, _} = Store.delete(:probe, "w", sys.i)
      await!(sys, :kept, "k", &(&1.managed_fields == %{}))
      settle(sys)

      # Its hold went with it; the value it had pinned stays, unowned.
      assert %{spec: %{"holds" => %{"user" => true} = holds, "pin" => 3}} =
               Store.get(:kept, "k", sys.i)

      assert map_size(holds) == 1
      assert {:ok, _} = Store.update_spec(:kept, "k", %{"pin" => 4}, sys.i)
    end
  end

  describe "retention" do
    test "of the finished resources of a kind, the newest `keep` remain" do
      sys = start_system(controllers: [OneShot])
      for n <- 1..5, do: {:ok, _} = Store.create(:oneshot, "run-#{n}", %{}, sys.i)
      settle(sys)

      assert for(run <- Store.list(:oneshot, sys.i), do: run.name) == ["run-4", "run-5"]
    end

    test "each expiry names the uid it listed, and with no ttl only the count applies" do
      sys = start_system(controllers: [OneShot])
      for n <- 1..2, do: given_ready(sys, {:oneshot, "run-#{n}", %{}}, condition: :done)
      [first, second] = Store.list(:oneshot, sys.i)
      %Stamp{} = now = TestClock.now(sys.clock)
      later = %{now | at: 10_000_000}

      assert Collector.expired(:oneshot, %{keep: 1, ttl_ms: :infinity}, later, sys.i) ==
               [[{:expect, :oneshot, "run-1", uid: first.uid}, {:delete, :oneshot, "run-1"}]]

      assert [[{:expect, :oneshot, "run-2", uid: uid}, _], [{:expect, :oneshot, "run-1", _}, _]] =
               Collector.expired(:oneshot, %{keep: 2, ttl_ms: 1_000}, later, sys.i)

      assert uid == second.uid
      assert Collector.expired(:oneshot, %{keep: 2, ttl_ms: :infinity}, later, sys.i) == []
    end

    test "a finished resource is looked at again when its ttl is up, without a resync" do
      sys = start_system(controllers: [OneShot])
      given_ready(sys, {:oneshot, "run", %{}}, condition: :done)

      runtime = Process.whereis(Runtime.name(sys.instance, OneShot))
      assert %{"run" => {timer, token}} = :sys.get_state(runtime).timers
      assert Process.read_timer(timer) in 500..1_001

      TestClock.advance(sys.clock, 1_001)
      send(runtime, {:requeue, "run", token})
      await!(sys, :oneshot, "run", :gone)
    end

    test "a finished resource older than the ttl goes, however few there are" do
      sys = start_system(controllers: [OneShot])
      given_ready(sys, {:oneshot, "run", %{}}, condition: :done)
      assert %{status: %{finished: finished}} = Store.get(:oneshot, "run", sys.i)
      assert finished == TestClock.now(sys.clock)

      TestClock.advance(sys.clock, 1_000)
      resync(sys, OneShot)
      settle(sys)
      assert Store.get(:oneshot, "run", sys.i).status.finished == finished

      TestClock.advance(sys.clock, 1)
      resync(sys, OneShot)
      await!(sys, :oneshot, "run", :gone)
    end
  end

  describe "finalizers" do
    test "every controller's finalizer is on a resource from its creation, so a delete that beats them waits" do
      sys = start_system(controllers: [Kept, Tagger])
      shutdown(sys, true)

      {:ok, created} = Store.create(:kept, "k", %{}, sys.i)
      assert created.finalizers == [:kept, :tagged]

      # No controller has seen "k" yet.
      {:ok, _} = Store.delete(:kept, "k", sys.i)

      assert %Resource{deleting?: true, finalizers: [:kept, :tagged]} =
               Store.get(:kept, "k", sys.i)

      shutdown(sys, false)
      await!(sys, :kept, "k", :gone)
      settle(sys)
      assert {:tagger_saw_deleting, "k"} in notes(sys)
    end

    test "a controller is not shown a deleting resource before the finalizers it waits for are gone" do
      sys = start_system(controllers: [Kept, Tagger])
      given_ready(sys, {:kept, "k", %{}})
      await!(sys, :kept, "k", :tagged)
      settle(sys)
      put_fact(sys, {:untag, "k"}, :block)

      {:ok, _} = Store.delete(:kept, "k", sys.i)
      assert_receive {:untagging, "k", step}, sys.wait

      # The owner has heard of the delete and is at rest, having done nothing.
      settle(sys, only: [Kept])
      assert fact(sys, {:made, "k"}) == true
      assert %Resource{finalizers: [:kept, :tagged]} = Store.get(:kept, "k", sys.i)

      send(step, :go)
      await!(sys, :kept, "k", :gone)
      settle(sys)

      assert Enum.take(journal(sys), -2) == [{{:tagger, "k"}, :untag}, {{:kept, "k"}, :unmake}]
    end
  end
end
