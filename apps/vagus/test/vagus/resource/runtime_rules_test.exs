defmodule Vagus.Resource.RuntimeRulesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.{Controller, Kind, Lanes, Runtime, Store, TestInstance}

  alias Vagus.Resource.Toys.{
    Bare,
    Broken,
    Clasher,
    Echo,
    Flaky,
    Follower,
    Grabber,
    Idle,
    Kept,
    Mute,
    Probe,
    Shapeless,
    Solo,
    Sticky,
    Wild
  }

  @moduletag :capture_log
  @moduletag :scenario

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

      # The replacement is looked at for having been found, and clean.
      await!(sys, :probe, "p", :ready)
      settle(sys)
      assert Store.get(:probe, "p", sys.i).status[:last_error] == nil
      assert %{failures: failures, timers: []} = Runtime.info(Probe, sys.i)
      assert failures == %{}
    end

    test "is not charged to a replacement the store already holds when the step crashes" do
      sys =
        start_system(
          controllers: [Probe],
          runtime: [backoff: {60_000, 60_000}, deliver_events: false]
        )

      put_fact(sys, {:observe, "p"}, :block)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      resync(sys, Probe)
      assert_receive {:observing, "p", step}, sys.wait

      # Neither the removal nor the new resource is ever announced: the
      # crash is all the runtime hears, with the replacement in the store.
      {:ok, _} = Store.delete(:probe, "p", sys.i)
      {:ok, %{uid: uid}} = Store.create(:probe, "p", %{}, sys.i)
      put_fact(sys, {:observe, "p"}, nil)
      Process.exit(step, :kill)

      assert %{uid: ^uid} = await!(sys, :probe, "p", :ready)
      settle(sys)
      assert %{failures: failures, timers: []} = Runtime.info(Probe, sys.i)
      assert failures == %{}
    end

    test "nothing remembered of a resource is found by one a resync finds in its place" do
      sys =
        start_system(
          controllers: [Sticky],
          runtime: [backoff: {60_000, 60_000}, deliver_events: false]
        )

      known = fn -> :sys.get_state(runtime(sys, Sticky)) |> Map.take([:known, :refs_in]) end
      {:ok, _} = Store.create(:sticky, "a", %{"target" => "old"}, sys.i)
      {:ok, _} = Store.create(:sticky, "b", %{"target" => "old", "fail" => true}, sys.i)
      resync(sys, Sticky)
      settle(sys)

      # Everything there is to remember: a repeated pass being paced, a
      # failed action, timers, references.
      assert %{known: %{"a" => a, "b" => b}, refs_in: %{{:probe, "old"} => [_, _]}} = known.()
      assert %{failures: 1, acted: :nudge, timer: {_, _}, refs: [probe: "old"]} = a
      assert %{failures: 2, failed: %{reason: :stuck}, timer: {_, _}, refs: [probe: "old"]} = b

      for name <- ["a", "b"] do
        {:ok, _} = Store.delete(:sticky, name, sys.i)
        {:ok, _} = Store.create(:sticky, name, %{"target" => "new"}, sys.i)
      end

      # Found by the listing, and held before any step can add to it.
      shutdown(sys, true)
      resync(sys, Sticky)
      settle(sys)
      fresh = &%{uid: &1, failures: 0, failed: nil, acted: nil, timer: nil, refs: []}

      assert known.() == %{
               known: Map.new(Store.list(:sticky, sys.i), &{&1.name, fresh.(&1.uid)}),
               refs_in: %{}
             }

      notes(sys)
      shutdown(sys, false)
      settle(sys, only: [Sticky])

      assert %{known: %{"a" => a, "b" => b}, refs_in: refs_in} = known.()
      assert %{failures: 1, failed: nil, refs: [probe: "new"]} = a
      assert %{failures: 1, failed: nil, refs: [probe: "new"]} = b
      assert Map.keys(refs_in) == [{:probe, "new"}]
      assert notes(sys) |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [nil]
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

  describe "supervision" do
    test "every supervisor in the subtree is given all the time it needs to stop" do
      sys = start_system(controllers: [Probe])
      controllers = Vagus.Resource.Controllers.Supervisor.name(sys.instance)
      pair = Vagus.Resource.Controllers.Supervisor.pair(sys.instance, Probe)

      assert {:ok, %{type: :supervisor, shutdown: :infinity, restart: :permanent}} =
               :supervisor.get_childspec(controllers, Probe)

      assert {:ok, %{type: :supervisor, shutdown: :infinity}} =
               :supervisor.get_childspec(pair, Runtime.tasks(sys.instance, Probe))

      assert {:ok, %{type: :worker, shutdown: 5_000}} = :supervisor.get_childspec(pair, Runtime)

      for child <- [Vagus.Resource.Controllers.Supervisor, Store] do
        assert {:ok, %{type: :supervisor, shutdown: :infinity}} =
                 :supervisor.get_childspec(Module.concat(sys.instance, Supervisor), child)
      end
    end
  end

  describe "what the controllers declare" do
    test "two controllers declaring one condition type fail the start, by name" do
      assert {:error, reason} = TestInstance.start(controllers: [Kept, Clasher], kinds: %{})

      assert inspect(reason) =~
               "Vagus.Resource.Toys.Kept and Vagus.Resource.Toys.Clasher both declare " <>
                 "condition :ready on kind :kept"
    end

    test "two controllers declaring one finalizer on a kind fail the start, by name" do
      assert {:error, reason} = TestInstance.start(controllers: [Kept, Grabber], kinds: %{})

      assert inspect(reason) =~
               "Vagus.Resource.Toys.Kept and Vagus.Resource.Toys.Grabber both declare " <>
                 "finalizer :kept on kind :kept"

      # The same controller twice is one controller.
      assert {:ok, _instance} = TestInstance.start(controllers: [Kept, Kept], kinds: %{})
    end

    test "a declaration that raises fails the start, naming the controller and the callback" do
      assert {:error, reason} = TestInstance.start(controllers: [Kept, Broken], kinds: %{})

      assert inspect(reason) =~
               "Vagus.Resource.Toys.Broken.retention/0 failed: ** (RuntimeError) no idea"

      assert_raise ArgumentError, ~r/Broken.retention\/0 failed/, fn ->
        Controller.declare(Broken)
      end

      assert %{kind: :kept, owner?: true, conditions: [:ready], finalizer: :kept, retention: nil} =
               Controller.declare(Kept)
    end

    test "a declaration of the wrong shape fails the start, naming the controller and the callback" do
      assert {:error, reason} = TestInstance.start(controllers: [Bare], kinds: %{})

      assert inspect(reason) =~
               "Vagus.Resource.Toys.Bare.condition_types/0 returned :ready, not a list of atoms"

      for {callback, malformed, expected} <- [
            {:kind, "shapeless", "an atom other than nil"},
            {:kind, nil, "an atom other than nil"},
            {:condition_types, :ready, "a list of atoms"},
            {:condition_types, %{ready: true}, "a list of atoms"},
            {:condition_types, [:ready | :failed], "a list of atoms"},
            {:condition_types, ["ready"], "a list of atoms"},
            {:retention, %{keep: 3}, "%{keep: count, ttl_ms: ms | :infinity}"},
            {:retention, %{keep: -1, ttl_ms: 0}, "%{keep: count, ttl_ms: ms | :infinity}"},
            {:retention, [keep: 1, ttl_ms: 1], "%{keep: count, ttl_ms: ms | :infinity}"},
            {:finalizer, "shapeless", "an atom other than nil"},
            {:writer_entries, ["holds"], "a list of spec paths"},
            {:writer_entries, %{}, "a list of spec paths"}
          ] do
        Process.put({Shapeless, callback}, malformed)

        message =
          "Vagus.Resource.Toys.Shapeless.#{callback}/0 returned #{inspect(malformed)}, " <>
            "not #{expected}"

        assert_raise ArgumentError, message, fn -> Controller.declare(Shapeless) end
        Process.delete({Shapeless, callback})
      end

      assert %{kind: :shapeless, conditions: [:ready], writer_entries: [["holds"]]} =
               Controller.declare(Shapeless)
    end

    test "who owns a kind and who writes which condition is the store's from its start" do
      sys = start_system(controllers: [Kept, Mute, Echo])
      store = :sys.get_state(Process.whereis(Store.name(sys.instance)))

      assert %{kept: %Kind{owner: Kept, conditions: %{ready: Kept}}} = store.kinds
      assert %Kind{owner: Mute, conditions: %{ready: Mute, heard: Echo}} = store.kinds.mute
    end

    test "a kind given to the store that a controller also owns fails the start, by name" do
      assert {:error, reason} =
               TestInstance.start(controllers: [Kept], kinds: %{kept: [finalizers: [:mine]]})

      assert inspect(reason) =~
               "kind :kept is given in :kinds and owned by Vagus.Resource.Toys.Kept"

      assert {:ok, _instance} = TestInstance.start(controllers: [Kept], kinds: %{part: []})
    end

    test "something that is no controller fails the start, by name" do
      assert {:error, reason} = TestInstance.start(controllers: [nil], kinds: %{})
      assert inspect(reason) =~ "could not load module nil"
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

    test "a pass that performs the action the pass before performed is spaced out, whatever its arguments" do
      sys = start_system(controllers: [Idle], runtime: [backoff: {60_000, 60_000}])

      {:ok, _} = Store.create(:idle, "i", %{}, sys.i)
      settle(sys)

      # The first is followed at once, as any pass that acted is. The two
      # nudges had different arguments.
      assert journal(sys) == [{{Idle, "i"}, :nudge}, {{Idle, "i"}, :nudge}]
      assert fact(sys, {:nudges, "i"}) == 2
      assert %{steps: 2, timers: ["i"]} = Runtime.info(Idle, sys.i)
    end

    test "a pass that performs no action in between ends the run of repeats" do
      sys =
        start_system(
          controllers: [Idle],
          runtime: [backoff: {60_000, 60_000}, unavailable_retry: 600_000]
        )

      {:ok, _} = Store.create(:idle, "i", %{}, sys.i)
      settle(sys)
      assert %{steps: 2, timers: ["i"]} = Runtime.info(Idle, sys.i)

      put_fact(sys, :engine, :down)
      fire_timer(sys, Idle, "i")
      settle(sys)
      assert %{steps: 3, timers: ["i"]} = Runtime.info(Idle, sys.i)

      # The nudge after the engine is back is the first of a new run: it is
      # followed at once, and only that one waits.
      put_fact(sys, :engine, :up)
      fire_timer(sys, Idle, "i")
      settle(sys)
      assert %{steps: 5, timers: ["i"]} = Runtime.info(Idle, sys.i)
      assert length(journal(sys)) == 4
    end

    test "an observation that cannot be made is looked at again after the sooner of the two delays" do
      for {retry, armed} <- [{600_000, 50_000}, {10_000, 10_000}] do
        sys = start_system(controllers: [Idle], runtime: [unavailable_retry: retry])
        put_fact(sys, :engine, :down)

        {:ok, _} = Store.create(:idle, "i", %{"requeue" => 50_000}, sys.i)
        settle(sys)

        assert pending_timer(sys, Idle, "i").remaining in (armed - 5_000)..armed
        stop_system(sys)
      end
    end

    test "of several timed re-queues the soonest is armed" do
      sys = start_system(controllers: [Wild])
      given_ready(sys, {:wild, "w", %{"effect" => "requeues"}})

      assert pending_timer(sys, Wild, "w").remaining in 290_000..300_000
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

  describe "a commit that changes nothing" do
    test "is told apart at the boundary, whatever ops it is made of" do
      test = self()
      boundary = fn info -> send(test, {:boundary, info.after}) end
      sys = start_system(controllers: [Wild], runtime: [boundary: boundary])

      # The first pass writes the verdict beside its three idle ops.
      given_ready(sys, {:wild, "w", %{"effect" => "noop"}})
      assert_received {:boundary, :commit}

      # From then on the verdict is there too, and nothing is new.
      resync(sys, Wild)
      settle(sys)
      assert_received {:boundary, :idle_commit}
      refute_received {:boundary, :commit}
      assert Store.get(:wild, "w", sys.i).generation == 1
    end
  end

  describe "a step that cannot go on" do
    setup do
      %{sys: start_system(controllers: [Wild, Probe], runtime: [backoff: {60_000, 60_000}])}
    end

    for {effect, logged} <- [
          {"refused", ":commit_refused, {:wild, \"w\"}, :not_found"},
          {"expect_generation",
           ":commit_refused, {:wild, \"w\"}, {:precondition, {:wild, \"w\"}, :generation}"},
          {"bad_act", "Vagus.Resource.Toys.Wild.act/3 returned :done"}
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

    for {effect, logged} <- [
          {"non_effect", "not effects: [status: %{}]"},
          {"two_actions", "more than one action in a pass, or an op after the action"},
          {"op_after_action", "more than one action in a pass, or an op after the action"},
          {"op_after_requeue", "more than one action in a pass, or an op after the action"},
          {"no_pair", "Vagus.Resource.Toys.Wild.reconcile/2 returned :nothing"}
        ] do
      test "fails with nothing written or done when its controller returns #{effect}",
           %{sys: sys} do
        log =
          capture_log(fn ->
            {:ok, created} = Store.create(:wild, "w", %{"effect" => unquote(effect)}, sys.i)
            settle(sys)
            # Neither the verdict nor the op that came before what was wrong.
            assert Store.get(:wild, "w", sys.i) == created
          end)

        assert log =~ unquote(logged)
        refute log =~ "act/3 returned"
        assert %{failures: %{"w" => 1}, timers: ["w"], steps: 1} = Runtime.info(Wild, sys.i)
      end
    end

    test "goes on when a re-queue follows its action", %{sys: sys} do
      log =
        capture_log(fn ->
          {:ok, _} = Store.create(:wild, "w", %{"effect" => "requeue_after_action"}, sys.i)
          assert_receive {:fine, "w"}, sys.wait
          settle(sys)
        end)

      refute log =~ "more than one action"
      assert %{status: true} = Resource.get_condition(Store.get(:wild, "w", sys.i), :ready)
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
