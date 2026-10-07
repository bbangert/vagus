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

      assert journal(sys) |> Enum.filter(&(elem(&1, 0) == {Kept, "child"})) ==
               [{{Kept, "child"}, :make}, {{Kept, "child"}, :unmake}]

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

    test "what has expired is named by uid, and with no ttl only the count applies" do
      sys = start_system(controllers: [OneShot])
      for n <- 1..2, do: given_ready(sys, {:oneshot, "run-#{n}", %{}}, condition: :done)
      [first, second] = for run <- Store.list(:oneshot, sys.i), do: Resource.ref(run)
      %Stamp{} = now = TestClock.now(sys.clock)
      later = %{now | at: 10_000_000}

      assert Collector.expired(:oneshot, %{keep: 1, ttl_ms: :infinity}, later, sys.i) == [first]

      assert Collector.expired(:oneshot, %{keep: 2, ttl_ms: 1_000}, later, sys.i) == [
               second,
               first
             ]

      assert Collector.expired(:oneshot, %{keep: 2, ttl_ms: :infinity}, later, sys.i) == []
    end

    # Two finished resources past their ttl, and `hook` run in the step
    # right after the first of them is deleted: between the two deletes.
    defp between_expiries(opts, runtime, hook) do
      {:ok, cell} = Agent.start_link(fn -> nil end)

      between = fn _boundary ->
        due =
          Agent.get_and_update(cell, fn sys ->
            if sys != nil and Store.get(:oneshot, "run-2", sys.i) == nil,
              do: {sys, nil},
              else: {nil, sys}
          end)

        if due, do: hook.(due)
      end

      sys =
        start_system([controllers: [OneShot], runtime: [boundary: between] ++ runtime] ++ opts)

      for n <- 1..2, do: given_ready(sys, {:oneshot, "run-#{n}", %{}}, condition: :done)
      TestClock.advance(sys.clock, 100_001)
      Agent.update(cell, fn nil -> sys end)
      sys
    end

    defp expire(sys, step_of), do: fire_timer(sys, OneShot, step_of)

    test "a resource created under an expired name since the listing is not the one deleted" do
      sys =
        between_expiries([], [], fn sys ->
          {:ok, _} = Store.delete(:oneshot, "run-1", sys.i)
          {:ok, _} = Store.create(:oneshot, "run-1", %{"new" => true}, sys.i)
        end)

      old = Store.get(:oneshot, "run-1", sys.i)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          expire(sys, "run-2")
          await!(sys, :oneshot, "run-2", :gone)
          settle(sys)
        end)

      # Not a failure of the step either: there was nothing left to delete.
      # By name, since the log of every test running now is in here.
      refute log =~ "started from #{inspect(Runtime.name(sys.instance, OneShot))} terminating"

      assert %Resource{spec: %{"new" => true}, uid: uid} = Store.get(:oneshot, "run-1", sys.i)
      assert uid != old.uid
      assert %{failures: failures} = Runtime.info(OneShot, sys.i)
      assert failures == %{}
    end

    test "a shutdown that begins between two expiries stops the second" do
      sys = between_expiries([], [], fn sys -> shutdown(sys, true) end)

      expire(sys, "run-2")
      await!(sys, :oneshot, "run-2", :gone)
      settle(sys)
      assert %Resource{deleting?: false} = Store.get(:oneshot, "run-1", sys.i)

      # The step that was deleting is over, its own resource gone. The one
      # left goes when it is next looked at.
      shutdown(sys, false)
      expire(sys, "run-1")
      await!(sys, :oneshot, "run-1", :gone)
    end

    @tag :tmp_dir
    test "an expiry the store cannot write fails the step", %{tmp_dir: dir} do
      failing = :atomics.new(1, [])

      persist = fn path, data ->
        if :atomics.get(failing, 1) == 1,
          do: {:error, :enospc},
          else: Vagus.Resource.Persistence.write(path, data)
      end

      sys =
        between_expiries(
          [path: Path.join(dir, "resources.json"), persist: persist],
          [backoff: {60_000, 60_000}],
          fn _sys -> :ok end
        )

      :atomics.put(failing, 1, 1)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          expire(sys, "run-2")
          Runtime.info(OneShot, sys.i)
          settle(sys)
        end)

      assert log =~ ":commit_refused, {:oneshot, \"run-2\"}, {:persist_failed, :enospc}"
      assert %{failures: %{"run-2" => 1}} = Runtime.info(OneShot, sys.i)
      assert for(run <- Store.list(:oneshot, sys.i), do: run.name) == ["run-1", "run-2"]
    end

    test "a finished resource is looked at again when its ttl is up, without a resync" do
      sys = start_system(controllers: [OneShot])
      given_ready(sys, {:oneshot, "run", %{}}, condition: :done)

      assert pending_timer(sys, OneShot, "run").remaining in 90_000..100_001

      TestClock.advance(sys.clock, 100_001)
      fire_timer(sys, OneShot, "run")
      await!(sys, :oneshot, "run", :gone)
    end

    test "a finished resource older than the ttl goes, however few there are" do
      sys = start_system(controllers: [OneShot])
      given_ready(sys, {:oneshot, "run", %{}}, condition: :done)
      assert %{status: %{finished: finished}} = Store.get(:oneshot, "run", sys.i)
      assert finished == TestClock.now(sys.clock)

      TestClock.advance(sys.clock, 100_000)
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

    test "a controller that waits for another's finalizer is brought back by its removal" do
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

      assert Enum.take(journal(sys), -2) == [{{Tagger, "k"}, :untag}, {{Kept, "k"}, :unmake}]
    end
  end
end
