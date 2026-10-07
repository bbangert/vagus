defmodule Vagus.Resource.RuntimeRulesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.{Lanes, Runtime, Store, TestInstance}

  alias Vagus.Resource.Toys.{
    Clasher,
    Echo,
    Flaky,
    Follower,
    Idle,
    Kept,
    Last,
    Mute,
    Probe,
    Solo,
    Wild
  }

  @moduletag :capture_log
  @moduletag :scenario

  defmodule Squatter do
    @moduledoc "Wants to own `:thing`."
    @behaviour Vagus.Resource.Controller
    def kind, do: :thing
    def condition_types, do: [:ready]
    def observe(_resource, _context), do: nil
    def reconcile(_resource, _observed), do: {:no_verdict, []}
    def act(_action, _args, _context), do: :ok
  end

  defp runtime(sys, controller), do: Process.whereis(Runtime.name(sys.instance, controller))

  describe "a controller's code runs in steps only" do
    test "a references/1 that exits, and one that never returns, cost only their own resources" do
      sys = start_system(controllers: [Wild, Probe], runtime: [backoff: {60_000, 60_000}])
      before = for controller <- sys.controllers, do: runtime(sys, controller)
      supervisor = Process.whereis(Module.concat(sys.instance, Supervisor))

      {:ok, _} = Store.create(:wild, "exits", %{"refs" => "exit"}, sys.i)
      settle(sys)
      assert %{failures: %{"exits" => 1}, timers: ["exits"], steps: 1} = Runtime.info(Wild, sys.i)

      # This one's step never ends, so from here on the system never rests.
      {:ok, _} = Store.create(:wild, "hangs", %{"refs" => "hang"}, sys.i)
      given_ready(sys, {:wild, "fine", %{}}, settle: false)
      given_ready(sys, {:probe, "p", %{}}, settle: false)
      assert %{in_flight: %{"hangs" => _step}, failures: %{"exits" => 1}} = info(sys, Wild)

      assert for(controller <- sys.controllers, do: runtime(sys, controller)) == before
      assert Process.whereis(Module.concat(sys.instance, Supervisor)) == supervisor
      assert Store.get(:wild, "exits", sys.i).status == %{}
    end

    test "a reference to itself is not indexed" do
      sys = start_system(controllers: [Wild, Probe])
      given_ready(sys, {:wild, "w", %{"refs" => "self"}})

      assert %{references: %{"w" => [probe: "elsewhere"]}} = Runtime.info(Wild, sys.i)
    end

    test "a reference learnt from a step is acted on even if its change came first" do
      sys = start_system(controllers: [Probe, Follower])
      given_ready(sys, {:probe, "p", %{}})
      put_fact(sys, {:follow, "f"}, :block)

      {:ok, _} = Store.create(:follower, "f", %{"target" => "p"}, sys.i)
      assert_receive {:following, "f", step}, sys.wait

      # The step has read the probe. Its runtime does not know yet that "f"
      # refers to it, so this change wakes nothing.
      {:ok, _} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)
      await!(sys, :probe, "p", :ready)
      assert %{references: references, dirty: []} = info(sys, Follower)
      assert references == %{}

      put_fact(sys, {:follow, "f"}, nil)
      send(step, :go)
      settle(sys)
      assert notes(sys) == [{:followed, "f", 1}, {:followed, "f", 2}]
      assert %{references: %{"f" => [probe: "p"]}, steps: 2} = Runtime.info(Follower, sys.i)
    end
  end

  describe "a step's result" do
    test "is about the resource it read, not a later one of the same name" do
      sys = start_system(controllers: [Probe], runtime: [backoff: {60_000, 60_000}])
      put_fact(sys, {:act, "p"}, :block)

      {:ok, %{uid: first}} = Store.create(:probe, "p", %{}, sys.i)
      assert_receive {:acting, "p", 1, step}, sys.wait

      {:ok, _} = Store.delete(:probe, "p", sys.i)
      {:ok, %{uid: second}} = Store.create(:probe, "p", %{}, sys.i)
      assert first != second

      # The action of the first "p" fails only now.
      put_fact(sys, {:act, "p"}, nil)
      send(step, {:fail, :boom})

      ready = await!(sys, :probe, "p", :ready)
      settle(sys)
      assert ready.uid == second
      assert Store.get(:probe, "p", sys.i).status[:last_error] == nil
      assert %{failures: failures, timers: []} = Runtime.info(Probe, sys.i)
      assert failures == %{}
    end

    test "is recognised by its uid when the namesake was never announced" do
      sys =
        start_system(
          controllers: [Probe],
          runtime: [backoff: {60_000, 60_000}, deliver_events: false]
        )

      put_fact(sys, {:act, "p"}, :block)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      resync(sys, Probe)
      assert_receive {:acting, "p", 1, step}, sys.wait

      {:ok, _} = Store.delete(:probe, "p", sys.i)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      put_fact(sys, {:act, "p"}, nil)
      send(step, {:fail, :boom})
      settle(sys)
      assert %{failures: failures, timers: [], steps: 1} = Runtime.info(Probe, sys.i)
      assert failures == %{}

      resync(sys, Probe)
      await!(sys, :probe, "p", :ready)
      assert Store.get(:probe, "p", sys.i).status[:last_error] == nil
    end

    test "is not believed of a namesake even when the step crashed" do
      sys = start_system(controllers: [Probe], runtime: [backoff: {60_000, 60_000}])
      put_fact(sys, {:observe, "p"}, :block)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      assert_receive {:observing, "p", step}, sys.wait

      {:ok, _} = Store.delete(:probe, "p", sys.i)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      assert %{dirty: ["p"]} = info(sys, Probe)

      put_fact(sys, {:observe, "p"}, nil)
      Process.exit(step, :kill)

      await!(sys, :probe, "p", :ready)
      settle(sys)
      assert %{failures: failures, timers: []} = Runtime.info(Probe, sys.i)
      assert failures == %{}
    end
  end

  describe "registration" do
    test "two controllers declaring one condition type fail the start, by name" do
      assert {:error, reason} = TestInstance.start(controllers: [Kept, Clasher], kinds: %{})

      assert inspect(reason) =~
               "Vagus.Resource.Toys.Kept and Vagus.Resource.Toys.Clasher both declare " <>
                 "condition :ready on kind :kept"
    end

    test "a registration the store refuses stops the runtime with that reason" do
      instance = TestInstance.start!()
      i = [instance: instance]
      :ok = Store.register_kind(:thing, Somebody, [conditions: [:ready]] ++ i)
      Process.flag(:trap_exit, true)

      {:ok, runtime} =
        Runtime.start_link([controller: Squatter, tasks: Runtime.tasks(instance, Squatter)] ++ i)

      assert_receive {:EXIT, ^runtime,
                      {:registration_refused, Squatter, {:kind_owned, Somebody}}},
                     5_000
    end
  end

  describe "priority" do
    test "is what a step's action waits for its lane with" do
      sys = start_system(controllers: [Probe], lanes: %{pull: 1})
      lanes = Process.whereis(Lanes.name(sys.instance))

      :erlang.trace(lanes, true, [:receive])
      given_ready(sys, {:probe, "p", %{"lane" => true, "priority" => 7}})
      :erlang.trace(lanes, false, [:receive])

      assert_received {:trace, ^lanes, :receive, {:"$gen_call", _from, {:acquire, :pull, 7}}}
    end
  end

  describe "pacing" do
    test "a step that changes its own status and then crashes still waits for its timer" do
      sys = start_system(controllers: [Flaky], runtime: [backoff: {60_000, 60_000}])

      {:ok, _} = Store.create(:flaky, "f", %{}, sys.i)
      settle(sys)

      # Its own write was announced to its runtime like anybody's.
      assert Store.get(:flaky, "f", sys.i).status.attempt == 1
      assert %{steps: 1, failures: %{"f" => 1}, timers: ["f"]} = Runtime.info(Flaky, sys.i)
    end

    test "a pass that performs the same actions as the pass before is spaced out" do
      sys = start_system(controllers: [Idle], runtime: [backoff: {60_000, 60_000}])

      {:ok, _} = Store.create(:idle, "i", %{}, sys.i)
      settle(sys)

      # The first is followed at once, as any pass that acted is.
      assert journal(sys) == [{{:idle, "i"}, :nudge}, {{:idle, "i"}, :nudge}]
      assert %{steps: 2, timers: ["i"]} = Runtime.info(Idle, sys.i)
    end

    test "of several timed re-queues the soonest is armed" do
      sys = start_system(controllers: [Wild])
      given_ready(sys, {:wild, "w", %{"effect" => "requeues"}})

      %{"w" => {timer, _token}} = :sys.get_state(runtime(sys, Wild)).timers
      assert Process.read_timer(timer) in 290_000..300_000
    end
  end

  describe "one step per resource" do
    test "a second is not started while the first runs, whatever arrives" do
      sys = start_system(controllers: [Solo])
      put_fact(sys, {:observe, "s"}, :block)

      {:ok, _} = Store.create(:solo, "s", %{}, sys.i)
      assert_receive {:observing, "s", step}, sys.wait
      for n <- 1..3, do: {:ok, _} = Store.update_spec(:solo, "s", %{"n" => n}, sys.i)
      resync(sys, Solo)

      assert %{steps: 1, in_flight: %{"s" => ^step}, dirty: ["s"]} = info(sys, Solo)

      put_fact(sys, {:observe, "s"}, nil)
      send(step, :go)
      await!(sys, :solo, "s", :ready)

      for n <- 4..40, do: {:ok, _} = Store.update_spec(:solo, "s", %{"n" => n}, sys.i)
      await!(sys, :solo, "s", :ready)
      settle(sys)
      assert fact(sys, {:seen, "s"}) == 40
      assert notes(sys) == []
    end
  end

  describe "a step that cannot go on" do
    setup do
      %{sys: start_system(controllers: [Wild, Probe], runtime: [backoff: {60_000, 60_000}])}
    end

    for {effect, logged} <- [
          {"refused", ":commit_refused, {:wild, \"w\"}, :not_found"},
          {"bad_act", "Vagus.Resource.Toys.Wild.act/3 returned :done"},
          {"non_effect", "not effects: [status: %{}]"}
        ] do
      test "fails and is retried when its controller returns #{effect}", %{sys: sys} do
        before = runtime(sys, Wild)

        log =
          capture_log(fn ->
            {:ok, _} = Store.create(:wild, "w", %{"effect" => unquote(effect)}, sys.i)
            settle(sys)
          end)

        assert log =~ unquote(logged)
        assert %{failures: %{"w" => 1}, timers: ["w"], steps: 1} = Runtime.info(Wild, sys.i)
        assert runtime(sys, Wild) == before
      end
    end

    test "gives back the lane its failed action held", %{sys: sys} do
      put_fact(sys, {:act, "p"}, {:error, :boom})

      {:ok, _} = Store.create(:probe, "p", %{"lane" => true}, sys.i)
      await!(sys, :probe, "p", &(&1.status[:last_error] == :boom))
      settle(sys)

      assert %{pull: %{held: [], waiting: 0}} = Lanes.info(sys.i)
    end
  end

  describe "an attached controller" do
    test "writes its conditions and nothing else: no generation mark, no finished stamp" do
      sys = start_system(controllers: [Mute, Echo])
      {:ok, _} = Store.create(:mute, "m", %{}, sys.i)
      {:ok, _} = Store.update_spec(:mute, "m", %{"more" => true}, sys.i)
      settle(sys)

      assert %{generation: 2, status: status} = Store.get(:mute, "m", sys.i)
      assert status == %{conditions: %{heard: Resource.condition(:heard, true, :loud, 2)}}
    end

    test "is refused a verdict that carries other status" do
      sys = start_system(controllers: [Mute, Echo], runtime: [backoff: {60_000, 60_000}])

      log =
        capture_log(fn ->
          {:ok, _} = Store.create(:mute, "m", %{"nosy" => true}, sys.i)
          settle(sys)
        end)

      assert log =~ "verdict on mute/m refused: [:status_not_owned]"
      assert Store.get(:mute, "m", sys.i).status == %{}
      assert %{failures: %{"m" => 1}} = Runtime.info(Echo, sys.i)
    end
  end

  describe "finalize_after" do
    test "holds a controller back until every finalizer it names is gone, and only when deleting" do
      sys = start_system(controllers: [Last])
      given_ready(sys, {:last, "l", %{}}, finalizers: [:a, :b])

      {:ok, _} = Store.delete(:last, "l", sys.i)
      settle(sys)
      assert %Resource{finalizers: [:last, :a, :b]} = Store.get(:last, "l", sys.i)

      {:ok, _} = Store.remove_finalizer(:last, "l", :a, sys.i)
      settle(sys)
      assert %Resource{finalizers: [:last, :b]} = Store.get(:last, "l", sys.i)

      {:ok, _} = Store.remove_finalizer(:last, "l", :b, sys.i)
      await!(sys, :last, "l", :gone)
    end
  end

  describe "the generation a verdict is about" do
    test "is the one its pass read, however far the spec has moved by the time it is written" do
      sys = start_system(controllers: [Probe])
      put_fact(sys, {:observe, "p"}, :block)
      put_fact(sys, {:act, "p"}, :block)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      assert_receive {:observing, "p", observing}, sys.wait
      {:ok, %{generation: 2}} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)

      # The verdict is written before the action, which now holds the pass.
      put_fact(sys, {:observe, "p"}, nil)
      send(observing, :go)
      assert_receive {:acting, "p", 1, acting}, sys.wait

      stale = Store.get(:probe, "p", sys.i)
      assert stale.generation == 2

      assert %{observed_generation: 1, reason: :visiting} =
               Resource.get_condition(stale, :progressing)

      assert %{observed_generation: 1} = Resource.get_condition(stale, :ready)
      assert stale.status.observed_generation == 1

      put_fact(sys, {:act, "p"}, nil)
      send(acting, :go)
      ready = await!(sys, :probe, "p", :ready)
      assert Resource.get_condition(ready, :ready).observed_generation == 2
      assert fact(sys, {:seen, "p"}) == 2
    end
  end
end
