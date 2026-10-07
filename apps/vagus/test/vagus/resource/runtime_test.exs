defmodule Vagus.Resource.RuntimeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Vagus.Resource.Harness

  alias Vagus.Resource
  alias Vagus.Resource.{Lanes, Runtime, Store}
  alias Vagus.Resource.Toys.{Batch, Kept, Linker, Probe, Scribe, Sloppy, Stubborn, Tagger}

  @moduletag :capture_log
  @moduletag :scenario

  defp condition(sys, kind, name, type),
    do: Resource.get_condition(Store.get(kind, name, sys.i), type)

  # Delivers the message of the timer pending for `name` now, and returns
  # how long the timer still had to run.
  defp fire_timer(sys, controller, name) do
    runtime = Process.whereis(Runtime.name(sys.instance, controller))
    %{^name => {timer, token}} = :sys.get_state(runtime).timers
    send(runtime, {:requeue, name, token})
    # A call from here is behind that message; a settle might not be.
    Runtime.info(controller, sys.i)
    Process.read_timer(timer)
  end

  describe "the queue" do
    test "a change that arrives during a step is not lost: the key runs once more" do
      sys = start_system(controllers: [Probe])
      given_ready(sys, {:probe, "p", %{}})

      put_fact(sys, {:observe, "p"}, :block)
      resync(sys, Probe)
      assert_receive {:observing, "p", step}, sys.wait

      for n <- 2..4, do: {:ok, _} = Store.update_spec(:probe, "p", %{"n" => n}, sys.i)

      # Three changes, one member of a set, and nothing queued behind the step.
      assert %{dirty: ["p"], queued: [], in_flight: %{"p" => ^step}} = info(sys, Probe)

      # The step in flight read `n: 1`, which the world already has: it ends
      # with nothing to do, and only the dirty mark takes the key further.
      put_fact(sys, {:observe, "p"}, nil)
      send(step, :go)

      await!(sys, :probe, "p", :ready)
      settle(sys)
      assert fact(sys, {:seen, "p"}) == 4
      assert journal(sys) == [{{:probe, "p"}, {:visit, 1}}, {{:probe, "p"}, {:visit, 4}}]
    end

    test "a crashed step frees its key and backs off, and the runtime survives" do
      sys = start_system(controllers: [Probe], runtime: [backoff: {60_000, 60_000}])
      runtime = Process.whereis(Runtime.name(sys.instance, Probe))
      put_fact(sys, {:observe, "p"}, :raise)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      settle(sys)

      assert %{failures: %{"p" => 1}, timers: ["p"], in_flight: in_flight, queued: [], steps: 1} =
               Runtime.info(Probe, sys.i)

      assert in_flight == %{}
      assert Process.whereis(Runtime.name(sys.instance, Probe)) == runtime

      # A change does not wait for the back-off, and a step that works ends it.
      put_fact(sys, {:observe, "p"}, nil)
      {:ok, _} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)
      await!(sys, :probe, "p", :ready)
      settle(sys)
      assert %{failures: failures, timers: []} = Runtime.info(Probe, sys.i)
      assert failures == %{}
    end

    test "a crashed step is tried again by its timer" do
      sys = start_system(controllers: [Probe], runtime: [backoff: {1, 4}])
      put_fact(sys, {:act, "p"}, :raise)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      for _attempt <- 1..4, do: assert_receive({:acting, "p", 1, _step}, sys.wait)

      put_fact(sys, {:act, "p"}, nil)
      await!(sys, :probe, "p", :ready)
    end

    test "each failure in a row doubles the wait, up to the cap" do
      sys = start_system(controllers: [Probe], runtime: [backoff: {10_000, 35_000}])
      put_fact(sys, {:observe, "p"}, :raise)
      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)

      waits =
        for failures <- 1..4 do
          settle(sys)
          assert %{failures: %{"p" => ^failures}} = Runtime.info(Probe, sys.i)
          fire_timer(sys, Probe, "p")
        end

      # 10 s, 20 s, then 35 s where 40 s and 80 s would have been; each read
      # a moment after it was armed.
      for {wait, armed} <- Enum.zip(waits, [10_000, 20_000, 35_000, 35_000]) do
        assert wait in (armed - 4_000)..armed
      end
    end

    test "an action that returns an error is told to the next pass and counts no crash" do
      sys = start_system(controllers: [Probe])
      put_fact(sys, {:act, "p"}, {:error, :boom})

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      await!(sys, :probe, "p", &(&1.status[:last_error] == :boom))
      settle(sys)

      assert %{failures: failures} = Runtime.info(Probe, sys.i)
      assert failures == %{}
      assert %{status: false, reason: :action_failed} = condition(sys, :probe, "p", :ready)
      assert journal(sys) == []

      # Told once: a later pass decides from observation alone.
      assert_received {:acting, "p", 1, _step}
      refute_received {:acting, "p", 1, _step}
      put_fact(sys, {:act, "p"}, nil)
      {:ok, _} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)
      await!(sys, :probe, "p", :ready)
    end

    test "passes that keep ending in a failed action are spaced out" do
      sys = start_system(controllers: [Stubborn], runtime: [backoff: {60_000, 60_000}])

      {:ok, _} = Store.create(:stubborn, "s", %{}, sys.i)
      settle(sys)

      # The first failure is told to the next pass at once; the second waits.
      assert %{failures: %{"s" => 2}, timers: ["s"], steps: 2} = Runtime.info(Stubborn, sys.i)
    end

    test "a deleted key's timer is cancelled, and its late message starts nothing" do
      sys = start_system(controllers: [Probe])
      put_fact(sys, {:requeue, "p"}, 600_000)
      given_ready(sys, {:probe, "p", %{}})

      runtime = Process.whereis(Runtime.name(sys.instance, Probe))
      assert %{timers: ["p"]} = Runtime.info(Probe, sys.i)
      %{"p" => {_timer, token}} = :sys.get_state(runtime).timers

      {:ok, _} = Store.delete(:probe, "p", sys.i)
      settle(sys)
      assert %{timers: [], steps: steps} = Runtime.info(Probe, sys.i)

      # What a timer that fired just before it was cancelled leaves behind.
      send(runtime, {:requeue, "p", token})
      # A call from here is behind that message; the settle might not be.
      Runtime.info(Probe, sys.i)
      settle(sys)
      assert %{steps: ^steps, queued: [], timers: []} = Runtime.info(Probe, sys.i)
      assert Store.get(:probe, "p", sys.i) == nil
    end

    test "a step that outlived its resource writes nothing onto a namesake" do
      sys = start_system(controllers: [Scribe], kinds: %{note: []})
      put_fact(sys, :block_scribe, true)

      {:ok, %{uid: first}} = Store.create(:scribe, "s", %{}, sys.i)
      assert_receive {:observing, "s", step}, sys.wait

      {:ok, _} = Store.delete(:scribe, "s", sys.i)
      {:ok, %{uid: second}} = Store.create(:scribe, "s", %{}, sys.i)

      # The step read the first "s" and decides to write a note for it.
      send(step, :go)
      assert_receive {:observing, "s", again}, sys.wait
      put_fact(sys, :block_scribe, false)
      send(again, :go)

      await!(sys, :scribe, "s", :ready)
      settle(sys)
      assert first != second
      assert for(note <- Store.list(:note, sys.i), do: note.name) == ["by-#{second}"]
    end
  end

  describe "restarts" do
    test "killing a runtime kills its step in flight, and the replacement carries on" do
      sys = start_system(controllers: [Probe])
      put_fact(sys, {:act, "p"}, :block)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      assert_receive {:acting, "p", 1, orphan}, sys.wait
      monitor = Process.monitor(orphan)

      kill_runtime(sys, Probe)
      assert_receive {:DOWN, ^monitor, :process, ^orphan, _reason}, sys.wait

      # Its listing at start is all the replacement has to go on.
      assert_receive {:acting, "p", 1, step}, sys.wait
      assert step != orphan
      send(step, :go)
      await!(sys, :probe, "p", :ready)
      settle(sys)
      assert fact(sys, {:seen, "p"}) == 1
    end

    test "after a store restart every runtime has registered again and writes status" do
      sys = start_system(controllers: [Kept, Tagger])
      given_ready(sys, {:kept, "k", %{}})

      before =
        for controller <- sys.controllers,
            do: Process.whereis(Runtime.name(sys.instance, controller))

      restart_store(sys)

      for {controller, old} <- Enum.zip(sys.controllers, before) do
        assert Process.whereis(Runtime.name(sys.instance, controller)) != old
      end

      # A new generation, so both conditions have to be written again.
      {:ok, _} = Store.update_spec(:kept, "k", %{"again" => true}, sys.i)
      await!(sys, :kept, "k", :ready)
      await!(sys, :kept, "k", :tagged)
    end
  end

  describe "shutdown" do
    test "while the host shuts down no step starts and nothing is written; work resumes after" do
      sys = start_system(controllers: [Probe])
      shutdown(sys, true)

      {:ok, created} = Store.create(:probe, "p", %{}, sys.i)
      settle(sys)

      assert %{steps: 0, queued: ["p"]} = Runtime.info(Probe, sys.i)
      assert Store.get(:probe, "p", sys.i) == created
      assert journal(sys) == []
      refute_received {:acting, "p", _n, _step}

      shutdown(sys, false)
      await!(sys, :probe, "p", :ready)
    end

    test "a step in flight when the shutdown begins stops before its first write" do
      sys = start_system(controllers: [Probe])
      put_fact(sys, {:observe, "p"}, :block)

      {:ok, created} = Store.create(:probe, "p", %{}, sys.i)
      assert_receive {:observing, "p", step}, sys.wait

      shutdown(sys, true)
      put_fact(sys, {:observe, "p"}, nil)
      send(step, :go)
      settle(sys)

      assert Store.get(:probe, "p", sys.i) == created
      assert journal(sys) == []

      shutdown(sys, false)
      await!(sys, :probe, "p", :ready)
    end
  end

  describe "shutdown and lanes" do
    test "an action that gets its lane after the shutdown began is not performed" do
      sys = start_system(controllers: [Probe], lanes: %{pull: 1})
      lanes = Process.whereis(Lanes.name(sys.instance))
      put_fact(sys, {:act, "a"}, :block)

      {:ok, _} = Store.create(:probe, "a", %{"lane" => true}, sys.i)
      assert_receive {:acting, "a", 1, holder}, sys.wait

      :erlang.trace(lanes, true, [:receive])
      {:ok, _} = Store.create(:probe, "b", %{"lane" => true}, sys.i)

      assert_receive {:trace, ^lanes, :receive, {:"$gen_call", _from, {:acquire, :pull, 0}}},
                     sys.wait

      :erlang.trace(lanes, false, [:receive])

      shutdown(sys, true)
      send(holder, :go)
      settle(sys)

      assert journal(sys) == [{{:probe, "a"}, {:fetch, 1}}]
      refute_received {:acting, "b", 1, _step}
      assert %{pull: %{held: [], waiting: 0}} = Lanes.info(sys.i)

      shutdown(sys, false)
      for name <- ["a", "b"], do: await!(sys, :probe, name, :ready)
    end
  end

  describe "verdicts" do
    test "two controllers attached to one kind write their own conditions and leave the rest" do
      sys = start_system(controllers: [Kept, Tagger])
      given_ready(sys, {:kept, "k", %{}})
      await!(sys, :kept, "k", :tagged)
      settle(sys)

      assert %{status: true, reason: :made} = condition(sys, :kept, "k", :ready)
      assert %{status: true, reason: :tagged} = condition(sys, :kept, "k", :tagged)

      # Only the tagger has anything to say about this.
      put_fact(sys, {:tag, "k"}, false)
      resync(sys, Tagger)
      settle(sys)
      assert %{status: true, reason: :made} = condition(sys, :kept, "k", :ready)
      assert %{status: true, reason: :tagged} = condition(sys, :kept, "k", :tagged)
      assert Enum.count(journal(sys), &(&1 == {{:tagger, "k"}, :tag})) == 2

      # And only the owner about this; the generation observed is the owner's.
      put_fact(sys, {:made, "k"}, false)
      resync(sys, Kept)
      settle(sys)
      kept = Store.get(:kept, "k", sys.i)
      assert kept.status.observed_generation == kept.generation
      assert Enum.sort(Map.keys(kept.status.conditions)) == [:ready, :tagged]
      assert Enum.count(journal(sys), &(&1 == {{:kept, "k"}, :make})) == 2
    end

    test "a verdict missing a declared condition type fails the step and writes nothing" do
      sys = start_system(controllers: [Sloppy], runtime: [backoff: {60_000, 60_000}])

      log =
        capture_log(fn ->
          {:ok, created} = Store.create(:sloppy, "s", %{}, sys.i)
          settle(sys)
          assert Store.get(:sloppy, "s", sys.i) == created
        end)

      assert log =~ "verdict on sloppy/s refused: [missing: :progressing]"
      assert %{failures: %{"s" => 1}, steps: 1} = Runtime.info(Sloppy, sys.i)
      assert journal(sys) == []
    end

    test "outside strict mode such a verdict is dropped and the effects still happen" do
      sys = start_system(controllers: [Sloppy], runtime: [strict_verdicts: false])

      {:ok, created} = Store.create(:sloppy, "s", %{}, sys.i)
      settle(sys)

      assert %{failures: failures} = Runtime.info(Sloppy, sys.i)
      assert failures == %{}
      assert Store.get(:sloppy, "s", sys.i) == created
      assert journal(sys) == [{{:sloppy, "s"}, :poke}]
    end
  end

  describe "effect groups" do
    @tag :tmp_dir
    test "the effects between two actions are one commit", %{tmp_dir: dir} do
      test = self()

      persist = fn path, data ->
        send(test, :persisted)
        Vagus.Resource.Persistence.write(path, data)
      end

      sys =
        start_system(
          controllers: [Batch],
          path: Path.join(dir, "resources.json"),
          persist: persist
        )

      given_ready(sys, {:batch, "b", %{}})

      # The create, then one write per group: `a` with the progress and the
      # verdict, `b` with `c`, and `d`. Status alone never reaches the file.
      for _commit <- 1..4, do: assert_received(:persisted)
      refute_received :persisted

      assert %{spec: %{"a" => true, "b" => true, "c" => true, "d" => true}, generation: 5} =
               Store.get(:batch, "b", sys.i)

      assert journal(sys) == [{{:batch, "b"}, {:mark, 1}}, {{:batch, "b"}, {:mark, 2}}]

      # The verdict went with the first group: it is there before any action.
      assert [{:status_at_mark, 1, at_first}, {:status_at_mark, 2, _status}] = notes(sys)
      assert %{observed_generation: 1, conditions: %{ready: %{reason: :marking}}} = at_first
    end
  end

  describe "references" do
    test "a change to a referenced resource runs only the resources that refer to it" do
      sys = start_system(controllers: [Probe, Linker])
      given_ready(sys, {:probe, "p1", %{}})
      given_ready(sys, {:probe, "p2", %{}})
      given_ready(sys, {:link, "l1", %{"target" => "p1"}})
      given_ready(sys, {:link, "l2", %{"target" => "p2"}})

      assert %{references: %{"l1" => [probe: "p1"], "l2" => [probe: "p2"]}} =
               Runtime.info(Linker, sys.i)

      notes(sys)

      {:ok, _} = Store.update_spec(:probe, "p1", %{"n" => 2}, sys.i)
      await!(sys, :link, "l1", &(&1.status.sees == 2))
      settle(sys)

      assert Enum.uniq(notes(sys)) == [{:link_observed, "l1"}]
      assert Store.get(:link, "l2", sys.i).status.sees == 1
    end

    test "a reference that moves is followed, and the old target no longer wakes it" do
      sys = start_system(controllers: [Probe, Linker])
      given_ready(sys, {:probe, "p1", %{}})
      given_ready(sys, {:probe, "p2", %{"n" => 7}})
      given_ready(sys, {:link, "l", %{"target" => "p1"}})

      {:ok, _} = Store.update_spec(:link, "l", %{"target" => "p2"}, sys.i)
      await!(sys, :link, "l", &(&1.status.sees == 7))
      settle(sys)
      assert %{references: %{"l" => [probe: "p2"]}} = Runtime.info(Linker, sys.i)
      notes(sys)

      {:ok, _} = Store.update_spec(:probe, "p1", %{"n" => 3}, sys.i)
      await!(sys, :probe, "p1", :ready)
      settle(sys)
      assert notes(sys) == []
    end
  end

  describe "resync" do
    @tag scenario: :resync
    test "the periodic resync finds what was never announced, tick after tick" do
      sys = start_system(controllers: [Probe], resync: 20, runtime: [deliver_events: false])

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      await!(sys, :probe, "p", :ready)

      {:ok, _} = Store.update_spec(:probe, "p", %{"n" => 2}, sys.i)
      await!(sys, :probe, "p", :ready)
    end

    @tag scenario: :resync
    test "a gap signal has every resource looked at again" do
      sys = start_system(controllers: [Probe], runtime: [deliver_events: false])

      {:ok, created} = Store.create(:probe, "p", %{}, sys.i)
      settle(sys)
      assert Store.get(:probe, "p", sys.i) == created

      Runtime.resync(Probe, sys.i)
      await!(sys, :probe, "p", :ready)
    end

    @tag scenario: :resync
    test "a resync forgets a resource whose removal was never announced" do
      sys = start_system(controllers: [Probe], runtime: [deliver_events: false])
      put_fact(sys, {:requeue, "p"}, 600_000)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      resync(sys, Probe)
      await!(sys, :probe, "p", :ready)
      settle(sys)
      assert %{timers: ["p"]} = Runtime.info(Probe, sys.i)

      {:ok, _} = Store.delete(:probe, "p", sys.i)
      settle(sys)
      assert %{timers: ["p"]} = Runtime.info(Probe, sys.i)

      resync(sys, Probe)
      settle(sys)
      assert %{timers: [], queued: []} = Runtime.info(Probe, sys.i)
    end
  end

  describe "an observation that cannot be made" do
    test "is reported as progressing, counts no failure, and is retried" do
      sys = start_system(controllers: [Probe], runtime: [unavailable_retry: 600_000])
      put_fact(sys, :engine, :down)

      {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
      await!(sys, :probe, "p", :progressing)
      settle(sys)

      assert %{status: true, reason: :engine_unavailable} =
               condition(sys, :probe, "p", :progressing)

      assert %{status: false, reason: :engine_unavailable} = condition(sys, :probe, "p", :ready)
      assert %{failures: failures, timers: ["p"], steps: 1} = Runtime.info(Probe, sys.i)
      assert failures == %{}
      assert journal(sys) == []

      put_fact(sys, :engine, :up)
      assert fire_timer(sys, Probe, "p") in 590_000..600_000
      await!(sys, :probe, "p", :ready)
    end

    test "has none of the actions decided from it performed" do
      sys = start_system(controllers: [Probe], runtime: [unavailable_retry: 600_000])
      put_fact(sys, :engine, :down)
      put_fact(sys, :act_when_down, true)

      log =
        capture_log(fn ->
          {:ok, _} = Store.create(:probe, "p", %{}, sys.i)
          await!(sys, :probe, "p", :progressing)
          settle(sys)
        end)

      assert log =~ "probe/p could not be observed; not performing [visit: 0]"
      assert journal(sys) == []
      refute_received {:acting, "p", _n, _step}
      assert %{timers: ["p"], steps: 1} = Runtime.info(Probe, sys.i)
    end
  end

  describe "lanes" do
    test "a lane caps the actions running at once, and a holder that dies frees its slot" do
      sys = start_system(controllers: [Probe], lanes: %{pull: 1})
      lanes = Process.whereis(Lanes.name(sys.instance))
      for name <- ["a", "b"], do: put_fact(sys, {:act, name}, :block)

      :erlang.trace(lanes, true, [:receive])
      for name <- ["a", "b"], do: {:ok, _} = Store.create(:probe, name, %{"lane" => true}, sys.i)

      for _step <- 1..2 do
        assert_receive {:trace, ^lanes, :receive, {:"$gen_call", _from, {:acquire, :pull, 0}}},
                       sys.wait
      end

      :erlang.trace(lanes, false, [:receive])

      # Both have asked; this call is behind them.
      assert %{pull: %{cap: 1, held: [holder], waiting: 1}} = Lanes.info(sys.i)
      assert_receive {:acting, first, 1, ^holder}, sys.wait
      refute_received {:acting, _name, 1, _step}

      for name <- ["a", "b"], do: put_fact(sys, {:act, name}, nil)
      Process.exit(holder, :kill)

      [second] = ["a", "b"] -- [first]
      assert_receive {:acting, ^second, 1, _step}, sys.wait
      for name <- ["a", "b"], do: await!(sys, :probe, name, :ready)
      settle(sys)
      assert %{pull: %{held: [], waiting: 0}} = Lanes.info(sys.i)
    end
  end
end
