defmodule Vagus.App.Controller.ScenarioTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  import Vagus.Test.AppWorld,
    only: [actions: 2, advance: 3, install: 3, install: 4, verdict: 1, wake: 2, write: 3]

  alias Vagus.App.{AuthIndex, Controller, Prepare, Pulls}
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Resource.{Store, TestInstance}
  alias Vagus.Test.AppWorld
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log
  @moduletag :scenario

  @plain "only_host_uts"
  @watched "45df7312_zigbee2mqtt"
  @once "local_once"
  @manual "elixir_probe"
  @early "core_mosquitto"

  @ready {true, false, false, :ready, :ready}
  @stopped {false, false, false, :stopped, :stopped}
  @start [:create, :put_token, :start]

  # The scenario undisturbed, and then once more for each boundary it
  # crossed, with the runtime killed there.
  defp run(world, extra \\ [], scenario) do
    Faults.each_boundary(
      system: AppWorld.system(world, extra),
      normalize: &AppWorld.normalize/1,
      scenario: fn sys -> scenario.(sys, AppWorld.engine(world, sys)) end
    )
  end

  defp watchdog, do: %{run: true, settings: %{watchdog: true}}
  defp get(sys, app), do: Store.get(:app, app, sys.i)
  defp attempts(app), do: app.status.restarts.attempts
  defp container(engine, app), do: Model.container(engine, "app_" <> app)
  defp token(engine, app), do: token_of(container(engine, app))

  defp token_of(%{env: env}) do
    Enum.find_value(env, fn
      "SUPERVISOR_TOKEN=" <> token -> token
      _other -> nil
    end)
  end

  defp tail(list, n), do: Enum.take(list, -n)

  # A hold as a backup would place it: owned by a resource, and gone with it.
  defp hold(sys, app) do
    {:ok, backup} = Store.create(:backup, "nightly", %{}, sys.i)

    {:ok, _app} =
      Store.update_spec(
        :app,
        app,
        [{:put, [:holds, "nightly"], true}],
        [writer: Vagus.Resource.writer(backup)] ++ sys.i
      )

    settle(sys)
  end

  defp crash(sys, engine, app, exit_code \\ 1) do
    Model.crash(engine, "app_" <> app, exit_code)
    wake(sys, app)
  end

  test "an installed app that is started becomes Ready, its token in the table before it ran" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      app = install(world, sys, @plain)
      assert verdict(app) == @stopped
      assert Controller.wire_state(app) == :stopped
      assert actions(sys, @plain) == []

      app = write(sys, @plain, %{run: true})
      assert verdict(app) == @ready
      assert Controller.wire_state(app) == :started
      # The put had returned before the start was decided, by a later pass.
      assert actions(sys, @plain) == @start

      assert AppWorld.writes(engine) == [
               {:post, "/containers/create"},
               {:post, "/containers/app_#{@plain}/start"}
             ]

      assert %{state: "running", id: id} = container(engine, @plain)
      assert AuthIndex.lookup(token(engine, @plain), sys.i) == {:ok, @plain}
      assert %{id: ^id, address: "172.30.33." <> _, running?: true} = app.status.instance
      refute is_map_key(app.status.instance, :env)

      options = Prepare.options_path(@plain, world.facts)
      assert File.read!(options) == "{}"
    end)
  end

  test "a stop removes the container, and its exit is no crash" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      held = token(engine, @watched)

      app = write(sys, @watched, %{run: false})
      assert verdict(app) == @stopped
      assert tail(actions(sys, @watched), 3) == [:remove_token, :stop, :remove]
      assert container(engine, @watched) == nil
      assert AuthIndex.lookup(held, sys.i) == :error
      assert attempts(app) == 0
      assert app.status.failure == nil
      assert app.status.instance == nil
    end)
  end

  test "a restart counter replaces the instance, and a start counter leaves a running one" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @plain, %{run: true})
      %{id: first} = container(engine, @plain)
      old = token(engine, @plain)

      app = write(sys, @plain, [{:inc, [:start_counter]}])
      assert verdict(app) == @ready
      assert actions(sys, @plain) == @start
      assert %{id: ^first} = container(engine, @plain)

      app = write(sys, @plain, [{:inc, [:restart_counter]}])
      assert verdict(app) == @ready
      assert actions(sys, @plain) == @start ++ [:stop, :remove] ++ @start
      assert %{id: second} = container(engine, @plain)
      assert second != first
      assert app.status.made_for.restart_counter == 1
      # The token of the instance before is nobody's.
      assert AuthIndex.lookup(old, sys.i) == :error
      assert AuthIndex.lookup(token(engine, @plain), sys.i) == {:ok, @plain}
    end)
  end

  test "options changed under a running app restart nothing, and are what the next instance gets" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @early, %{run: true})
      %{id: id} = container(engine, @early)
      options = Prepare.options_path(@early, world.facts)
      assert Jason.decode!(File.read!(options))["require_certificate"] == false

      app = write(sys, @early, %{options: %{"require_certificate" => true}})
      assert verdict(app) == @ready
      assert app.status.restart_required
      assert actions(sys, @early) == @start
      assert %{id: ^id, state: "running"} = container(engine, @early)
      assert Jason.decode!(File.read!(options))["require_certificate"] == false

      app = write(sys, @early, [{:inc, [:restart_counter]}])
      assert verdict(app) == @ready
      refute app.status.restart_required
      assert Jason.decode!(File.read!(options))["require_certificate"] == true
    end)
  end

  test "a crash is restarted within the budget, after its back-off" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      %{id: first} = container(engine, @watched)

      app = crash(sys, engine, @watched)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert attempts(app) == 1
      assert actions(sys, @watched) == @start ++ [:remove]
      assert container(engine, @watched) == nil

      app = advance(sys, @watched, 9_999)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert actions(sys, @watched) == @start ++ [:remove]

      app = advance(sys, @watched, 1)
      assert verdict(app) == @ready
      assert actions(sys, @watched) == @start ++ [:remove] ++ @start
      assert %{id: second, state: "running"} = container(engine, @watched)
      assert second != first
      assert attempts(app) == 1
    end)
  end

  test "the budget spent is Failed, and a restart asked for recovers" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())

      for attempt <- 1..5 do
        app = crash(sys, engine, @watched)
        assert verdict(app) == {false, true, false, :backing_off, :restarting}
        # One millisecond short of the pause is still a pause.
        pause = 10_000 * Integer.pow(2, attempt - 1)
        assert {_, true, _, :backing_off, _} = verdict(advance(sys, @watched, pause - 1))
        app = advance(sys, @watched, 1)
        assert verdict(app) == @ready
        assert attempts(app) == attempt
      end

      before = actions(sys, @watched)
      app = crash(sys, engine, @watched)
      assert verdict(app) == {false, false, true, :restart_budget_exhausted, :failed}
      assert Controller.wire_state(app) == :error
      assert app.spec.run
      assert %{state: "exited"} = container(engine, @watched)
      assert wake(sys, @watched) |> verdict() == verdict(app)
      assert actions(sys, @watched) == before

      app = write(sys, @watched, [{:inc, [:restart_counter]}])
      assert verdict(app) == @ready
      assert attempts(app) == 0
      assert actions(sys, @watched) == before ++ [:remove] ++ @start
    end)
  end

  test "Ready held for long enough forgets the attempts" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      crash(sys, engine, @watched)
      app = advance(sys, @watched, 10_000)
      assert verdict(app) == @ready
      assert attempts(app) == 1

      app = advance(sys, @watched, 599_999)
      assert attempts(app) == 1
      app = advance(sys, @watched, 1)
      assert verdict(app) == @ready
      assert attempts(app) == 0
    end)
  end

  test "a running container the engine calls unhealthy is restarted" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      Model.set_health(engine, "app_" <> @watched, "unhealthy", 3)

      app = wake(sys, @watched)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert attempts(app) == 1
      assert actions(sys, @watched) == @start ++ [:stop, :remove]

      app = advance(sys, @watched, 10_000)
      assert verdict(app) == @ready
      assert actions(sys, @watched) == @start ++ [:stop, :remove] ++ @start
    end)
  end

  test "an app that misses its probe twice, two minutes apart, is restarted" do
    world = AppWorld.new()

    run(world, fn sys, _engine ->
      :atomics.put(world.probe, 1, 0)
      install(world, sys, @watched, watchdog())
      :atomics.put(world.probe, 1, 1)

      app = advance(sys, @watched, 119_999)
      assert app.status.probe.misses == 0
      app = advance(sys, @watched, 1)
      assert verdict(app) == @ready
      assert app.status.probe.misses == 1
      assert actions(sys, @watched) == @start

      app = advance(sys, @watched, 120_000)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert actions(sys, @watched) == @start ++ [:stop, :remove]

      :atomics.put(world.probe, 1, 0)
      assert verdict(advance(sys, @watched, 10_000)) == @ready
    end)
  end

  test "an app that ended as it was being stopped is not a crash, and starts again when asked" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      Model.crash(engine, "app_" <> @watched, 0)

      app = write(sys, @watched, %{run: false})
      assert verdict(app) == @stopped
      assert attempts(app) == 0
      assert actions(sys, @watched) == @start ++ [:remove_token, :remove]

      app = write(sys, @watched, %{run: true})
      assert verdict(app) == @ready
      assert attempts(app) == 0
    end)
  end

  test "with the watchdog off a dead container is Failed and stays, until a start is asked for" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @plain, %{run: true})

      app = crash(sys, engine, @plain, 137)
      assert verdict(app) == {false, false, true, :crashed, :failed}
      assert Controller.wire_state(app) == :error
      assert app.status.failure.detail == %{exit_code: 137}
      assert app.spec.run
      assert %{state: "exited"} = container(engine, @plain)
      assert wake(sys, @plain) |> verdict() == verdict(app)
      assert actions(sys, @plain) == @start

      # Any other write is no reason to try again.
      app = write(sys, @plain, %{settings: %{protected: false}})
      assert {false, false, true, :crashed, :failed} = verdict(app)
      assert actions(sys, @plain) == @start

      app = write(sys, @plain, [{:inc, [:start_counter]}])
      assert verdict(app) == @ready
      assert actions(sys, @plain) == @start ++ [:remove] ++ @start
    end)
  end

  test "an app that runs once: exit 0 is done, anything else has failed" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @once, %{run: true})
      assert verdict(get(sys, @once)) == @ready

      app = crash(sys, engine, @once, 0)
      assert verdict(app) == {false, false, false, :succeeded, :succeeded}
      assert Controller.wire_state(app) == :stopped
      assert actions(sys, @once) == @start

      app = write(sys, @once, [{:inc, [:start_counter]}])
      assert verdict(app) == @ready

      app = crash(sys, engine, @once, 3)
      assert verdict(app) == {false, false, true, :crashed, :failed}
      assert Controller.wire_state(app) == :error
      assert actions(sys, @once) == @start ++ [:remove] ++ @start
    end)
  end

  test "a stop during a pull cancels the pull" do
    world = AppWorld.new()
    spec = AppWorld.spec(world, @plain, %{run: true})
    image = AppWorld.image(world, spec)

    run(world, fn sys, engine ->
      Model.script_pull(engine, image, {:stall, [Model.downloading("layer", 1, 100)]})
      {:ok, _app} = Store.create(:app, @plain, spec, sys.i)
      app = await!(sys, :app, @plain, &(&1.status[:state] == :pulling))
      settle(sys)
      assert Controller.wire_state(app) == :stopped
      assert %{^image => %{waiters: [{Controller, @plain}]}} = Pulls.info(sys.i)

      app = write(sys, @plain, %{run: false})
      assert verdict(app) == @stopped
      assert actions(sys, @plain) == [:request_pull, :cancel_pull]
      assert Pulls.info(sys.i) == %{}
      assert Pulls.state(image, sys.i) == :idle
      assert container(engine, @plain) == nil
    end)
  end

  test "a pull refused for good is Failed and not asked for again" do
    world = AppWorld.new()
    spec = AppWorld.spec(world, @plain, %{run: true})
    image = AppWorld.image(world, spec)

    run(world, fn sys, engine ->
      Model.script_pull(engine, image, :not_found)
      {:ok, _app} = Store.create(:app, @plain, spec, sys.i)
      app = await!(sys, :app, @plain, :failed)
      settle(sys)
      assert verdict(get(sys, @plain)) == {false, false, true, :pull_denied, :failed}
      assert Controller.wire_state(app) == :error
      assert verdict(wake(sys, @plain)) == {false, false, true, :pull_denied, :failed}
      assert actions(sys, @plain) == [:request_pull]
    end)
  end

  test "a pull that failed for now is asked for again after a pause" do
    world = AppWorld.new()
    spec = AppWorld.spec(world, @plain, %{run: true})
    image = AppWorld.image(world, spec)

    run(world, fn sys, engine ->
      Model.script_pull(engine, image, {:error, "unexpected EOF"})
      {:ok, _app} = Store.create(:app, @plain, spec, sys.i)
      await!(sys, :app, @plain, &match?(%{reason: :pull_failed}, &1.status[:conditions][:ready]))
      settle(sys)
      assert verdict(get(sys, @plain)) == {false, true, false, :pull_failed, :pulling}
      assert actions(sys, @plain) == [:request_pull]

      assert verdict(advance(sys, @plain, 999)) == {false, true, false, :pull_failed, :pulling}
      assert actions(sys, @plain) == [:request_pull]

      Model.script_pull(engine, image, :ok)
      advance(sys, @plain, 1)
      await!(sys, :app, @plain, :ready)
      settle(sys)
      assert actions(sys, @plain) == [:request_pull, :request_pull] ++ @start
    end)
  end

  test "with the engine away an app waits, nothing counted, and starts when it is back" do
    world = AppWorld.new()
    spec = AppWorld.spec(world, @watched, watchdog())
    world = %{world | seed: &Model.put_image(&1, AppWorld.image(world, spec))}

    run(world, fn sys, _engine ->
      AppWorld.engine_down(sys)
      {:ok, _app} = Store.create(:app, @watched, spec, sys.i)

      app =
        await!(
          sys,
          :app,
          @watched,
          &match?(%{status: true}, &1.status[:conditions][:progressing])
        )

      assert %{reason: :engine_unavailable} = app.status.conditions.ready
      assert Controller.wire_state(app) == :unknown
      refute is_map_key(app.status, :failure)
      assert actions(sys, @watched) == []
      settle(sys)
      assert info(sys, Controller).failures == %{}

      AppWorld.engine_up(sys)
      app = await!(sys, :app, @watched, :ready)
      settle(sys)
      assert attempts(app) == 0
      assert app.status.failure == nil
      assert actions(sys, @watched) == @start
    end)
  end

  test "a port that is taken fails the start for good, with the port" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      Model.fail_start(
        engine,
        "app_" <> @plain,
        "driver failed programming external connectivity: Bind for 0.0.0.0:8080 failed: " <>
          "port is already allocated"
      )

      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, false, true, :port_conflict, :failed}
      assert Controller.wire_state(app) == :error

      assert %{action: :start, class: :permanent, cause: :port_conflict, detail: %{port: 8080}} =
               app.status.failure

      assert verdict(wake(sys, @plain)) == verdict(app)
      # Asked for once, and not again.
      assert actions(sys, @plain) == @start

      # The next attempt is the user's, and starts the container made before.
      Model.fail_start(engine, "app_" <> @plain, nil)
      app = write(sys, @plain, [{:inc, [:start_counter]}])
      assert verdict(app) == @ready
    end)
  end

  test "an app waits for an earlier wave, for at most its wait" do
    world = AppWorld.new()
    early = AppWorld.spec(world, @early, %{run: true})

    run(world, fn sys, engine ->
      Model.script_pull(engine, AppWorld.image(world, early), {:error, "unexpected EOF"})
      {:ok, _app} = Store.create(:app, @early, early, sys.i)
      await!(sys, :app, @early, &match?(%{reason: :pull_failed}, &1.status[:conditions][:ready]))
      settle(sys)

      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :waiting_for_wave, :waiting}
      assert app.status.waiting_on == [@early]
      assert Controller.wire_state(app) == :stopped
      assert actions(sys, @plain) == []

      assert {_, true, _, :waiting_for_wave, _} = verdict(advance(sys, @plain, 119_999))
      app = advance(sys, @plain, 1)
      assert verdict(app) == @ready
      assert app.status.waiting_on == []
      assert {_, true, _, :pull_failed, _} = verdict(get(sys, @early))
    end)
  end

  test "an earlier wave becoming Ready wakes the app that waits, with no timer" do
    world = AppWorld.new()
    early = AppWorld.spec(world, @early, %{run: true})

    run(world, fn sys, engine ->
      Model.script_pull(engine, AppWorld.image(world, early), {:error, "unexpected EOF"})
      {:ok, _app} = Store.create(:app, @early, early, sys.i)
      await!(sys, :app, @early, &match?(%{reason: :pull_failed}, &1.status[:conditions][:ready]))
      settle(sys)

      app = install(world, sys, @plain, %{run: true})
      assert {_, true, _, :waiting_for_wave, _} = verdict(app)
      waiting = pending_timer(sys, Controller, @plain)

      # The earlier app's pull is tried again and succeeds. The clock moves
      # one second of the waiter's two minutes, and its timer is not fired.
      Model.script_pull(engine, AppWorld.image(world, early), :ok)
      advance(sys, @early, 1_000)
      await!(sys, :app, @early, :ready)
      await!(sys, :app, @plain, :ready)
      settle(sys)
      assert waiting.remaining > 60_000
      assert AppWorld.acted?(sys, @plain, @start)
    end)
  end

  test "an uninstall takes the token first and the finalizer last, and leaves nothing" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      spec = AppWorld.spec(world, @plain, %{run: true})
      install(world, sys, @plain, %{run: true})
      held = token(engine, @plain)
      data = Prepare.data_dir(@plain, world.facts)
      assert File.dir?(data)

      {:ok, _app} = Store.delete(:app, @plain, sys.i)
      await!(sys, :app, @plain, :gone)
      settle(sys)

      assert actions(sys, @plain) ==
               @start ++ [:remove_token, :stop, :remove, :remove_image, :remove_data]

      assert container(engine, @plain) == nil

      assert Vagus.App.Backend.Container.image_present?(AppWorld.image(world, spec),
               engine: [socket: engine.socket]
             ) == {:ok, false}

      assert AuthIndex.lookup(held, sys.i) == :error
      assert AuthIndex.digest_of(@plain, sys.i) == :error
      assert snapshot(sys) == []
      refute File.exists?(data)
    end)
  end

  test "an image another container still uses is left, and the uninstall ends all the same" do
    world = AppWorld.new()
    image = AppWorld.image(world, AppWorld.spec(world, @plain))

    run(world, fn sys, engine ->
      install(world, sys, @plain, %{run: true})
      Model.put_container(engine, "somebody_elses", image: image, state: "exited")

      {:ok, _app} = Store.delete(:app, @plain, sys.i)
      await!(sys, :app, @plain, :gone)
      settle(sys)

      # Asked for once: its refusal is the end of that step.
      assert actions(sys, @plain) ==
               @start ++ [:remove_token, :stop, :remove, :remove_image, :remove_data]

      assert Vagus.App.Backend.Container.image_present?(image, engine: [socket: engine.socket]) ==
               {:ok, true}

      assert snapshot(sys) == []
    end)
  end

  test "a container the other firmware slot left is stopped and removed before one is created" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      Model.put_container(engine, "addon_" <> @plain, state: "running")
      app = install(world, sys, @plain)
      # Not waiting for a start: it holds the app's ports either way.
      assert verdict(app) == @stopped
      assert actions(sys, @plain) == [:stop_leftover, :remove_leftover]
      assert Model.container(engine, "addon_" <> @plain) == nil

      Model.put_container(engine, "addon_" <> @plain, state: "exited")
      app = write(sys, @plain, %{run: true})
      assert verdict(app) == @ready

      assert actions(sys, @plain) ==
               [:stop_leftover, :remove_leftover, :remove_leftover] ++ @start

      assert Model.container(engine, "addon_" <> @plain) == nil
    end)
  end

  test "a hold stops the app and its release starts it again" do
    world = AppWorld.new()

    run(world, [kinds: %{backup: []}], fn sys, engine ->
      install(world, sys, @watched, watchdog())
      hold(sys, @watched)
      app = get(sys, @watched)
      assert verdict(app) == {false, false, false, :held, :stopped}
      assert app.spec.run
      assert container(engine, @watched) == nil
      assert attempts(app) == 0

      # The holder gone, the hold goes with it.
      {:ok, _backup} = Store.delete(:backup, "nightly", sys.i)
      settle(sys)
      app = get(sys, @watched)
      assert app.spec.holds == %{}
      assert verdict(app) == @ready
      assert attempts(app) == 0
      assert actions(sys, @watched) == @start ++ [:remove_token, :stop, :remove] ++ @start
    end)
  end

  test "a hold placed in the middle of a start takes the start back" do
    world = AppWorld.new()

    run(world, [kinds: %{backup: []}], fn sys, engine ->
      Model.fail_start(engine, "app_" <> @plain, "no space left on device")
      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :engine_error, :starting}
      assert %{state: "created"} = container(engine, @plain)
      hold(sys, @plain)
      app = get(sys, @plain)
      assert verdict(app) == {false, false, false, :held, :stopped}
      assert actions(sys, @plain) == @start ++ [:remove_token, :remove]
      assert container(engine, @plain) == nil
      assert app.status.failure == nil

      Model.fail_start(engine, "app_" <> @plain, nil)
      {:ok, _backup} = Store.delete(:backup, "nightly", sys.i)
      settle(sys)
      assert verdict(get(sys, @plain)) == @ready
    end)
  end

  defmodule Gate do
    @moduledoc """
    Attached to the App kind as a controller that registers an instance
    somewhere would be: it writes `:dns_ready`, true once the test says the
    instance of that id is registered, and names the id in the message.
    """
    @behaviour Vagus.Resource.Controller

    alias Vagus.Resource.{Harness, Verdict}

    @impl true
    def kind, do: :app
    @impl true
    def condition_types, do: [:dns_ready]
    @impl true
    def owned_conditions, do: [:dns_ready]

    @impl true
    def observe(%{name: name}, context), do: Harness.fact(context, {:registered, name})

    @impl true
    def reconcile(_app, nil), do: {Verdict.new(dns_ready: {false, :unregistered}), []}
    def reconcile(_app, id), do: {Verdict.new(dns_ready: {true, :registered, id}), []}

    @impl true
    def act(_action, _args, _context), do: :ok
  end

  test "an app waits for its gate, which opens only for the instance that runs" do
    world = AppWorld.new(gates: [:dns_ready])
    system = AppWorld.system(world)
    system = Keyword.update!(system, :controllers, &(&1 ++ [Gate]))

    register = fn sys, id ->
      put_fact(sys, {:registered, @plain}, id)
      :ok = Vagus.Resource.Runtime.enqueue(Gate, @plain, sys.i)
      _info = Vagus.Resource.Runtime.info(Gate, sys.i)
      settle(sys)
      get(sys, @plain)
    end

    Faults.each_boundary(
      system: system,
      normalize: &AppWorld.normalize/1,
      scenario: fn sys ->
        engine = AppWorld.engine(world, sys)
        app = install(world, sys, @plain, %{run: true})
        # Running, and neither Ready nor Failed for as long as the gate is shut.
        assert verdict(app) == {false, true, false, :waiting_for_gate, :starting}
        assert Controller.wire_state(app) == :startup
        assert %{state: "running", id: first} = container(engine, @plain)

        assert verdict(register.(sys, first)) == @ready

        # A new instance: the gate still names the one before.
        app = write(sys, @plain, [{:inc, [:restart_counter]}])
        assert %{id: second} = container(engine, @plain)
        assert second != first
        assert %{status: true, message: ^first} = app.status.conditions.dns_ready
        assert verdict(app) == {false, true, false, :waiting_for_gate, :starting}
        assert Controller.wire_state(app) == :startup

        assert verdict(register.(sys, second)) == @ready
      end
    )
  end

  test "the token of a running app is put back into a token table that was replaced" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @plain, %{run: true})
      %{id: id} = container(engine, @plain)
      held = token(engine, @plain)

      index = Process.whereis(AuthIndex.name(sys.instance))
      TestInstance.kill_observed(index, Process.whereis(Module.concat(sys.instance, Supervisor)))
      settle(sys)
      await!(sys, :app, @plain, :ready)
      settle(sys)

      assert Process.whereis(AuthIndex.name(sys.instance)) != index
      assert AuthIndex.lookup(held, sys.i) == {:ok, @plain}
      assert %{id: ^id, state: "running"} = container(engine, @plain)
      assert token(engine, @plain) == held
      assert verdict(get(sys, @plain)) == @ready
      # The world outlives the runtime, so this is every action there was.
      assert actions(sys, @plain) == @start ++ [:put_token]
    end)
  end

  test "containers a shutdown stops are left alone, and are no crashes at the next boot" do
    world = AppWorld.new()
    path = Path.join(world.root, "resources.json")
    spec = AppWorld.spec(world, @watched, watchdog())
    image = AppWorld.image(world, spec)

    world = %{world | before: fn -> File.rm(path) end}

    run(world, [path: path], fn sys, engine ->
      install(world, sys, @watched, watchdog())
      before = get(sys, @watched)

      shutdown(sys, true)
      Model.crash(engine, "app_" <> @watched, 143)
      app = wake(sys, @watched)
      assert app.status == before.status
      assert actions(sys, @watched) == @start
      assert %{state: "exited"} = container(engine, @watched)
    end)

    # The boot after: the store's file, an engine whose containers are as
    # the shutdown left them, and no status.
    world = %{
      world
      | before: fn -> :ok end,
        seed: fn engine ->
          Model.put_image(engine, image)

          Model.put_container(engine, "app_" <> @watched,
            state: "exited",
            exit_code: 143,
            image: image
          )
        end
    }

    sys = start_system(AppWorld.system(world, path: path))
    app = await!(sys, :app, @watched, :ready)
    settle(sys)
    assert attempts(app) == 0
    assert app.status.failure == nil
    assert actions(sys, @watched) == [:remove] ++ @start
  end

  test "Core: what there is of it" do
    world = AppWorld.new()
    core = %{lifecycle: :core, version: "2026.8.0", run: true}

    run(world, fn sys, engine ->
      # No container, and nothing here that could make one.
      {:ok, _core} = Store.create(:app, "homeassistant", core, sys.i)
      settle(sys)
      app = get(sys, "homeassistant")
      assert verdict(app) == {false, false, true, :no_container_builder, :failed}
      assert Controller.wire_state(app) == :error
      assert actions(sys, "homeassistant") == []
      assert info(sys, Controller).failures == %{}

      # One that is there is taken as it is: its token put, and asked
      # whether it answers.
      :atomics.put(world.probe, 1, 1)

      Model.put_container(engine, "homeassistant",
        state: "running",
        restart_policy: "unless-stopped",
        env: ["SUPERVISOR_TOKEN=the-supervisor-token", "S6_SERVICES_GRACETIME=240000"]
      )

      app = wake(sys, "homeassistant")
      assert verdict(app) == {false, true, false, :not_answering, :starting}
      assert Controller.wire_state(app) == :startup
      assert actions(sys, "homeassistant") == [:put_token]
      assert AuthIndex.lookup("the-supervisor-token", sys.i) == {:ok, "homeassistant"}

      :atomics.put(world.probe, 1, 0)
      app = advance(sys, "homeassistant", 5_000)
      assert verdict(app) == @ready

      # A stop keeps the container, with the grace its image asks for.
      app = write(sys, "homeassistant", %{run: false})
      assert verdict(app) == @stopped
      assert %{state: "exited"} = Model.container(engine, "homeassistant")
      assert actions(sys, "homeassistant") == [:put_token, :remove_token, :stop]

      assert %{query: %{"t" => "260"}} =
               Enum.find(Vagus.Test.FakeEngine.requests(engine), &(&1.path =~ "/stop"))

      app = write(sys, "homeassistant", %{run: true})
      assert verdict(app) == @ready
      assert tail(actions(sys, "homeassistant"), 2) == [:put_token, :start]

      # Restarted by the engine three times in ten minutes: a crash loop,
      # which cannot be answered by making the container anew.
      for _ <- 1..3 do
        Model.crash(engine, "homeassistant")
        wake(sys, "homeassistant")
      end

      app = get(sys, "homeassistant")
      assert verdict(app) == {false, false, true, :crash_loop, :failed}
      assert %{state: "running", restart_count: 3} = Model.container(engine, "homeassistant")
      assert tail(actions(sys, "homeassistant"), 2) == [:put_token, :start]
    end)
  end
end
