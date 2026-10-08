defmodule Vagus.App.Controller.ObserveTest do
  use ExUnit.Case, async: true

  import Vagus.Resource.Harness

  alias Vagus.App.{AuthIndex, Controller, Prepare, Pulls}
  alias Vagus.App.Controller.Observe
  alias Vagus.Resource.{Stamp, Store}
  alias Vagus.Test.AppRows, as: Rows
  alias Vagus.Test.AppWorld
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log

  @plain "only_host_uts"
  @watched "45df7312_zigbee2mqtt"
  @core "homeassistant"
  @token "a-token-the-container-was-given"

  # A system whose runtime rests, as during a shutdown: everything the
  # controller's observe reads is there, and nothing but the test observes.
  setup do
    world = AppWorld.new()
    sys = start_system(AppWorld.system(world))
    shutdown(sys, true)
    %{world: world, sys: sys, engine: AppWorld.engine(world, sys)}
  end

  defp app(ctx, slug, fields \\ %{}, status \\ %{}) do
    spec =
      if slug == @core,
        do: Map.merge(%{lifecycle: :core, version: "2026.8.0", run: true}, fields),
        else: AppWorld.spec(ctx.world, slug, Map.merge(%{run: true}, fields))

    {:ok, app} = Store.create(:app, slug, spec, ctx.sys.i)
    made(%{app | status: status})
  end

  # Recorded as made for the spec as it is: a container nothing is
  # recorded of is removed, whatever state it is in.
  defp made(app), do: %{app | status: Map.put(app.status, :made_for, Rows.target(app.spec))}

  defp observe(ctx, app, over \\ %{}) do
    context =
      ctx.world
      |> AppWorld.context()
      |> Map.merge(%{
        instance: ctx.sys.instance,
        now: %Stamp{incarnation: 1, at: 0},
        failed_action: nil
      })
      |> Map.merge(over)

    Observe.observe(app, context, Controller)
  end

  defp container(ctx, name, attrs \\ []) do
    env = ["SUPERVISOR_TOKEN=" <> @token | Keyword.get(attrs, :env, [])]
    Model.put_container(ctx.engine, name, Keyword.put(attrs, :env, env))
  end

  defp image(ctx, app) do
    {:ok, image} = Vagus.App.Container.Config.image(app.spec, ctx.world.facts)
    image
  end

  defp have_image(ctx, app), do: Model.put_image(ctx.engine, image(ctx, app))

  # The observation is one the table's rows could have been built from, by
  # `Rows.problems/2`, which every row is held to as well, and the decision
  # takes it: `clause` is the one it reaches.
  defp assert_decided(app, observation, clause) do
    assert Rows.problems(app, observation) == []
    returned = Controller.reconcile(app, observation)
    assert_verdict_contract(Controller, [{app, observation}])
    assert Rows.clause(app, observation, returned) == clause
    observation
  end

  describe "a container app" do
    test "with no container: the image there, and missing", ctx do
      app = app(ctx, @plain)
      assert %{instance: :absent, image_present?: false} = o = observe(ctx, app)
      assert o.image == image(ctx, app)
      assert_decided(app, o, :request_pull)

      have_image(ctx, app)
      assert %{image_present?: true, token: :absent, leftover: :absent} = o = observe(ctx, app)
      assert_decided(app, o, :create)
    end

    test "created: its token not in the table, another's, and its own", ctx do
      app = app(ctx, @plain)
      id = container(ctx, "app_" <> @plain, state: "created")

      assert %{instance: %{id: ^id, state: :created, started_at: nil, exit_code: nil}} =
               o = observe(ctx, app)

      assert o.token == :absent and o.instance.token?
      refute is_map_key(o.instance, :env)
      assert_decided(app, o, :put_token)

      :ok = AuthIndex.put(@plain, "another", ctx.sys.i)
      assert %{token: :other} = o = observe(ctx, app)
      assert_decided(app, o, :put_token)

      :ok = AuthIndex.put(@plain, @token, ctx.sys.i)
      assert %{token: :current} = o = observe(ctx, app)
      assert_decided(app, o, :start)
    end

    test "a container made without a token", ctx do
      app = app(ctx, @plain)
      Model.put_container(ctx.engine, "app_" <> @plain, state: "created", env: ["TZ=UTC"])
      assert %{instance: %{token?: false}, token: :absent} = o = observe(ctx, app)
      assert_decided(app, o, :no_token)
    end

    for {health, clause} <- [
          {nil, :ready},
          {{"healthy", 0}, :ready},
          {{"starting", 0}, :await_readiness},
          {{"unhealthy", 3}, :await_readiness}
        ] do
      test "running, its health #{inspect(health)}", ctx do
        app = app(ctx, @plain)
        container(ctx, "app_" <> @plain, health: unquote(Macro.escape(health)))
        :ok = AuthIndex.put(@plain, @token, ctx.sys.i)

        assert %{instance: %{state: :running, address: "172.30.33." <> _}, token: :current} =
                 o = observe(ctx, app)

        assert is_binary(o.instance.started_at)
        assert_decided(app, o, unquote(clause))
      end
    end

    test "exited, with 0 and with another code", ctx do
      app = app(ctx, @plain)
      id = container(ctx, "app_" <> @plain, state: "exited", exit_code: 0)
      known = made(%{app | status: Rows.running(instance: Rows.seen(id: id))})
      assert %{instance: %{state: :exited, exit_code: 0}} = o = observe(ctx, known)
      assert_decided(known, o, :crashed)

      Model.crash(ctx.engine, "app_" <> @plain, 137)

      assert %{instance: %{state: :exited, exit_code: 137, address: nil}} =
               o = observe(ctx, known)

      assert_decided(known, o, :crashed)
      # Nothing recorded of it: it is removed, and nothing is counted.
      assert_decided(%{app | status: %{}}, o, :remove)
    end

    for {state, clause} <- [
          {"paused", :await_readiness},
          {"restarting", :await_readiness},
          {"removing", :await_removal},
          {"dead", :remove}
        ] do
      test "a container that is #{state}", ctx do
        app = app(ctx, @plain)
        container(ctx, "app_" <> @plain, state: unquote(state))
        :ok = AuthIndex.put(@plain, @token, ctx.sys.i)
        expected = String.to_existing_atom(unquote(state))
        assert %{instance: %{state: ^expected}} = o = observe(ctx, app)
        assert_decided(app, o, unquote(clause))
      end
    end

    test "the engine away, failing a read, and not answering in time", ctx do
      app = app(ctx, @plain)
      container(ctx, "app_" <> @plain)

      Model.fail(
        ctx.engine,
        :get,
        "/containers/app_#{@plain}/json",
        {500, "the engine fell over"}
      )

      assert observe(ctx, app) == {:unavailable, :engine_error}
      Model.fail(ctx.engine, :get, "/containers/app_#{@plain}/json", nil)

      # The second read of a pass, and the third.
      Model.put_container(ctx.engine, "addon_" <> @plain, state: "exited")
      Model.crash(ctx.engine, "app_" <> @plain)
      Model.fail(ctx.engine, :get, "/containers/addon_", {500, "the engine fell over"})
      assert observe(ctx, app) == {:unavailable, :engine_error}
      Model.fail(ctx.engine, :get, "/containers/addon_", nil)
      Model.fail(ctx.engine, :get, "/images/", {500, "the engine fell over"})
      deleting = %{app | deleting?: true}
      assert observe(ctx, deleting) == {:unavailable, :engine_error}
      Model.fail(ctx.engine, :get, "/images/", nil)

      Model.hold(ctx.engine, :get, "/containers/app_#{@plain}/json")
      assert observe(ctx, app, %{observe_timeout: 50}) == {:unavailable, :engine_error}
      Model.release(ctx.engine)

      AppWorld.engine_down(ctx.sys)
      assert observe(ctx, app) == {:unavailable, :engine_unavailable}

      for unavailable <- [{:unavailable, :engine_error}, {:unavailable, :engine_unavailable}] do
        assert Rows.problems(app, unavailable) == []
        assert {_verdict, []} = Controller.reconcile(app, unavailable)
      end
    end

    for {state, seen} <- [
          {"running", :running},
          {"paused", :running},
          {"restarting", :running},
          {"exited", :stopped},
          {"created", :stopped}
        ] do
      test "a container the other slot left, #{state}", ctx do
        app = app(ctx, @plain)
        have_image(ctx, app)
        container(ctx, "addon_" <> @plain, state: unquote(state))
        assert %{leftover: unquote(seen), instance: :absent} = o = observe(ctx, app)

        assert_decided(
          app,
          o,
          if(unquote(seen) == :running, do: :stop_leftover, else: :remove_leftover)
        )
      end
    end

    test "a leftover is not looked for beside an own container that runs", ctx do
      app = app(ctx, @plain)
      container(ctx, "addon_" <> @plain)
      container(ctx, "app_" <> @plain)
      assert %{leftover: :absent} = o = observe(ctx, app)
      assert Rows.problems(app, o) == []
    end

    test "a pull: for this app, for another, failed, and of an image moved on from", ctx do
      app = app(ctx, @plain)
      image = image(ctx, app)
      me = {Controller, @plain}
      stall = {:stall, [Model.downloading("layer", 1, 100)]}

      Model.script_pull(ctx.engine, image, stall)
      :ok = Pulls.request(image, {Controller, "another"}, ctx.sys.i)
      assert %{pull: {:pulling, false}} = o = observe(ctx, app)
      assert_decided(app, o, :request_pull)

      :ok = Pulls.request(image, me, ctx.sys.i)
      asked = %{app | status: %{pull: Rows.pulled(image: image, generation: app.generation)}}
      # The pull worker tells a waiter's runtime that its pull has ended.
      Process.register(self(), Vagus.Resource.Runtime.name(ctx.sys.instance, __MODULE__))
      assert %{pull: {:pulling, true}, stale_pull: nil} = o = observe(ctx, asked)
      assert_decided(asked, o, :pulling)

      for waiter <- [me, {Controller, "another"}], do: Pulls.cancel(image, waiter, ctx.sys.i)
      assert %{pull: :idle} = observe(ctx, asked)

      Model.script_pull(ctx.engine, image, {:error, "unexpected EOF"})
      :ok = Pulls.request(image, {__MODULE__, "another"}, ctx.sys.i)
      assert_receive {:"$gen_cast", {:enqueue, "another"}}, 5_000
      assert %{pull: {:failed, {:stream, "unexpected EOF"}, %Stamp{}}} = o = observe(ctx, asked)
      assert_decided(asked, o, :pull_pause)

      # The image this app asked for before the one it wants now.
      Model.script_pull(ctx.engine, "an/earlier:1", stall)
      :ok = Pulls.request("an/earlier:1", me, ctx.sys.i)
      moved = %{app | status: %{pull: Rows.pulled(image: "an/earlier:1", generation: 1)}}
      assert %{stale_pull: "an/earlier:1"} = o = observe(ctx, moved)
      assert_decided(moved, o, :cancel_stale_pull)

      # Withdrawn from it, there is nothing to cancel.
      Pulls.cancel("an/earlier:1", me, ctx.sys.i)
      assert %{stale_pull: nil} = observe(ctx, moved)
    end

    test "a pull that ends between the read of its state and the read of who waits for it",
         ctx do
      app = app(ctx, @plain)
      image = image(ctx, app)
      Model.script_pull(ctx.engine, image, {:stall, [Model.downloading("layer", 1, 100)]})
      :ok = Pulls.request(image, {Controller, "another"}, ctx.sys.i)
      worker = Process.whereis(Pulls.name(ctx.sys.instance))
      failed = {:failed, {:stream, "unexpected EOF"}, %Stamp{incarnation: 1, at: 0}}

      # The worker stands still, so the observation reads the table and then
      # waits for the worker's answer. Its question is seen arriving, and
      # only then does the pull end, in the worker, before it answers.
      :sys.suspend(worker)
      :erlang.trace(worker, true, [:receive])
      observing = Task.async(fn -> observe(ctx, app) end)

      try do
        assert_receive {:trace, ^worker, :receive, {:"$gen_call", _from, :info}}, 5_000
      after
        :erlang.trace(worker, false, [:receive])
      end

      :sys.replace_state(worker, fn {module, state, report} ->
        :ets.insert(state.table, {image, failed})
        {module, %{state | pulls: %{}, refs: %{}}, report}
      end)

      :sys.resume(worker)

      # Not a pull this app has yet to join, which it would ask for again.
      assert %{pull: ^failed} = o = Task.await(observing)
      assert Rows.problems(app, o) == []
    end

    test "being deleted: its image and its data, while there are any", ctx do
      app = app(ctx, @plain)
      deleting = %{app | deleting?: true}
      assert %{data?: false, image_present?: false} = o = observe(ctx, deleting)
      assert_decided(deleting, o, :deleted)

      have_image(ctx, app)
      File.mkdir_p!(Prepare.data_dir(@plain, ctx.world.facts))
      assert %{data?: true, image_present?: true} = o = observe(ctx, deleting)
      assert_decided(deleting, o, :remove_image)
      # Only a delete asks after the data.
      assert %{data?: false} = observe(ctx, app)
    end

    test "an earlier wave still starting is waited for, by an app with no instance", ctx do
      early = app(ctx, "core_mosquitto")
      app = app(ctx, @plain)
      have_image(ctx, app)
      assert %{waiting_on: ["core_mosquitto"]} = o = observe(ctx, app)
      assert_decided(app, o, :await_wave)

      container(ctx, "app_" <> @plain, state: "created")
      assert %{waiting_on: []} = observe(ctx, app)
      assert %{waiting_on: []} = observe(ctx, early)
    end

    test "the API not accepting, and the gates the controller was given", ctx do
      app = app(ctx, @plain)
      have_image(ctx, app)
      :atomics.put(ctx.world.api, 1, 1)
      assert %{api?: false, gates: [:dns_ready]} = o = observe(ctx, app, %{gates: [:dns_ready]})
      assert_decided(app, o, :await_api)
    end

    test "the action that failed in the pass before, with the generation it was decided for",
         ctx do
      app = app(ctx, @plain)
      have_image(ctx, app)
      at = %Stamp{incarnation: 1, at: 0}

      failed = %{
        name: :create,
        args: %{generation: 1},
        reason: {:status, 500, "no space left on device"},
        at: at
      }

      assert %{failed_action: %{name: :create, generation: 1, at: ^at} = seen} =
               o = observe(ctx, app, %{failed_action: failed})

      refute is_map_key(seen, :args)
      assert_decided(app, o, :retry_pause)
    end

    defmodule Answers do
      @behaviour Vagus.App.Readiness
      @impl true
      def probe(%{proto: "http", port: 8099}, timeout) when is_integer(timeout), do: :ok
      def probe(_target, _timeout), do: :error
    end

    test "a watched app that was ready is asked at its watchdog URL when that is due", ctx do
      app = app(ctx, @watched, %{settings: %{watchdog: true}})
      id = container(ctx, "app_" <> @watched)
      :ok = AuthIndex.put(@watched, @token, ctx.sys.i)
      %{started_at: started} = Model.container(ctx.engine, "app_" <> @watched)
      ready = Rows.seen(id: id, ready?: true, started_at: started)

      watched = fn probe -> made(%{app | status: Rows.running(instance: ready, probe: probe)}) end
      due = %{misses: 0, at: %Stamp{incarnation: 1, at: -120_000}}

      assert %{probes?: true, probe: :none} = o = observe(ctx, watched.(%{misses: 0, at: nil}))
      assert_decided(watched.(%{misses: 0, at: nil}), o, :ready)

      assert %{probes?: true, probe: :healthy} = o = observe(ctx, watched.(due))
      assert_decided(watched.(due), o, :ready)

      :atomics.put(ctx.world.probe, 1, 1)
      assert %{probe: :unhealthy} = observe(ctx, watched.(due))

      # The prober as a module, which is how the application gives it.
      assert %{probe: :healthy} = observe(ctx, watched.(due), %{prober: Answers})

      # An instance not recorded as ready, or of another run, is not asked.
      other = %{
        app
        | status: Rows.running(instance: %{ready | started_at: "another"}, probe: due)
      }

      assert %{probes?: false, probe: :none} = observe(ctx, other)
    end
  end

  describe "Core" do
    test "has no image, and with no container nothing to make one from", ctx do
      core = app(ctx, @core)

      assert %{instance: :absent, image: nil, image_present?: true, leftover: :absent} =
               o = observe(ctx, core)

      assert_decided(core, o, :no_builder)
    end

    test "its container: the Supervisor's token, the answer, and the grace its image asks for",
         ctx do
      core = app(ctx, @core)

      Model.put_container(ctx.engine, @core,
        restart_policy: "unless-stopped",
        env: ["SUPERVISOR_TOKEN=the-supervisor-token", "S6_SERVICES_GRACETIME=10000"]
      )

      assert %{instance: %{grace: 30, token?: true}, token: :absent, ready: :ready, image: nil} =
               o = observe(ctx, core)

      assert_decided(core, o, :restore_token)

      :ok = AuthIndex.put(@core, "the-supervisor-token", ctx.sys.i)
      :atomics.put(ctx.world.probe, 1, 1)
      assert %{token: :current, ready: :not_ready} = o = observe(ctx, core)
      assert_decided(core, o, :await_readiness)

      # A container that is not Core's own to authenticate: no Supervisor
      # token to give it yet.
      assert %{instance: %{token?: false}} =
               o = observe(ctx, core, %{supervisor_token: fn -> nil end})

      assert_decided(core, o, :await_token)
    end

    for {given, grace} <- [
          {["S6_SERVICES_GRACETIME=240000"], 260},
          {["S6_SERVICES_GRACETIME=0"], 20},
          {[], 260},
          {["S6_SERVICES_GRACETIME=-5"], 260},
          {["S6_SERVICES_GRACETIME=soon"], 260},
          {["S6_SERVICES_GRACETIME=1500ms"], 260}
        ] do
      test "the grace of a container whose image says #{inspect(given)}", ctx do
        core = app(ctx, @core, %{run: false})
        Model.put_container(ctx.engine, @core, env: unquote(given))
        assert %{instance: %{grace: unquote(grace)}} = o = observe(ctx, core)

        assert {_verdict, [{:action, :stop, %{grace: unquote(grace)}}]} =
                 Controller.reconcile(core, o)

        assert Rows.problems(core, o) == []
      end
    end
  end

  test "the helpers the table is built with have the keys of a real observation", ctx do
    app = app(ctx, @plain)
    container(ctx, "app_" <> @plain)
    o = observe(ctx, app)
    assert Enum.sort(Map.keys(o)) == Enum.sort(Map.keys(Rows.obs()))
    assert Enum.sort(Map.keys(o.instance)) == Enum.sort(Map.keys(Rows.inst()))
    # And the check that says so can fail.
    assert Rows.problems(app, Map.put(o, :env, %{})) == [:keys]
    assert Rows.problems(app, put_in(o.instance[:env], %{})) == [:instance]
    assert Rows.problems(app, %{o | leftover: :running}) != []
  end
end
