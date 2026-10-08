defmodule Vagus.App.Controller.SystemTest do
  # Not async: a native app binds a port and registers names, one test
  # traces every new process, and one reads everything that was logged.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Vagus.Resource.Harness

  import Vagus.Test.AppWorld,
    only: [actions: 2, advance: 3, install: 4, verdict: 1, wake: 2, write: 3]

  alias Vagus.App.{AuthIndex, Backend, Boot, Controller, EngineObserver, Pulls}
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Resource.{Runtime, Store}
  alias Vagus.Test.{AppManifests, AppWorld, FakeEngine}
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log
  @moduletag :scenario
  # A scenario runs once more for each boundary it crosses.
  @moduletag timeout: 180_000

  @plain "only_host_uts"
  @watched "45df7312_zigbee2mqtt"
  @once "local_once"
  @manual "elixir_probe"
  @native "core_mqtt"

  @ready {true, false, false, :ready, :ready}
  @stopped {false, false, false, :stopped, :stopped}
  @start [:create, :put_token, :start]

  defp run(world, extra, scenario) do
    Faults.each_boundary(
      system: AppWorld.system(world, extra),
      normalize: &AppWorld.normalize/1,
      scenario: fn sys -> scenario.(sys, AppWorld.engine(world, sys)) end
    )
  end

  defp get(sys, app), do: Store.get(:app, app, sys.i)

  # Every process beneath a supervisor, itself included.
  defp tree(pid) do
    [
      pid
      | for(
          {_id, child, type, _modules} <- Supervisor.which_children(pid),
          is_pid(child),
          descendant <- if(type == :supervisor, do: tree(child), else: [child]),
          do: descendant
        )
    ]
  end

  # Killed, and gone with everything it held: its names and its port are
  # free when this returns.
  defp kill_tree(pid) do
    monitors = for process <- tree(pid), do: {process, Process.monitor(process)}
    Process.exit(pid, :kill)

    for {process, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^process, _reason}, 5_000)

    :ok
  end

  test "a native app is started, comes back under its budget when it ends, and is stopped" do
    world = AppWorld.new(native: true)
    spec = AppWorld.spec(world, AppManifests.native(), %{run: true})
    native = [supervisor: world.native.supervisor, port: world.native.port]

    run(world, [observers: &[AppWorld.observer(world, &1)]], fn sys, _engine ->
      {:ok, _app} = Store.create(:app, @native, spec, sys.i)
      app = await!(sys, :app, @native, :ready)
      settle(sys)
      assert verdict(get(sys, @native)) == @ready
      assert actions(sys, @native) == [:start_process]
      assert %{process: broker, address: nil} = app.status.instance
      assert {:ok, %{process: ^broker}} = Backend.Native.observe(@native, native)

      # Nothing restarts it but the app's next pass, which nothing but the
      # observer's monitor brings.
      kill_tree(broker)

      app =
        await!(sys, :app, @native, &match?(%{reason: :backing_off}, &1.status.conditions.ready))

      settle(sys)
      assert app.status.restarts.attempts == 1
      assert actions(sys, @native) == [:start_process]
      assert Backend.Native.observe(@native, native) == {:ok, :absent}

      assert {_, true, _, :backing_off, _} = verdict(advance(sys, @native, 9_999))
      app = advance(sys, @native, 1)
      assert verdict(app) == @ready
      assert actions(sys, @native) == [:start_process, :start_process]
      assert app.status.instance.process != broker

      app = write(sys, @native, %{run: false})
      assert verdict(app) == @stopped
      assert actions(sys, @native) == [:start_process, :start_process, :stop_process]
      assert Backend.Native.observe(@native, native) == {:ok, :absent}
      assert app.status.restarts.attempts == 0
    end)
  end

  describe "after a reboot" do
    setup do
      world = AppWorld.new()
      template = Path.join(world.root, "before-the-reboot.json")
      path = Path.join(world.root, "resources.json")
      marker = Path.join(world.root, "booted")
      apps = [@plain, @manual, @once]
      images = for app <- apps, do: AppWorld.image(world, AppWorld.spec(world, app))

      # Before the reboot all three ran.
      sys = start_system(AppWorld.system(world, path: template))
      for app <- apps, do: install(world, sys, app, %{run: true})
      for app <- apps, do: assert(verdict(get(sys, app)) == @ready)
      stop_system(sys)

      # After it: the same store, no status, the containers stopped, and a
      # run directory with no marker in it.
      world = %{
        world
        | boot_marker: marker,
          before: fn ->
            File.cp!(template, path)
            File.rm(marker)
          end,
          seed: fn engine ->
            for {app, image} <- Enum.zip(apps, images) do
              Model.put_image(engine, image)

              Model.put_container(engine, "app_" <> app,
                state: "exited",
                exit_code: 143,
                image: image
              )
            end
          end
      }

      %{world: world, path: path, marker: marker}
    end

    test "an app started by hand and one that runs once stay down; the rest start, uncounted",
         %{world: world, path: path, marker: marker} do
      run(world, [path: path], fn sys, engine ->
        assert Jason.decode!(File.read!(marker)) == %{"state" => "done"}

        auto = get(sys, @plain)
        assert auto.spec.run
        assert verdict(auto) == @ready
        assert auto.status.restarts.attempts == 0
        assert AppWorld.acted?(sys, @plain, [:remove] ++ @start)

        # Set before the runtime's first pass: neither was ever started.
        for app <- [@manual, @once] do
          refute get(sys, app).spec.run
          assert verdict(get(sys, app)) == @stopped
          assert AppWorld.acted?(sys, app, [:remove])
          assert Model.container(engine, "app_" <> app) == nil
        end

        # What the user asks for afterwards is theirs.
        assert verdict(write(sys, @manual, %{run: true})) == @ready
        assert Boot.normalise(instance: sys.instance, marker: marker) == :already
        assert get(sys, @manual).spec.run
      end)
    end
  end

  test "no token is in the store's file, in status, in a process's state or in a log" do
    world = AppWorld.new()
    path = Path.join(world.root, "resources.json")
    seen = :ets.new(:seen, [:public, :bag])

    look = fn sys ->
      runtime = Process.whereis(Runtime.name(sys.instance, Controller))
      index = Process.whereis(AuthIndex.name(sys.instance))

      for term <- [
            File.read!(path),
            snapshot(sys),
            journal(sys),
            :sys.get_state(runtime),
            Runtime.info(Controller, sys.i),
            :sys.get_state(index),
            :ets.tab2list(AuthIndex.table(sys.instance)),
            :sys.get_state(Process.whereis(Pulls.name(sys.instance)))
          ],
          do:
            :ets.insert(
              seen,
              {:term, inspect(term, limit: :infinity, printable_limit: :infinity)}
            )
    end

    log =
      capture_log([level: :debug], fn ->
        sys = start_system(AppWorld.system(world, path: path))
        engine = AppWorld.engine(world, sys)

        install(world, sys, @plain, %{run: true})
        install(world, sys, @watched, %{run: true, settings: %{watchdog: true}})
        look.(sys)

        # A start that fails, a restart, a crash, a pass that raises with
        # the instance in hand, a runtime replaced, a token table replaced.
        Model.fail_start(engine, "app_" <> @plain, "port is already allocated")
        write(sys, @plain, [{:inc, [:restart_counter]}])
        look.(sys)
        Model.fail_start(engine, "app_" <> @plain, nil)
        write(sys, @plain, [{:inc, [:start_counter]}])
        Model.crash(engine, "app_" <> @watched)
        wake(sys, @watched)
        advance(sys, @watched, 10_000)
        look.(sys)
        # The probe raises, once, in a pass that has the instance in hand.
        :atomics.put(world.probe, 1, 2)
        advance(sys, @watched, 120_000)
        await!(sys, :app, @watched, :ready)
        settle(sys)
        look.(sys)
        kill_runtime(sys, Controller)
        settle(sys)
        look.(sys)

        {:ok, _app} = Store.delete(:app, @plain, sys.i)
        await!(sys, :app, @plain, :gone)
        look.(sys)

        tokens =
          for %{path: "/containers/create", body: %{"Env" => env}} <- FakeEngine.requests(engine),
              "SUPERVISOR_TOKEN=" <> token <- env,
              do: token

        :ets.insert(seen, {:tokens, tokens})
      end)

    [tokens: tokens] = :ets.lookup(seen, :tokens)
    assert length(Enum.uniq(tokens)) >= 4
    assert Enum.all?(tokens, &(byte_size(&1) == 43))
    # The pass that raised was logged, so a crash report is among what is read.
    assert log =~ "the prober fell over"
    hay = [log | for({:term, text} <- :ets.lookup(seen, :term), do: text)]

    for token <- tokens, text <- hay do
      refute text =~ token
      refute text =~ Base.encode16(:crypto.hash(:sha256, token), case: :lower)
    end

    refute Enum.any?(hay, &(&1 =~ "SUPERVISOR_TOKEN"))
  end

  describe "Vagus.App.wiring/1" do
    setup do
      world = AppWorld.new()
      events = Module.concat(__MODULE__, "Events#{world.id}")

      opts = [
        engine: [socket: world.socket],
        facts: [data_root: world.data],
        boot_marker: Path.join(world.root, "booted"),
        context:
          Map.put(Map.take(AppWorld.context(world), [:prepare, :audit]), :api_ready, fn ->
            true
          end),
        observer: [events: {Vagus.Runtime.Events, events}, interval: :infinity]
      ]

      %{world: world, opts: opts, events: events}
    end

    test "is the controller with a long resync of its own, what it stands on, and the observer",
         %{opts: opts} do
      wiring = Vagus.App.wiring([instance: I] ++ opts)
      assert Keyword.keys(wiring) == [:controllers, :services, :observers]
      assert [{Controller, runtime}] = wiring[:controllers]
      assert runtime[:resync] == :timer.hours(1)
      assert %{facts: %Vagus.App.Facts{}, gates: [], backends: %{}} = runtime[:context]

      assert [{AuthIndex, instance: I}, {Pulls, _}, %{id: _tasks}, %{id: Boot}] =
               wiring[:services]

      assert [{EngineObserver, observer}] = wiring[:observers]
      assert observer[:controller] == Controller and observer[:instance] == I

      # Only a gate somebody opens is waited for.
      assert [{Controller, gated}] = Vagus.App.wiring(gates: [:dns_ready])[:controllers]
      assert gated[:context].gates == [:dns_ready]
    end

    test "run as given: an app is started, and what happens in the engine wakes it",
         %{world: world, opts: opts, events: events} do
      wiring = &Vagus.App.wiring([instance: &1] ++ opts)

      sys =
        start_system(
          controllers: wiring.(nil)[:controllers],
          services:
            &[%{id: :engine, start: {AppWorld, :start_engine, [world]}} | wiring.(&1)[:services]],
          observers: &wiring.(&1)[:observers]
        )

      engine = AppWorld.engine(world, sys)
      start_supervised!({Vagus.Runtime.Events, name: events, socket: world.socket})
      assert File.read!(opts[:boot_marker]) =~ "done"

      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == @ready
      assert Process.whereis(EngineObserver.name(sys.instance))

      # Nobody tells the runtime: the event does, through the observer.
      Model.crash(engine, "app_" <> @plain, 9)
      app = await!(sys, :app, @plain, :failed)
      assert %{cause: :crashed, detail: %{exit_code: 9}} = app.status.failure
    end
  end

  describe "where the controller's code runs" do
    @traced [Controller, Controller.Observe, Controller.Reconcile, Controller.View]

    defp calls(seen \\ []) do
      receive do
        {:trace, pid, :call, {module, function, _args}} -> calls([{pid, module, function} | seen])
      after
        0 -> seen
      end
    end

    test "never in its runtime, from that runtime's start to its replacement's work" do
      world = AppWorld.new()
      for module <- @traced, do: :erlang.trace_pattern({module, :_, :_}, true, [:local])
      :erlang.trace(:new_processes, true, [:call])

      {first, second, store} =
        try do
          sys = start_system(AppWorld.system(world))
          first = Process.whereis(Runtime.name(sys.instance, Controller))
          store = Process.whereis(Store.name(sys.instance))

          install(world, sys, @plain, %{run: true})
          second = kill_runtime(sys, Controller)
          settle(sys)
          write(sys, @plain, [{:inc, [:restart_counter]}])
          {:ok, _app} = Store.delete(:app, @plain, sys.i)
          await!(sys, :app, @plain, :gone)
          settle(sys)
          {first, second, store}
        after
          # Whatever became of the scenario: a tracer left on outlives the test.
          :erlang.trace(:new_processes, false, [:call])
          for module <- @traced, do: :erlang.trace_pattern({module, :_, :_}, false, [:local])
        end

      calls = calls()

      for function <- [:observe, :reconcile, :act, :references, :action_class] do
        assert Enum.any?(calls, &match?({_pid, Controller, ^function}, &1)),
               "#{function} was never called"
      end

      assert Enum.any?(calls, &match?({_pid, Controller.View, :view}, &1))
      # Admission and the codec are the store's to run.
      assert {store, Controller, :validate} in calls
      assert first != second
      for runtime <- [first, second], do: refute(Enum.any?(calls, &(elem(&1, 0) == runtime)))
    end
  end
end
