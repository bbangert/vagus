defmodule Vagus.App.Controller.ScenarioTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  import Vagus.Test.AppWorld,
    only: [
      actions: 2,
      advance: 3,
      advance: 4,
      install: 3,
      install: 4,
      verdict: 1,
      wake: 2,
      write: 3
    ]

  alias Vagus.App.{AuthIndex, Controller, Prepare, Pulls}
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Resource.{Store, TestInstance}
  alias Vagus.Test.AppWorld
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log
  @moduletag :scenario
  # A scenario runs once more for each boundary it crosses.
  @moduletag timeout: 180_000

  # No scenario rests a millisecond short of a pause. The runtime's timers
  # run on real time: one armed for the millisecond that is left comes round
  # every millisecond for as long as the clock stands, a pass each time. The
  # instants themselves are the table's to pin (`Vagus.Test.AppRows`).

  @plain "only_host_uts"
  @watched "45df7312_zigbee2mqtt"
  @once "local_once"
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
      journal: &AppWorld.journal/1,
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
      assert tail(actions(sys, @watched), 3) == [:stop, :remove, :remove_token]
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

      app = advance(sys, @watched, 9_000)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert actions(sys, @watched) == @start ++ [:remove]

      app = advance(sys, @watched, 1_000)
      assert verdict(app) == @ready
      assert actions(sys, @watched) == @start ++ [:remove] ++ @start
      assert %{id: second, state: "running"} = container(engine, @watched)
      assert second != first
      assert attempts(app) == 1
    end)
  end

  # Six crashes and five restarts: several times the boundaries of any other
  # scenario, each of them one more run of the whole. On a core it shares
  # with others every call to the engine waits its turn, and the runs
  # together take minutes.
  @tag timeout: 900_000
  test "the budget spent is Failed, and a restart asked for recovers" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())

      for attempt <- 1..5 do
        app = crash(sys, engine, @watched)
        assert verdict(app) == {false, true, false, :backing_off, :restarting}
        # A second short of the pause is still a pause.
        pause = 10_000 * Integer.pow(2, attempt - 1)
        assert {_, true, _, :backing_off, _} = verdict(advance(sys, @watched, pause - 1_000))
        app = advance(sys, @watched, 1_000)
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

      app = advance(sys, @watched, 599_000)
      assert attempts(app) == 1
      app = advance(sys, @watched, 1_000)
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
      # The stop that followed was the controller's own: one attempt, not two.
      assert attempts(wake(sys, @watched)) == 1
    end)
  end

  test "a restart asked for of an app that is to run is no crash: nothing is counted" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      %{id: first} = container(engine, @watched)

      app = write(sys, @watched, [{:inc, [:restart_counter]}])
      assert verdict(app) == @ready
      assert %{id: second} = container(engine, @watched)
      assert second != first
      assert actions(sys, @watched) == @start ++ [:stop, :remove] ++ @start
      app = wake(sys, @watched)
      assert attempts(app) == 0
      assert app.status.failure == nil
      assert app.status.expected_exit == nil
    end)
  end

  test "a container put in the place of the one recorded is taken as it is, its token put" do
    world = AppWorld.new()
    image = AppWorld.image(world, AppWorld.spec(world, @watched))

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      %{id: first} = container(engine, @watched)
      old = token(engine, @watched)

      # Behind the controller's back: nothing here stopped the first.
      Model.delete_container(engine, "app_" <> @watched)

      second =
        Model.put_container(engine, "app_" <> @watched,
          image: image,
          env: ["SUPERVISOR_TOKEN=a-token-nobody-here-minted"]
        )

      app = wake(sys, @watched)
      assert verdict(app) == @ready
      assert second != first
      assert app.status.instance.id == second
      assert attempts(app) == 0
      assert app.status.failure == nil
      assert actions(sys, @watched) == @start ++ [:put_token]
      assert AuthIndex.lookup("a-token-nobody-here-minted", sys.i) == {:ok, @watched}
      assert AuthIndex.lookup(old, sys.i) == :error
    end)
  end

  test "a start the engine fails for now is asked for again after its pause, which doubles" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      Model.fail_start(engine, "app_" <> @plain, "no space left on device")
      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :engine_error, :starting}
      assert %{action: :start, class: :transient, count: 1} = app.status.failure
      assert actions(sys, @plain) == @start

      assert {_, true, _, :engine_error, :starting} = verdict(advance(sys, @plain, 500))
      assert actions(sys, @plain) == @start

      # The pause over, the same container is started, and refused again.
      app = advance(sys, @plain, 500)
      assert %{action: :start, count: 2} = app.status.failure
      assert actions(sys, @plain) == @start ++ [:start]

      Model.fail_start(engine, "app_" <> @plain, nil)
      assert {_, true, _, :engine_error, :starting} = verdict(advance(sys, @plain, 1_000))
      assert actions(sys, @plain) == @start ++ [:start]

      app = advance(sys, @plain, 1_000)
      assert verdict(app) == @ready
      assert app.status.failure == nil
      assert actions(sys, @plain) == @start ++ [:start, :start]
    end)
  end

  test "an app that misses its probe twice, two minutes apart, is restarted" do
    world = AppWorld.new()

    run(world, fn sys, _engine ->
      :atomics.put(world.probe, 1, 0)
      install(world, sys, @watched, watchdog())
      :atomics.put(world.probe, 1, 1)

      app = advance(sys, @watched, 119_000)
      assert app.status.probe.misses == 0
      app = advance(sys, @watched, 1_000)
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
      assert actions(sys, @watched) == @start ++ [:remove, :remove_token]

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

      assert verdict(advance(sys, @plain, 500)) == {false, true, false, :pull_failed, :pulling}
      assert actions(sys, @plain) == [:request_pull]

      Model.script_pull(engine, image, :ok)
      advance(sys, @plain, 500)
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

      # The next attempt is the user's, and is a container of its own: the
      # one whose start failed was made for the start asked for before.
      %{id: refused} = container(engine, @plain)
      Model.fail_start(engine, "app_" <> @plain, nil)
      app = write(sys, @plain, [{:inc, [:start_counter]}])
      assert verdict(app) == @ready
      assert %{id: started, state: "running"} = container(engine, @plain)
      assert started != refused
      assert actions(sys, @plain) == @start ++ [:remove] ++ @start
      assert app.status.failure == nil
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

      assert {_, true, _, :waiting_for_wave, _} = verdict(advance(sys, @plain, 119_000))
      # Time passed for the earlier app too: its pause is over, it has asked
      # again, and that pull fails like the first, whenever it gets to.
      await!(sys, :app, @early, &match?(%{failures: 2}, &1.status.pull))
      settle(sys)
      app = advance(sys, @plain, 1_000)
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
      steps = info(sys, Controller).steps

      # The earlier app's pull is tried again and succeeds. The clock moves
      # one second of the waiter's two minutes, and its timer is not fired.
      Model.script_pull(engine, AppWorld.image(world, early), :ok)
      advance(sys, @early, 1_000, timers: [@early])
      await!(sys, :app, @early, :ready)
      await!(sys, :app, @plain, :ready)
      settle(sys)
      # Not by its wait running out: one second of its two minutes has
      # passed on the clock it is measured by, and its own timer, which
      # nobody fired, is still far out. And not by looking again and again.
      assert Vagus.Resource.TestClock.now(sys.clock).at == 1_000
      assert info(sys, Controller).steps - steps < 40
      assert AppWorld.acted?(sys, @plain, @start)
    end)
  end

  test "no app is created while the API it calls as it starts is not accepting" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      :atomics.put(world.api, 1, 1)
      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :waiting_for_api, :waiting}
      assert actions(sys, @plain) == []
      assert container(engine, @plain) == nil

      :atomics.put(world.api, 1, 0)
      assert verdict(advance(sys, @plain, 0)) == @ready
      assert actions(sys, @plain) == @start
    end)
  end

  test "a start asked for during a back-off starts at once and forgets the count" do
    world = AppWorld.new()

    run(world, fn sys, engine ->
      install(world, sys, @watched, watchdog())
      app = crash(sys, engine, @watched)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert attempts(app) == 1

      # The clock has not moved: it is not the pause that ended.
      app = write(sys, @watched, [{:inc, [:start_counter]}])
      assert verdict(app) == @ready
      assert attempts(app) == 0
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
      assert actions(sys, @watched) == @start ++ [:stop, :remove, :remove_token] ++ @start
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
      assert actions(sys, @plain) == @start ++ [:remove, :remove_token]
      assert container(engine, @plain) == nil
      assert app.status.failure == nil

      Model.fail_start(engine, "app_" <> @plain, nil)
      {:ok, _backup} = Store.delete(:backup, "nightly", sys.i)
      settle(sys)
      assert verdict(get(sys, @plain)) == @ready
    end)
  end

  describe "a pass in flight" do
    setup do
      world = AppWorld.new()
      %{world: world}
    end

    # The app's next pass waits in its first read of the engine until the
    # test lets it go on: what the test does meanwhile lands during a pass.
    defp looking(sys, engine, app) do
      Model.hold(engine, :get, "/containers/app_#{app}/json")
      :ok = Vagus.Resource.Runtime.enqueue(Controller, app, sys.i)
      assert_receive {:fake_engine, :held, %{method: :get}}, sys.wait
    end

    test "that began before a stop was written does not report Ready for the stop's generation",
         %{world: world} do
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      %{generation: seen} = install(world, sys, @plain, %{run: true})

      # The pass the write brings is held too, so that what the pass before
      # it committed can be read before anything is written over it.
      looking(sys, engine, @plain)
      Model.hold(engine, :get, "/containers/app_#{@plain}/json")
      {:ok, %{generation: written}} = Store.update_spec(:app, @plain, %{run: false}, sys.i)
      assert written == seen + 1
      Model.release(engine)
      assert_receive {:fake_engine, :held, %{method: :get}}, sys.wait

      app = get(sys, @plain)
      assert app.generation == written
      # Ready is what the pass saw, and it says of which generation.
      assert %{status: true, observed_generation: ^seen} = app.status.conditions.ready
      assert app.status.observed_generation == seen

      Model.release(engine)
      settle(sys)
      app = get(sys, @plain)
      assert verdict(app) == @stopped
      assert %{status: false, observed_generation: ^written} = app.status.conditions.ready
    end

    test "does not lose a stop written meanwhile", %{world: world} do
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      install(world, sys, @plain, %{run: true})

      looking(sys, engine, @plain)
      {:ok, _app} = Store.update_spec(:app, @plain, %{run: false}, sys.i)
      Model.release(engine)
      settle(sys)

      assert verdict(get(sys, @plain)) == @stopped
      assert container(engine, @plain) == nil
      assert actions(sys, @plain) == @start ++ [:stop, :remove, :remove_token]
    end

    test "a start written while the stop is still under way: the exit that follows is no crash",
         %{world: world} do
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      install(world, sys, @watched, watchdog())

      Model.hold(engine, :post, "/stop")
      {:ok, _app} = Store.update_spec(:app, @watched, %{run: false}, sys.i)

      assert_receive {:fake_engine, :held, %{path: "/containers/app_" <> @watched <> "/stop"}},
                     sys.wait

      {:ok, _app} = Store.update_spec(:app, @watched, %{run: true}, sys.i)
      Model.release(engine)
      settle(sys)

      # The pass after the stop finds the app to run again and its container
      # exited. That exit was asked for: it is removed, and nothing counted.
      app = get(sys, @watched)
      assert verdict(app) == @ready
      assert attempts(app) == 0
      assert app.status.failure == nil
      assert actions(sys, @watched) == @start ++ [:stop, :remove] ++ @start
    end

    test "does not lose its gate opening meanwhile", %{world: world} do
      world = %{world | gates: [:dns_ready]}
      system = Keyword.update!(AppWorld.system(world), :controllers, &(&1 ++ [__MODULE__.Gate]))
      sys = start_system(system)
      engine = AppWorld.engine(world, sys)
      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :waiting_for_gate, :starting}
      %{id: id} = container(engine, @plain)

      looking(sys, engine, @plain)
      put_fact(sys, {:registered, @plain}, id)
      :ok = Vagus.Resource.Runtime.enqueue(__MODULE__.Gate, @plain, sys.i)
      await!(sys, :app, @plain, &match?(%{status: true}, &1.status.conditions[:dns_ready]))
      Model.release(engine)
      settle(sys)

      assert verdict(get(sys, @plain)) == @ready
    end

    test "a hold placed while the container is being created takes the start back",
         %{world: world} do
      sys = start_system(AppWorld.system(world, kinds: %{backup: []}))
      engine = AppWorld.engine(world, sys)
      install(world, sys, @plain)

      Model.hold(engine, :post, "/containers/create")
      {:ok, _app} = Store.update_spec(:app, @plain, %{run: true}, sys.i)
      assert_receive {:fake_engine, :held, %{path: "/containers/create"}}, sys.wait
      {:ok, backup} = Store.create(:backup, "nightly", %{}, sys.i)
      writer = [writer: Vagus.Resource.writer(backup)]

      {:ok, _app} =
        Store.update_spec(:app, @plain, [{:put, [:holds, "nightly"], true}], writer ++ sys.i)

      Model.release(engine)
      settle(sys)

      assert verdict(get(sys, @plain)) == {false, false, false, :held, :stopped}
      # Made, and taken away again: never given its token, never started.
      assert actions(sys, @plain) == [:create, :remove]
      assert container(engine, @plain) == nil
      assert AuthIndex.digest_of(@plain, sys.i) == :error
    end
  end

  describe "an action that fails before the engine is asked, or is refused by it" do
    test "an app that needs a DSP this device has not got is Failed, and made once it has" do
      world = AppWorld.new()
      dsp = :atomics.new(1, [])

      prepare = [
        network: fn -> :ok end,
        dsp_state: fn -> if(:atomics.get(dsp, 1) == 1, do: :configured, else: :unsupported) end,
        devices: [required_dsp_nodes: ["/dev/null"]]
      ]

      sys = start_system(AppWorld.system(world, context: %{prepare: prepare}))
      engine = AppWorld.engine(world, sys)

      app = install(world, sys, "local_dsp", %{run: true})
      assert verdict(app) == {false, false, true, :invalid_config, :failed}

      assert %{action: :create, class: :permanent, detail: {:invalid, {:dsp_unsupported, _}}} =
               app.status.failure

      # Refused before the engine was asked for anything.
      assert actions(sys, "local_dsp") == []
      assert AppWorld.writes(engine) == []

      :atomics.put(dsp, 1, 1)
      app = write(sys, "local_dsp", [{:inc, [:start_counter]}])
      assert verdict(app) == @ready
      assert actions(sys, "local_dsp") == @start
    end

    test "a data directory that cannot be made is tried again after a pause" do
      world = AppWorld.new()
      sys = start_system(AppWorld.system(world))
      File.mkdir_p!(world.data)
      File.write!(Path.join(world.data, "addons"), "in the way")

      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :unknown, :starting}

      assert %{action: :create, class: :transient, detail: {:mkdir, _path, _}} =
               app.status.failure

      assert actions(sys, @plain) == []

      File.rm!(Path.join(world.data, "addons"))
      assert {_, true, _, :unknown, _} = verdict(advance(sys, @plain, 500))
      assert verdict(advance(sys, @plain, 500)) == @ready
      assert actions(sys, @plain) == @start
    end

    test "a create the engine refuses because the name is taken is tried again after a pause" do
      world = AppWorld.new()
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      Model.fail(engine, :post, "/containers/create", {409, "Conflict. The name is in use"})

      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, true, false, :already_exists, :starting}
      assert %{action: :create, class: :transient, count: 1} = app.status.failure
      assert actions(sys, @plain) == [:create]

      Model.fail(engine, :post, "/containers/create", nil)
      assert verdict(advance(sys, @plain, 1_000)) == @ready
      assert actions(sys, @plain) == [:create] ++ @start
    end

    test "a token is not put for an instance that is no longer the one the pass saw" do
      world = AppWorld.new()
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      spec = AppWorld.spec(world, @plain)
      image = AppWorld.image(world, spec)
      install(world, sys, @plain)
      read = "/containers/app_#{@plain}/json"

      # The pass that creates, the pass that decides the put, and then the
      # put's own read of the container, each let go as it arrives.
      Model.hold(engine, :get, read)
      {:ok, _app} = Store.update_spec(:app, @plain, %{run: true}, sys.i)

      for _pass <- 1..2 do
        assert_receive {:fake_engine, :held, %{path: ^read}}, sys.wait
        Model.hold(engine, :get, read)
        Model.release(engine)
      end

      assert_receive {:fake_engine, :held, %{path: ^read}}, sys.wait
      %{id: first} = container(engine, @plain)
      Model.delete_container(engine, "app_" <> @plain)

      second =
        Model.put_container(engine, "app_" <> @plain,
          state: "created",
          image: image,
          env: ["SUPERVISOR_TOKEN=the-token-of-the-second"]
        )

      Model.release(engine)
      settle(sys)

      # Nothing was put: the table does not know a token of either.
      app = get(sys, @plain)
      assert second != first

      assert %{action: :put_token, class: :transient, detail: {:other, :instance_changed}} =
               app.status.failure

      assert actions(sys, @plain) == [:create]
      assert AuthIndex.digest_of(@plain, sys.i) == :error

      # After the pause the instance that is there has its own token put.
      app = advance(sys, @plain, 1_000)
      assert verdict(app) == @ready
      assert app.status.instance.id == second
      assert actions(sys, @plain) == @start
      assert AuthIndex.lookup("the-token-of-the-second", sys.i) == {:ok, @plain}
    end
  end

  defmodule Raising do
    @moduledoc """
    The engine client, with a start (switch at 1), a remove (2) or a stop
    (3) that raises instead of asking the engine.
    """
    alias Vagus.Runtime.Docker

    for {function, arity, at} <-
          [
            inspect_container: 2,
            inspect_image: 2,
            create_container: 2,
            start_container: 2,
            stop_container: 2,
            remove_container: 2,
            remove_image: 2
          ]
          |> Enum.map(fn {function, arity} ->
            {function, arity,
             %{start_container: 1, remove_container: 2, stop_container: 3}[function]}
          end) do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(function)(unquote_splicing(args)) do
        {last, first} = List.pop_at(unquote(args), -1)
        {switch, opts} = Keyword.pop!(last, :raising)

        if :atomics.get(switch, 1) == unquote(at),
          do: raise("#{unquote(function)} fell over")

        apply(Docker, unquote(function), first ++ [opts])
      end
    end
  end

  describe "an action that raises, or whose call exits" do
    setup do
      world = AppWorld.new()
      switch = :atomics.new(1, [])

      backends = %{
        Vagus.App.Backend.Container => [
          client: Raising,
          engine: [socket: world.socket, raising: switch]
        ],
        Vagus.App.Backend.Native => []
      }

      sys = start_system(AppWorld.system(world, context: %{backends: backends}))
      %{world: world, sys: sys, engine: AppWorld.engine(world, sys), switch: switch}
    end

    test "a start that raises: Failed, with the failure in status, and not asked for again",
         %{world: world, sys: sys, engine: engine, switch: switch} do
      :atomics.put(switch, 1, 1)
      app = install(world, sys, @plain, %{run: true})
      assert verdict(app) == {false, false, true, :crashed, :failed}
      assert Controller.wire_state(app) == :error

      assert %{action: :start, class: :permanent, detail: {:crashed, RuntimeError}, count: 1} =
               app.status.failure

      # An action that failed, not a pass that crashed: nothing is being
      # tried again behind the verdict.
      assert info(sys, Controller).failures == %{}
      assert info(sys, Controller).timers == []
      assert actions(sys, @plain) == [:create, :put_token]
      assert wake(sys, @plain) == app
      assert %{state: "created"} = container(engine, @plain)

      :atomics.put(switch, 1, 0)
      assert verdict(write(sys, @plain, [{:inc, [:start_counter]}])) == @ready
    end

    test "a remove that raises: Failed all the same, the container left where it is",
         %{world: world, sys: sys, engine: engine, switch: switch} do
      install(world, sys, @plain, %{run: true})
      :atomics.put(switch, 1, 2)

      app = write(sys, @plain, %{run: false})
      assert verdict(app) == {false, false, true, :crashed, :failed}

      assert %{action: :remove, class: :permanent, detail: {:crashed, RuntimeError}} =
               app.status.failure

      assert info(sys, Controller).failures == %{}
      assert actions(sys, @plain) == @start ++ [:stop]
      assert wake(sys, @plain) == app
      assert %{state: "exited"} = container(engine, @plain)

      # A write to the spec is a new generation, and another attempt.
      :atomics.put(switch, 1, 0)
      app = write(sys, @plain, [{:inc, [:start_counter]}])
      assert verdict(app) == @stopped
      assert container(engine, @plain) == nil
    end

    test "a stop that raises leaves the app Failed and running, and its token is still kept",
         %{world: world, sys: sys, engine: engine, switch: switch} do
      install(world, sys, @plain, %{run: true})
      held = token(engine, @plain)
      :atomics.put(switch, 1, 3)

      app = write(sys, @plain, %{run: false})
      assert verdict(app) == {false, false, true, :crashed, :failed}
      assert %{action: :stop, class: :permanent} = app.status.failure
      assert %{state: "running"} = container(engine, @plain)
      assert actions(sys, @plain) == @start

      # The token table is replaced: the container still runs and still
      # calls the API, so its token goes back, and nothing else is done.
      index = Process.whereis(AuthIndex.name(sys.instance))
      TestInstance.kill_observed(index, Process.whereis(Module.concat(sys.instance, Supervisor)))
      settle(sys)
      await!(sys, :app, @plain, :failed)
      settle(sys)
      assert AuthIndex.lookup(held, sys.i) == {:ok, @plain}
      assert verdict(get(sys, @plain)) == {false, false, true, :crashed, :failed}
      assert actions(sys, @plain) == @start ++ [:put_token]
      assert %{state: "running"} = container(engine, @plain)
    end

    test "a pull asked for while the pull worker is being replaced is asked for again",
         %{world: world, sys: sys} do
      supervisor = Module.concat(sys.instance, Supervisor)
      :ok = Supervisor.terminate_child(supervisor, Pulls.name(sys.instance))
      {:ok, _app} = Store.create(:app, @plain, AppWorld.spec(world, @plain, %{run: true}), sys.i)
      app = await!(sys, :app, @plain, &(&1.status[:failure] != nil))
      settle(sys)

      # The call exited, nobody answering to the worker's name: a failure
      # for now, in status, and no crashed pass.
      assert %{action: :request_pull, class: :transient, cause: :call_exited} = app.status.failure
      assert app.status.failure.detail == {:exit, :noproc}
      assert verdict(get(sys, @plain)) == {false, true, false, :call_exited, :starting}
      assert info(sys, Controller).failures == %{}

      {:ok, _worker} = Supervisor.restart_child(supervisor, Pulls.name(sys.instance))
      advance(sys, @plain, 1_000)
      await!(sys, :app, @plain, :ready)
      settle(sys)
      assert actions(sys, @plain) == [:request_pull] ++ @start
    end
  end

  describe "an earlier wave written to" do
    test "is waited for again by an app asked to start meanwhile, until it is Ready as written" do
      world = AppWorld.new()
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      install(world, sys, @early, %{run: true})
      %{id: first} = container(engine, @early)

      # The earlier app's pass for its new spec stands in its first read:
      # status still says Ready, of the spec before.
      Model.hold(engine, :get, "/containers/app_#{@early}/json")
      {:ok, _app} = Store.update_spec(:app, @early, [{:inc, [:restart_counter]}], sys.i)
      assert_receive {:fake_engine, :held, %{method: :get}}, sys.wait
      assert %{status: true} = get(sys, @early).status.conditions.ready

      spec = AppWorld.spec(world, @plain, %{run: true})
      Model.put_image(engine, AppWorld.image(world, spec))
      {:ok, _app} = Store.create(:app, @plain, spec, sys.i)
      app = await!(sys, :app, @plain, &is_map_key(&1.status, :state))
      assert verdict(app) == {false, true, false, :waiting_for_wave, :waiting}
      assert app.status.waiting_on == [@early]
      assert actions(sys, @plain) == []

      Model.release(engine)
      await!(sys, :app, @early, :ready)
      await!(sys, :app, @plain, :ready)
      settle(sys)
      assert %{id: second} = container(engine, @early)
      assert second != first
      assert actions(sys, @plain) == @start
    end
  end

  describe "with nobody to say what happened in the engine" do
    @tag scenario: :resync
    test "a container that ended is found when the runtime looks at everything again" do
      world = AppWorld.new()
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      install(world, sys, @plain, %{run: true})

      # No observer and no event: nothing brings the app a pass.
      Model.crash(engine, "app_" <> @plain, 9)
      settle(sys)
      assert verdict(get(sys, @plain)) == @ready

      resync(sys, Controller)
      settle(sys)
      app = get(sys, @plain)
      assert verdict(app) == {false, false, true, :crashed, :failed}
      assert app.status.failure.detail == %{exit_code: 9}
    end
  end

  describe "an uninstall" do
    test "of an app whose owner is gone is the collector's to ask for, and ends like any other" do
      world = AppWorld.new()

      run(world, [kinds: %{backup: []}], fn sys, engine ->
        {:ok, owner} = Store.create(:backup, "restored", %{}, sys.i)
        spec = AppWorld.spec(world, @plain, %{run: true})
        Model.put_image(engine, AppWorld.image(world, spec))
        owned = [owner_refs: [Vagus.Resource.ref(owner)]]
        {:ok, _app} = Store.create(:app, @plain, spec, owned ++ sys.i)
        await!(sys, :app, @plain, :ready)
        settle(sys)

        {:ok, _owner} = Store.delete(:backup, "restored", sys.i)
        await!(sys, :app, @plain, :gone)
        settle(sys)

        assert actions(sys, @plain) ==
                 @start ++ [:remove_token, :stop, :remove, :remove_image, :remove_data]

        assert container(engine, @plain) == nil
        assert snapshot(sys) == []
      end)
    end

    test "held by another's finalizer: this controller does its part once and lets go" do
      world = AppWorld.new()

      run(world, fn sys, engine ->
        spec = AppWorld.spec(world, @plain, %{run: true})
        Model.put_image(engine, AppWorld.image(world, spec))
        {:ok, _app} = Store.create(:app, @plain, spec, [finalizers: [:dns]] ++ sys.i)
        await!(sys, :app, @plain, :ready)
        settle(sys)
        held = token(engine, @plain)

        {:ok, _app} = Store.delete(:app, @plain, sys.i)
        app = await!(sys, :app, @plain, &(&1.finalizers == [:dns]))
        settle(sys)
        assert app.deleting?
        assert container(engine, @plain) == nil
        assert AuthIndex.lookup(held, sys.i) == :error
        refute File.exists?(Prepare.data_dir(@plain, world.facts))
        done = @start ++ [:remove_token, :stop, :remove, :remove_image, :remove_data]
        assert actions(sys, @plain) == done

        # Looked at again, it is no longer this controller's: nothing is
        # done and nothing is said, whatever has appeared in the meantime.
        before = get(sys, @plain)
        File.mkdir_p!(Prepare.data_dir(@plain, world.facts))
        assert wake(sys, @plain) == before
        assert actions(sys, @plain) == done
        assert File.dir?(Prepare.data_dir(@plain, world.facts))

        {:ok, _resources} = Store.commit([{:remove_finalizer, :app, @plain, :dns}], sys.i)
        await!(sys, :app, @plain, :gone)
        settle(sys)
        assert snapshot(sys) == []
      end)
    end

    test "of an app that has failed takes away the container whose start was refused" do
      world = AppWorld.new()

      run(world, fn sys, engine ->
        Model.fail_start(
          engine,
          "app_" <> @plain,
          "Bind for 0.0.0.0:80 failed: port is already allocated"
        )

        app = install(world, sys, @plain, %{run: true})
        assert {false, false, true, :port_conflict, :failed} = verdict(app)
        held = token(engine, @plain)

        {:ok, _app} = Store.delete(:app, @plain, sys.i)
        await!(sys, :app, @plain, :gone)
        settle(sys)

        # Nothing runs, so nothing is stopped.
        assert actions(sys, @plain) ==
                 @start ++ [:remove_token, :remove, :remove_image, :remove_data]

        assert container(engine, @plain) == nil
        assert AuthIndex.lookup(held, sys.i) == :error
        assert snapshot(sys) == []
      end)
    end

    test "during a pull cancels the pull and leaves nothing" do
      world = AppWorld.new()
      spec = AppWorld.spec(world, @plain, %{run: true})
      image = AppWorld.image(world, spec)

      run(world, fn sys, engine ->
        Model.script_pull(engine, image, {:stall, [Model.downloading("layer", 1, 100)]})
        {:ok, _app} = Store.create(:app, @plain, spec, sys.i)
        await!(sys, :app, @plain, &(&1.status[:state] == :pulling))
        settle(sys)

        {:ok, _app} = Store.delete(:app, @plain, sys.i)
        await!(sys, :app, @plain, :gone)
        settle(sys)

        assert actions(sys, @plain) == [:request_pull, :cancel_pull]
        assert Pulls.info(sys.i) == %{}
        assert Pulls.state(image, sys.i) == :idle
        assert container(engine, @plain) == nil
        assert snapshot(sys) == []
      end)
    end
  end

  describe "a shutdown that did not end in a reboot" do
    test "leaves status as it was; a container it stopped is then taken for one that ended by itself" do
      world = AppWorld.new()
      sys = start_system(AppWorld.system(world))
      engine = AppWorld.engine(world, sys)
      install(world, sys, @watched, watchdog())
      before = get(sys, @watched)

      shutdown(sys, true)
      Model.crash(engine, "app_" <> @watched, 143)
      assert wake(sys, @watched).status == before.status

      # Not what is wanted. Nothing tells the pass after the shutdown that
      # the exit was the host's doing, and status still has the instance as
      # running: one attempt is counted, and the app comes back after its
      # pause. After a reboot there is no status, and nothing is counted.
      shutdown(sys, false)
      app = wake(sys, @watched)
      assert verdict(app) == {false, true, false, :backing_off, :restarting}
      assert attempts(app) == 1
      assert actions(sys, @watched) == @start ++ [:remove]
      assert verdict(advance(sys, @watched, 10_000)) == @ready
    end
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

    # Away while the test says so: it has yet to look, and says nothing.
    @impl true
    def observe(%{name: name}, context) do
      if Harness.fact(context, :gate_away),
        do: {:unavailable, :away},
        else: Harness.fact(context, {:registered, name})
    end

    @impl true
    def reconcile(_app, {:unavailable, :away}), do: {:no_verdict, []}
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
      AppWorld.heard(sys, Gate)
      settle(sys)
      get(sys, @plain)
    end

    Faults.each_boundary(
      system: system,
      normalize: &AppWorld.normalize/1,
      journal: &AppWorld.journal/1,
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

        # A write that keeps the instance: the gate's word is of the spec
        # before it until the gate's owner has looked at the new one.
        put_fact(sys, :gate_away, true)
        app = write(sys, @plain, %{settings: %{protected: false}})
        assert %{id: ^second, state: "running"} = container(engine, @plain)
        assert %{status: true, message: ^second} = stale = app.status.conditions.dns_ready
        assert stale.observed_generation < app.generation
        assert verdict(app) == {false, true, false, :waiting_for_gate, :starting}
        assert Controller.wire_state(app) == :startup

        put_fact(sys, :gate_away, false)
        app = register.(sys, second)
        assert app.status.conditions.dns_ready.observed_generation == app.generation
        assert verdict(app) == @ready
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

      # Its ten minutes over, it is Failed and still asked, at longer
      # intervals: a slow Core comes up all the same, with nothing written.
      app = advance(sys, "homeassistant", 600_000)
      assert verdict(app) == {false, false, true, :readiness_timeout, :failed}
      assert Controller.wire_state(app) == :error
      assert app.status.failure == nil
      %{generation: generation} = app

      :atomics.put(world.probe, 1, 0)
      app = advance(sys, "homeassistant", 30_000)
      assert verdict(app) == @ready
      assert app.generation == generation
      assert actions(sys, "homeassistant") == [:put_token]

      # A stop keeps the container, with the grace its image asks for.
      app = write(sys, "homeassistant", %{run: false})
      assert verdict(app) == @stopped
      assert %{state: "exited"} = Model.container(engine, "homeassistant")
      assert actions(sys, "homeassistant") == [:put_token, :stop, :remove_token]

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

      # Failed, and running all the same: a token table that is replaced
      # gets its token back, and nothing else is done to it.
      index = Process.whereis(AuthIndex.name(sys.instance))
      TestInstance.kill_observed(index, Process.whereis(Module.concat(sys.instance, Supervisor)))
      settle(sys)
      await!(sys, :app, "homeassistant", :failed)
      settle(sys)
      assert AuthIndex.lookup("the-supervisor-token", sys.i) == {:ok, "homeassistant"}
      assert verdict(get(sys, "homeassistant")) == {false, false, true, :crash_loop, :failed}
      assert tail(actions(sys, "homeassistant"), 3) == [:put_token, :start, :put_token]
    end)
  end
end
