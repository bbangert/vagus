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
  @early "core_mosquitto"

  @ready {true, false, false, :ready, :ready}
  @stopped {false, false, false, :stopped, :stopped}
  @start [:create, :put_token, :start]

  defp run(world, extra, scenario) do
    Faults.each_boundary(
      system: AppWorld.system(world, extra),
      normalize: &AppWorld.normalize/1,
      journal: &AppWorld.journal/1,
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
    native = [supervisor: world.native.supervisor]

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

      assert {_, true, _, :backing_off, _} = verdict(advance(sys, @native, 9_000))
      app = advance(sys, @native, 1_000)
      assert verdict(app) == @ready
      assert actions(sys, @native) == [:start_process, :start_process]
      assert app.status.instance.process != broker

      # A restart asked for ends the broker and starts another: its going
      # was asked for, and is no attempt of the budget.
      was = app.status.instance.process
      app = write(sys, @native, [{:inc, [:restart_counter]}])
      assert verdict(app) == @ready
      assert app.status.instance.process != was
      started = [:start_process, :start_process, :stop_process, :start_process]
      assert actions(sys, @native) == started
      assert wake(sys, @native).status.restarts.attempts == 0

      app = write(sys, @native, %{run: false})
      assert verdict(app) == @stopped
      assert actions(sys, @native) == started ++ [:stop_process]
      assert Backend.Native.observe(@native, native) == {:ok, :absent}
      assert app.status.restarts.attempts == 0
    end)
  end

  test "a native app whose options cannot be written is not started, and is once they can" do
    world = AppWorld.new(native: true)
    spec = AppWorld.spec(world, AppManifests.native(), %{run: true})
    sys = start_system(AppWorld.system(world))
    File.mkdir_p!(world.data)
    File.write!(Path.join(world.data, "addons"), "in the way")

    {:ok, _app} = Store.create(:app, @native, spec, sys.i)
    await!(sys, :app, @native, &(&1.status[:failure] != nil))
    settle(sys)
    app = get(sys, @native)
    assert %{action: :start_process, class: :transient} = app.status.failure
    # The broker's supervisor was never asked.
    assert actions(sys, @native) == []
    assert Backend.Native.observe(@native, supervisor: world.native.supervisor) == {:ok, :absent}

    File.rm!(Path.join(world.data, "addons"))
    assert verdict(advance(sys, @native, 1_000)) == @ready
    assert actions(sys, @native) == [:start_process]
    assert verdict(write(sys, @native, %{run: false})) == @stopped
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

  defmodule Faulty do
    @moduledoc """
    The engine client, with the faults a token could leave by: on the
    switch in its `:faults` option, a call raises with everything it was
    given or read in the exception's message, the container's environment
    and so its token among it.

      * 1: the create raises, with the config it was given;
      * 2: the inspect the token put makes raises, with what it read;
      * 3: the next inspect an observation makes raises the same way, once;
      * 4: so does the next inspect of a container the other slot left.
    """
    alias Vagus.Runtime.Docker

    def create_container(config, opts) do
      {faults, opts} = Keyword.pop!(opts, :faults)
      if :atomics.get(faults, 1) == 1, do: raise("create fell over with #{inspect(config)}")
      Docker.create_container(config, opts)
    end

    def inspect_container(name, opts) do
      {faults, opts} = Keyword.pop!(opts, :faults)
      result = Docker.inspect_container(name, opts)

      case {:atomics.get(faults, 1), putting?()} do
        {2, true} -> raise "inspect fell over with #{inspect(result, limit: :infinity)}"
        {3, false} -> match?({:ok, _}, result) && once(faults, result)
        {4, false} -> name =~ "addon_" && once(faults, result)
        _neither -> result
      end || result
    end

    defp once(faults, result) do
      :atomics.put(faults, 1, 0)
      raise "inspect fell over with #{inspect(result, limit: :infinity)}"
    end

    # Whether this is the token put's read and not an observation's: the two
    # make the same call.
    defp putting? do
      {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

      Enum.any?(stack, fn {module, function, _arity, _location} ->
        module == Controller and Atom.to_string(function) =~ "act"
      end)
    end

    for {function, arity} <- [
          inspect_image: 2,
          list_containers: 1,
          start_container: 2,
          stop_container: 2,
          remove_container: 2,
          remove_image: 2
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(function)(unquote_splicing(args)) do
        {last, first} = List.pop_at(unquote(args), -1)
        apply(Docker, unquote(function), first ++ [Keyword.delete(last, :faults)])
      end
    end
  end

  describe "a token" do
    @core "homeassistant"
    @supervisor_token "the-supervisor-token"
    @other_slot_token "the-token-the-other-slot-gave"

    # Every form a token or its digest could be written in.
    defp forms(token) do
      digest = :crypto.hash(:sha256, token)

      %{
        token: [token],
        digest: [
          Base.encode16(digest, case: :lower),
          Base.encode16(digest, case: :upper),
          Base.encode64(digest),
          Base.encode64(digest, padding: false),
          Base.url_encode64(digest),
          Base.url_encode64(digest, padding: false),
          # As `inspect/1` shows a binary that is no text.
          digest |> :binary.bin_to_list() |> Enum.join(", ")
        ]
      }
    end

    defp text(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

    # A process as a dump of it would show it: its state where it has one
    # to ask for, and whatever is on its stack, in its dictionary and in
    # its mailbox.
    defp process(pid) do
      {pid, Process.info(pid, [:backtrace, :dictionary, :messages])}
    end

    defp stateful(name) do
      pid = Process.whereis(name)
      {:sys.get_state(pid), process(pid)}
    end

    # Everything there is to read of a running system. The token table and
    # its process hold digests, which is what they are for, and so are
    # kept apart: only a token itself must not be in them.
    defp look(sys, path) do
      i = sys.instance
      tasks = Task.Supervisor.children(Runtime.tasks(i, Controller))
      pulls = Task.Supervisor.children(Pulls.tasks(i))

      %{
        anywhere: [
          file: File.read!(path),
          store: snapshot(sys),
          journal: AppWorld.journal(sys),
          runtime: stateful(Runtime.name(i, Controller)),
          info: Runtime.info(Controller, sys.i),
          steps: Enum.map(tasks, &process/1),
          lanes: stateful(Vagus.Resource.Lanes.name(i)),
          store_process: stateful(Store.name(i)),
          pull_worker: stateful(Pulls.name(i)),
          pull_tasks: Enum.map(pulls, &process/1)
        ],
        table: [
          index: stateful(AuthIndex.name(i)),
          rows: :ets.tab2list(AuthIndex.table(i))
        ]
      }
    end

    defp traced(seen \\ []) do
      receive do
        {:trace, _pid, :call, {Controller, function, args}} ->
          traced([{function, args} | seen])

        {:trace, _pid, :return_from, {Controller, function, _arity}, value} ->
          traced([{function, value} | seen])
      after
        0 -> seen
      end
    end

    defp minted(engine) do
      for %{path: "/containers/create", body: %{"Env" => env}} <- FakeEngine.requests(engine),
          "SUPERVISOR_TOKEN=" <> token <- env,
          uniq: true,
          do: token
    end

    test "is in nothing a run leaves or shows: file, status, journal, log, crash report, " <>
           "process, or what the controller's callbacks are given and return" do
      world = AppWorld.new()
      path = Path.join(world.root, "resources.json")
      faults = :atomics.new(1, [])
      network = :atomics.new(1, [])

      context = %{
        backends: %{
          Backend.Container => [client: Faulty, engine: [socket: world.socket, faults: faults]],
          Backend.Native => []
        },
        prepare: [
          network: fn -> if(:atomics.get(network, 1) == 1, do: {:error, :enetdown}, else: :ok) end,
          dsp_state: fn -> :unsupported end
        ]
      }

      seen = :ets.new(:seen, [:public, :bag])
      keep = fn sys -> :ets.insert(seen, {:look, look(sys, path)}) end
      failed = fn sys, app -> get(sys, app).status.failure end
      # Looked at after the search: with a guard gone the fault is a crashed
      # step and no failure, and what the test then says is where the token is.
      hit = fn action, failure -> :ets.insert(seen, {:hit, action, failure}) end

      # A pattern is set on code that is loaded, and on no other.
      Code.ensure_loaded!(Controller)
      :erlang.trace_pattern({Controller, :observe, 2}, [{:_, [], [{:return_trace}]}], [:local])
      :erlang.trace_pattern({Controller, :reconcile, 2}, true, [:local])
      :erlang.trace_pattern({Controller, :act, 3}, true, [:local])
      :erlang.trace(:new_processes, true, [:call])

      log =
        try do
          capture_log([level: :debug], fn ->
            sys = start_system(AppWorld.system(world, path: path, context: context))
            engine = AppWorld.engine(world, sys)

            # The read of a container the other slot left raises, with its
            # environment and the token that slot gave it.
            Model.put_container(engine, "addon_" <> @plain,
              state: "exited",
              env: ["SUPERVISOR_TOKEN=" <> @other_slot_token]
            )

            :atomics.put(faults, 1, 4)
            install(world, sys, @plain, %{run: true})
            await!(sys, :app, @plain, :ready)
            settle(sys)
            assert :atomics.get(faults, 1) == 0
            install(world, sys, @watched, %{run: true, settings: %{watchdog: true}})
            keep.(sys)

            # A create that raises with the token it had just minted in hand.
            :atomics.put(faults, 1, 1)
            app = write(sys, @plain, [{:inc, [:restart_counter]}])
            hit.(:create, app.status.failure)
            keep.(sys)
            :atomics.put(faults, 1, 0)
            assert verdict(write(sys, @plain, [{:inc, [:start_counter]}])) == @ready

            # A token put that raises with the environment it had just read.
            :atomics.put(faults, 1, 2)
            app = write(sys, @plain, [{:inc, [:restart_counter]}])
            hit.(:put_token, app.status.failure)
            keep.(sys)
            :atomics.put(faults, 1, 0)
            assert verdict(write(sys, @plain, [{:inc, [:start_counter]}])) == @ready

            # An observation whose read raises the same way. The pass says
            # the engine failed it, and the next one sees the app as it is.
            :atomics.put(faults, 1, 3)
            wake(sys, @plain)
            await!(sys, :app, @plain, :ready)
            settle(sys)
            assert :atomics.get(faults, 1) == 0
            keep.(sys)

            # A pass that raises with the instance in hand: the prober
            # falls over, once.
            Model.crash(engine, "app_" <> @watched)
            wake(sys, @watched)
            advance(sys, @watched, 10_000)
            :atomics.put(world.probe, 1, 2)
            advance(sys, @watched, 120_000)
            await!(sys, :app, @watched, :ready)
            settle(sys)
            keep.(sys)

            # A create that fails before anything is minted.
            :atomics.put(network, 1, 1)
            Model.put_image(engine, AppWorld.image(world, AppWorld.spec(world, @early)))

            {:ok, _app} =
              Store.create(:app, @early, AppWorld.spec(world, @early, %{run: true}), sys.i)

            await!(sys, :app, @early, &(&1.status[:failure] != nil))
            settle(sys)
            assert %{action: :create} = failed.(sys, @early)
            keep.(sys)
            :atomics.put(network, 1, 0)
            assert verdict(advance(sys, @early, 1_000)) == @ready

            # Core: its token is the Supervisor's own, and the put of it
            # raises as the others'.
            Model.put_container(engine, @core,
              restart_policy: "unless-stopped",
              env: ["SUPERVISOR_TOKEN=#{@supervisor_token}"]
            )

            :atomics.put(faults, 1, 2)
            core = %{lifecycle: :core, version: "2026.8.0", run: true}
            {:ok, _core} = Store.create(:app, @core, core, sys.i)
            await!(sys, :app, @core, &is_map_key(&1.status, :state))
            settle(sys)
            hit.(:put_token, failed.(sys, @core))
            keep.(sys)
            :atomics.put(faults, 1, 0)
            assert verdict(write(sys, @core, [{:inc, [:start_counter]}])) == @ready
            assert AuthIndex.lookup(@supervisor_token, sys.i) == {:ok, @core}

            # In flight: a step held inside its start, the token already in
            # the table, and a pull that stalls.
            stalled = AppWorld.spec(world, @once, %{run: true})

            Model.script_pull(
              engine,
              AppWorld.image(world, stalled),
              {:stall, [Model.downloading("layer", 1, 100)]}
            )

            {:ok, _app} = Store.create(:app, @once, stalled, sys.i)
            await!(sys, :app, @once, &(&1.status[:state] == :pulling))
            Model.hold(engine, :post, "/start")
            {:ok, _app} = Store.update_spec(:app, @plain, [{:inc, [:restart_counter]}], sys.i)

            assert_receive {:fake_engine, :held,
                            %{path: "/containers/app_" <> @plain <> "/start"}},
                           5_000

            held = look(sys, path)
            assert [_step] = held.anywhere[:steps]
            assert [_pull] = held.anywhere[:pull_tasks]
            assert is_map_key(held.anywhere[:info].in_flight, @plain)
            :ets.insert(seen, {:look, held})
            Model.release(engine)
            await!(sys, :app, @plain, :ready)
            settle(sys)

            kill_runtime(sys, Controller)
            settle(sys)
            keep.(sys)

            {:ok, _app} = Store.delete(:app, @plain, sys.i)
            await!(sys, :app, @plain, :gone)
            keep.(sys)
            :ets.insert(seen, {:tokens, minted(engine)})
          end)
        after
          # Whatever became of the scenario: a tracer left on outlives the test.
          :erlang.trace(:new_processes, false, [:call])

          for function <- [observe: 2, reconcile: 2, act: 3],
              do:
                :erlang.trace_pattern({Controller, elem(function, 0), elem(function, 1)}, false, [
                  :local
                ])
        end

      [tokens: tokens] = :ets.lookup(seen, :tokens)
      assert length(tokens) >= 5
      assert Enum.all?(tokens, &(byte_size(&1) == 43))
      # Each of the three faults was reported, and a pass that raised too:
      # crash reports are among what is read.
      assert log =~ "a step holding a token crashed"
      assert log =~ "the prober fell over"

      calls = traced()

      for function <- [:observe, :reconcile, :act],
          do: assert(List.keymember?(calls, function, 0))

      looks = for {:look, look} <- :ets.lookup(seen, :look), do: look

      anywhere =
        [log: log, callbacks: text(calls)] ++
          for(look <- looks, {where, term} <- look.anywhere, do: {where, text(term)})

      table = for look <- looks, {where, term} <- look.table, do: {where, text(term)}

      for secret <- [@supervisor_token, @other_slot_token | tokens] do
        %{token: [token], digest: digests} = forms(secret)

        for {where, text} <- anywhere ++ table,
            do: refute(text =~ token, "a token is in #{where}")

        for {where, text} <- anywhere, form <- digests do
          refute text =~ form, "a token's digest is in #{where}"
        end
      end

      for {where, text} <- anywhere ++ table,
          do: refute(text =~ "SUPERVISOR_TOKEN", "an environment is in #{where}")

      assert [create: _, put_token: _, put_token: _] =
               hits =
               for({:hit, action, failure} <- :ets.lookup(seen, :hit), do: {action, failure})

      for {action, failure} <- hits,
          do: assert(%{action: ^action, class: :permanent, cause: :crashed} = failure)
    end
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
          Map.put(Map.take(AppWorld.context(world), [:prepare]), :api_ready, fn ->
            true
          end),
        observer: [events: {Vagus.Runtime.Events, events}, interval: :infinity]
      ]

      %{world: world, opts: opts, events: events}
    end

    test "is the controller with a long resync of its own, what it stands on, and the observer",
         %{world: world, opts: opts, events: events} do
      engine = [socket: world.socket]
      wiring = Vagus.App.wiring([instance: I] ++ opts)
      assert Keyword.keys(wiring) == [:controllers, :services, :observers]

      assert [{Controller, runtime}] = wiring[:controllers]
      assert Keyword.keys(runtime) == [:resync, :max_in_flight_steps, :context]
      assert runtime[:resync] == :timer.hours(1)
      # Twice the engine lane's four slots: see the controller's "Lanes".
      assert runtime[:max_in_flight_steps] == 8

      context = runtime[:context]
      assert Enum.sort(Map.keys(context)) == [:api_ready, :backends, :facts, :gates, :prepare]
      assert context.facts == Vagus.App.Facts.read(data_root: world.data)
      assert context.gates == []
      # The test's own, over the application's: `&Vagus.API.Listener.accepting?/0`.
      assert context.api_ready == opts[:context].api_ready
      assert context.prepare == opts[:context].prepare

      assert context.backends == %{
               Backend.Container => [engine: engine],
               Backend.Native => []
             }

      assert wiring[:services] == [
               {AuthIndex, instance: I},
               {Pulls, instance: I, engine: engine},
               Supervisor.child_spec({Task.Supervisor, name: Pulls.tasks(I)}, id: Pulls.tasks(I)),
               Boot.child_spec(instance: I, marker: opts[:boot_marker])
             ]

      assert wiring[:observers] == [
               {EngineObserver,
                controller: Controller,
                instance: I,
                backend_opts: [engine: engine],
                events: {Vagus.Runtime.Events, events},
                interval: :infinity}
             ]

      # With nothing given: the application's own instance, engine and API,
      # the boot marker beside the run directory, and no gate.
      assert [{Controller, plain}] = Vagus.App.wiring()[:controllers]
      assert plain[:context].api_ready == (&Vagus.API.Listener.accepting?/0)
      assert plain[:context].gates == []

      assert plain[:context].backends == %{
               Backend.Container => [engine: []],
               Backend.Native => []
             }

      assert [{AuthIndex, instance: Vagus.Resource}, _pulls, _tasks, boot] =
               Vagus.App.wiring()[:services]

      assert boot == Boot.child_spec(instance: Vagus.Resource)

      # Only a gate somebody opens is waited for, and a resync asked for is had.
      assert [{Controller, gated}] =
               Vagus.App.wiring(gates: [:dns_ready], resync: 5_000)[:controllers]

      assert gated[:context].gates == [:dns_ready]
      assert gated[:resync] == 5_000
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
      # An engine tells of nothing that happened before it was asked.
      :ok = Model.await_event_stream(engine)
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
      # A pattern is set on code that is loaded, and on no other.
      for module <- @traced, do: Code.ensure_loaded!(module)
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
