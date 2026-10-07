defmodule Vagus.Resource.HarnessTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Resource.Store
  alias Vagus.Resource.Toys.{Fragile, Kept, Linker, Probe, Tagger}

  @moduletag :capture_log
  @moduletag :scenario

  describe "killing a runtime at every effect-group boundary" do
    test "a lifecycle across four controllers ends the same wherever it is interrupted" do
      scenario = fn sys ->
        owner = given_ready(sys, {:probe, "p", %{}})
        given_ready(sys, {:link, "l", %{"target" => "p"}})
        given_ready(sys, {:kept, "k", %{}}, owner_refs: [Resource.ref(owner)])
        await!(sys, :kept, "k", :tagged)

        {:ok, _} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)
        await!(sys, :probe, "p", :ready)
        await!(sys, :link, "l", &(&1.status.sees == 2))

        {:ok, _} = Store.delete(:probe, "p", sys.i)
        await!(sys, :kept, "k", :gone)
        await!(sys, :link, "l", &(&1.status.sees == nil))
      end

      reference =
        Faults.each_boundary(
          system: [controllers: [Probe, Linker, Kept, Tagger]],
          scenario: scenario
        )

      assert reference.boundaries >= 10
      assert [%Resource{kind: :link, name: "l"}] = reference.store

      assert reference.journal == %{
               {:probe, "p"} => [visit: 1, visit: 2],
               {:kept, "k"} => [:make, :unmake],
               {:tagger, "k"} => [:tag, :untag]
             }
    end

    test "finds a controller whose action is only safe if the commit after it happens" do
      scenario = fn sys -> given_ready(sys, {:fragile, "f", %{}}) end

      assert_raise ExUnit.AssertionError, ~r/the store ends differently/, fn ->
        Faults.each_boundary(system: [controllers: [Fragile]], scenario: scenario)
      end
    end
  end

  describe "journal equivalence" do
    test "a repeated block is one occurrence; anything else is a difference" do
      assert Faults.collapse([]) == []
      assert Faults.collapse([:a, :a, :b, :c]) == [:a, :b, :c]
      assert Faults.collapse([:a, :b, :a, :b, :c]) == [:a, :b, :c]
      assert Faults.collapse([:a, :a, :b, :a, :b, :b]) == [:a, :b]
      assert Faults.collapse([:a, :b, :a]) == [:a, :b, :a]
      assert Faults.collapse([:start, :stop, :start]) == [:start, :stop, :start]
    end
  end

  describe "settle" do
    test "returns only when a change has gone through every runtime it wakes in turn" do
      sys = start_system(controllers: [Probe, Linker, Kept, Tagger])
      owner = given_ready(sys, {:probe, "p", %{}})
      {:ok, _} = Store.create(:link, "l", %{"target" => "p"}, sys.i)
      {:ok, _} = Store.create(:kept, "k", %{}, [owner_refs: [Resource.ref(owner)]] ++ sys.i)
      settle(sys)
      assert Store.get(:link, "l", sys.i).status.sees == 1
      assert fact(sys, {:tag, "k"}) == true and fact(sys, {:made, "k"}) == true

      {:ok, _} = Store.delete(:probe, "p", sys.i)
      settle(sys)
      assert Store.get(:kept, "k", sys.i) == nil
      assert Store.get(:link, "l", sys.i).status.sees == nil
      assert fact(sys, {:tag, "k"}) == false and fact(sys, {:made, "k"}) == false
    end

    test "does not return while a runtime woken by another's write is still at work" do
      sys = start_system(controllers: [Kept, Tagger])
      given_ready(sys, {:kept, "k", %{}})
      await!(sys, :kept, "k", :tagged)
      settle(sys)
      for step <- [:untag, :unmake], do: put_fact(sys, {step, "k"}, :block)

      {:ok, _} = Store.delete(:kept, "k", sys.i)
      settling = Task.async(fn -> settle(sys) end)

      # The owner is at rest, waiting for the tagger's finalizer. The
      # tagger's write is what sets it to work again.
      assert_receive {:untagging, "k", tagger}, 5_000
      send(tagger, :go)
      assert_receive {:unmaking, "k", owner}, 5_000

      assert Task.yield(settling, 100) == nil
      send(owner, :go)
      assert Task.await(settling) == :ok
      assert Store.get(:kept, "k", sys.i) == nil
    end
  end

  describe "await!" do
    test "raises with the resource as last seen" do
      sys = %{start_system(controllers: [Probe]) | wait: 50}
      put_fact(sys, :engine, :down)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      await!(%{sys | wait: 5_000}, :probe, "p", :progressing)

      error = assert_raise ExUnit.AssertionError, fn -> await!(sys, :probe, "p", :ready) end
      assert error.message =~ "probe/p never reached :ready"
      assert error.message =~ "engine_unavailable"
    end

    test "a condition about an earlier generation does not count" do
      sys = start_system(controllers: [Probe])
      given_ready(sys, {:probe, "p", %{}})
      shutdown(sys, true)
      {:ok, _} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)

      assert_raise ExUnit.AssertionError, fn -> await!(%{sys | wait: 50}, :probe, "p", :ready) end
      stale = await!(sys, :probe, "p", &(Resource.get_condition(&1, :ready).status == true))
      assert Resource.get_condition(stale, :ready).observed_generation < stale.generation
    end
  end
end
