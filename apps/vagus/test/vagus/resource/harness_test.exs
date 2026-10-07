defmodule Vagus.Resource.HarnessTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Resource.{Runtime, Store, TestInstance}
  alias Vagus.Resource.Toys.{Copycat, Fragile, Kept, Linker, Probe, Tagger, Twisted}

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

      # Every boundary of the undisturbed run was killed at, and both kinds.
      assert length(reference.boundaries) >= 20
      assert {Probe, "p", :action} in reference.boundaries
      assert {Tagger, "k", :commit} in reference.boundaries
      assert [%Resource{kind: :link, name: "l"}] = reference.store

      assert reference.journal == %{
               {Probe, "p"} => [visit: 1, visit: 2],
               {Kept, "k"} => [:make, :unmake],
               {Tagger, "k"} => [:tag, :untag]
             }
    end

    test "finds a controller whose action is only safe if the commit after it happens" do
      scenario = fn sys -> given_ready(sys, {:fragile, "f", %{}}) end

      assert_raise ExUnit.AssertionError, ~r/the store ends differently/, fn ->
        Faults.each_boundary(system: [controllers: [Fragile]], scenario: scenario)
      end
    end

    for {twist, interrupted} <- [
          {"missing", "[:b]"},
          {"extra", "[:repair, :a, :b]"},
          {"reorder", "[:b, :a]"}
        ] do
      test "fails on the actions when an interrupted run's are #{twist}" do
        scenario = fn sys -> given_ready(sys, {:twisted, "t", %{"twist" => unquote(twist)}}) end

        error =
          assert_raise ExUnit.AssertionError, fn ->
            Faults.each_boundary(system: [controllers: [Twisted]], scenario: scenario)
          end

        assert error.message =~ ~s(killed after {Vagus.Resource.Toys.Twisted, "t", :commit} #1)
        assert error.message =~ ~s(the actions for {Vagus.Resource.Toys.Twisted, "t"} differ)
        assert error.message =~ "undisturbed: [:a, :b]"
        assert error.message =~ "interrupted: #{unquote(interrupted)}"
      end
    end

    test "fails when an interrupted run never reaches the boundary it was to be killed at" do
      runs = :counters.new(1, [])

      # Only the undisturbed run has a second probe.
      scenario = fn sys ->
        :counters.add(runs, 1, 1)
        given_ready(sys, {:probe, "a", %{}})
        if :counters.get(runs, 1) == 1, do: given_ready(sys, {:probe, "b", %{}})
      end

      assert_raise ExUnit.AssertionError,
                   ~r/"b", :action} #1: the run never crossed that boundary/,
                   fn ->
                     Faults.each_boundary(
                       system: [controllers: [Probe]],
                       scenario: scenario,
                       normalize: fn _store -> :same end,
                       equivalent: fn _reference, _interrupted -> true end
                     )
                   end
    end

    test "fails on the actions when a controller that was not killed repeats one" do
      # `Fragile` counts twice when cut after its action; `Copycat` copies
      # each count. Only the first of the two was interrupted.
      scenario = fn sys ->
        given_ready(sys, {:copycat, "c", %{"target" => "f"}})
        given_ready(sys, {:fragile, "f", %{}})
        await!(sys, :copycat, "c", :ready)
      end

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Faults.each_boundary(
            system: [controllers: [Copycat, Fragile]],
            scenario: scenario,
            normalize: fn _store -> :same end
          )
        end

      assert error.message =~ ~s(killed after {Vagus.Resource.Toys.Fragile, "f", :action} #1)
      assert error.message =~ ~s(the actions for {Vagus.Resource.Toys.Copycat, "c"} differ)
      assert error.message =~ "undisturbed: [:copy]"
      assert error.message =~ "interrupted: [:copy, :copy]"
    end

    test "fails a scenario that crosses no boundary" do
      assert_raise ExUnit.AssertionError, ~r/crosses no boundary/, fn ->
        Faults.each_boundary(system: [controllers: [Probe]], scenario: fn _sys -> :ok end)
      end
    end

    test "takes a rule of the scenario's own in place of the default" do
      scenario = fn sys -> given_ready(sys, {:twisted, "t", %{"twist" => "extra"}}) end
      anything = fn _reference, _interrupted -> true end

      assert %{journal: %{{Twisted, "t"} => [:a, :b]}} =
               Faults.each_boundary(
                 system: [controllers: [Twisted]],
                 scenario: scenario,
                 equivalent: anything
               )
    end

    test "a kill aimed at a runtime that is already dead is reported, not waited for" do
      instance = TestInstance.name()
      label = {Probe, "p", :commit}
      faults = start_supervised!({Faults, {instance, {:kill_at, {label, 1}}}})
      {dead, monitor} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}

      boundary = %{runtime: dead, controller: Probe, kind: :probe, name: "p", after: :commit}
      assert Faults.boundary(faults, boundary) == :ok

      assert %{crossed: [^label], kill: {:error, reason}} = Faults.report(faults)
      assert reason =~ "the runtime of Vagus.Resource.Toys.Probe was already dead"
    end
  end

  describe "journal equivalence" do
    test "an interrupted journal is the reference with one replay in it" do
      reference = [:a, :b, :c]

      for replay <- [[:a, :b, :c], [:a, :a, :b, :c], [:a, :b, :b, :c], [:a, :b, :a, :b, :c]] do
        assert Faults.replay?(reference, replay), inspect(replay)
      end

      assert Faults.replay?([:a, :b, :c], [:a, :b, :c, :a, :b, :c])
      assert Faults.replay?([], [])
    end

    test "nothing may be missing, added or moved, and a repeat must be a re-run" do
      reference = [:a, :b, :c]

      for other <- [
            [:a, :b],
            [:b, :c],
            [:a, :c],
            [],
            [:a, :b, :c, :d],
            [:a, :x, :b, :c],
            [:b, :a, :c],
            [:a, :b, :c, :a],
            [:a, :a, :b, :b, :c]
          ] do
        refute Faults.replay?(reference, other), inspect(other)
      end

      # The reference is taken as it is, not reduced.
      refute Faults.replay?([:visit, :visit], [:visit])
      refute Faults.replay?([:make, :unmake, :make, :unmake], [:make, :unmake])
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
      assert_receive {:untagging, "k", tagger}, sys.wait
      send(tagger, :go)
      assert_receive {:unmaking, "k", owner}, sys.wait

      assert Task.yield(settling, 100) == nil
      send(owner, :go)
      assert Task.await(settling) == :ok
      assert Store.get(:kept, "k", sys.i) == nil
    end
  end

  describe "settle with timers" do
    test "waits out a pending timer when asked to, and otherwise leaves it pending" do
      sys = start_system(controllers: [Probe], runtime: [unavailable_retry: 50])
      put_fact(sys, :engine, :down)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      await!(sys, :probe, "p", :progressing)
      put_fact(sys, :engine, :up)

      settle(sys, timers: :none)
      assert %{timers: [], in_flight: in_flight} = Runtime.info(Probe, sys.i)
      assert in_flight == %{}
      assert %{status: true} = Resource.get_condition(Store.get(:probe, "p", sys.i), :ready)
    end

    test "raises when a timer is still pending at the deadline" do
      sys = %{start_system(controllers: [Probe]) | wait: 50}
      put_fact(sys, {:requeue, "p"}, 600_000)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      await!(%{sys | wait: 5_000}, :probe, "p", :ready)

      assert settle(sys) == :ok

      assert_raise ExUnit.AssertionError, ~r/never came to rest/, fn ->
        settle(sys, timers: :none)
      end
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
