defmodule Vagus.App.Controller.ReconcileTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Controller
  alias Vagus.App.Controller.View
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.{Harness, Stamp, Verdict}
  alias Vagus.Test.AppManifests
  alias Vagus.Test.AppRows, as: Rows

  @moduletag :capture_log

  # Every action says which generation decided it; one row checks that.
  defp ungenerated(effects) do
    Enum.map(effects, fn
      {:action, name, %{generation: 3} = args} -> {:action, name, Map.delete(args, :generation)}
      effect -> effect
    end)
  end

  defp conditions(:ready, reason), do: outcome({true, false, false}, reason)
  defp conditions(:progressing, reason), do: outcome({false, true, false}, reason)
  defp conditions(:failed, reason), do: outcome({false, false, true}, reason)
  defp conditions(:idle, reason), do: outcome({false, false, false}, reason)

  defp outcome({ready, progressing, failed}, reason),
    do: %{ready: {ready, reason}, progressing: {progressing, reason}, failed: {failed, reason}}

  # The resource as the runtime would leave it after writing the verdict.
  defp written(resource, %Verdict{} = verdict) do
    status = Map.merge(resource.status, verdict.status)

    Enum.reduce(
      Verdict.conditions(verdict, resource.generation),
      %{resource | status: status},
      &Resource.put_condition(&2, &1)
    )
  end

  for {name, _resource, _observation, _expected, _effects, _status} <-
        Rows.all() ++ Rows.unreachable() do
    test name do
      {_name, resource, observation, expected, effects, status} =
        Enum.find(Rows.all() ++ Rows.unreachable(), &(elem(&1, 0) == unquote(name)))

      {verdict, returned} = Controller.reconcile(resource, observation)

      case expected do
        :no_verdict ->
          assert verdict == :no_verdict

        {kind, reason, state, wire} ->
          assert verdict.conditions == conditions(kind, reason)
          assert written(resource, verdict).status[:state] == state
          assert Controller.wire_state(written(resource, verdict)) == wire

          for {key, value} <- status do
            assert Map.fetch!(verdict.status, key) == value, "status.#{key}"
          end
      end

      assert ungenerated(returned) == effects
    end
  end

  test "every clause of the decision is reached by a row, and the clauses are as many as its own" do
    reached =
      for {_name, resource, observation, _expected, _effects, _status} <- Rows.all(),
          into: MapSet.new(),
          do: Rows.clause(resource, observation, Controller.reconcile(resource, observation))

    # Making Core anew is decided and not reachable: see `Rows.unreachable/0`.
    assert Rows.clauses() -- MapSet.to_list(reached) == [:crash_loop]

    assert :crash_loop in for(
             {_name, resource, observation, _expected, _effects, _status} <- Rows.unreachable(),
             do: Rows.clause(resource, observation, Controller.reconcile(resource, observation))
           )

    # The names above are written beside the decision by hand: a clause
    # added to it or taken from it without one changes this count.
    source = File.read!("lib/vagus/app/controller/reconcile.ex")
    [_before, decision] = String.split(source, "    cond do\n", parts: 2)
    [decision, _after] = String.split(decision, "\n    end\n  end\n", parts: 2)
    assert length(Regex.scan(~r/^      \S.* ->$/m, decision)) == length(Rows.clauses())
  end

  test "every row's observation is one the controller's observe could have made" do
    wrong =
      for {name, resource, observation, _expected, _effects, _status} <- Rows.all(),
          problems = Rows.problems(resource, observation),
          problems != [],
          do: {name, problems}

    assert wrong == []

    for {name, resource, observation, _expected, _effects, _status} <- Rows.unreachable() do
      assert Rows.problems(resource, observation) == [:image_only_of_a_manifest_with_one], name
    end
  end

  test "every row's status and action are what its clause is there to write and ask for" do
    wrong =
      for {name, resource, observation, _expected, _effects, _status} <-
            Rows.all() ++ Rows.unreachable(),
          problems =
            Rows.status_problems(
              resource,
              observation,
              Controller.reconcile(resource, observation)
            ),
          problems != [],
          do: {name, problems}

    assert wrong == []
  end

  test "every action carries the generation that decided it" do
    for {_name, resource, observation, _expected, _effects, _status} <- Rows.all(),
        {:action, _name, args} <- elem(Controller.reconcile(resource, observation), 1) do
      assert args.generation == resource.generation
    end
  end

  test "every row keeps the contract every controller is held to" do
    rows =
      for {_name, resource, observation, expected, _effects, _status} <- Rows.all() do
        if expected == :no_verdict,
          do: {resource, observation, :no_verdict},
          else: {resource, observation}
      end

    assert Harness.assert_verdict_contract(Controller, rows) == :ok
  end

  describe "action_class/1" do
    @engine [:create, :start, :stop, :remove, :stop_leftover, :remove_leftover] ++
              [:remove_image, :put_token]
    @none [:request_pull, :cancel_pull, :remove_token, :remove_data, :start_process] ++
            [:stop_process]

    test "what asks the engine for something runs in its lane, and nothing else in any" do
      for action <- @engine, do: assert(Controller.action_class(action) == :engine)
      for action <- @none, do: assert(Controller.action_class(action) == nil)
    end

    test "every action the table asks for is one of those" do
      asked =
        for {_name, resource, observation, _expected, _effects, _status} <- Rows.all(),
            {:action, action, _args} <- elem(Controller.reconcile(resource, observation), 1),
            uniq: true,
            do: action

      assert Enum.sort(asked) == Enum.sort(@engine ++ @none)
    end
  end

  describe "wire_state/1" do
    # The conditions as said of generation 1, of a resource at `generation`.
    defp with_status(status, conditions, generation \\ 1) do
      app = Harness.resource(:app, "a", %{}, status: status, generation: generation)

      Enum.reduce(conditions, app, fn {type, value}, app ->
        Resource.put_condition(app, Resource.condition(type, value, :reason, 1))
      end)
    end

    # After a write to the spec, until the next pass has committed.
    for {name, status, conditions, wire} <- [
          {"Ready, said of the spec before a write: the instance runs, and that is all",
           %{state: :ready, instance: %{running?: true}},
           [ready: true, progressing: false, failed: false], :startup},
          {"Failed, said of the spec before a write, the instance running",
           %{state: :failed, instance: %{running?: true}},
           [ready: false, progressing: false, failed: true], :startup},
          {"Failed, said of the spec before a write, with no instance",
           %{state: :failed, instance: nil}, [ready: false, progressing: false, failed: true],
           :stopped},
          {"Failed, said of the spec before a write, its container created and not started",
           %{state: :failed, instance: %{running?: false}},
           [ready: false, progressing: false, failed: true], :stopped},
          {"stopped before a write is stopped after it", %{state: :stopped, instance: nil},
           [ready: false, progressing: false, failed: false], :stopped}
        ] do
      test name do
        stale = with_status(unquote(Macro.escape(status)), unquote(conditions), 2)
        assert Controller.wire_state(stale) == unquote(wire)
      end
    end

    for {name, status, conditions, wire} <- [
          {"never observed", %{}, [], :unknown},
          {"only the conditions of a pass that could not observe", %{},
           [progressing: true, ready: false, failed: false], :unknown},
          {"Ready", %{state: :ready, instance: %{running?: true}},
           [ready: true, progressing: false, failed: false], :started},
          {"running, not Ready", %{state: :starting, instance: %{running?: true}},
           [ready: false, progressing: true, failed: false], :startup},
          {"being stopped, still running", %{state: :stopping, instance: %{running?: true}},
           [ready: false, progressing: true, failed: false], :startup},
          {"Failed, running or not", %{state: :failed, instance: %{running?: true}},
           [ready: false, progressing: false, failed: true], :error},
          {"Failed with no container", %{state: :failed, instance: nil},
           [ready: false, progressing: false, failed: true], :error},
          {"stopped", %{state: :stopped, instance: nil},
           [ready: false, progressing: false, failed: false], :stopped},
          {"pulling", %{state: :pulling, instance: nil},
           [ready: false, progressing: true, failed: false], :stopped},
          {"created, not started", %{state: :starting, instance: %{running?: false}},
           [ready: false, progressing: true, failed: false], :stopped},
          {"succeeded", %{state: :succeeded, instance: %{running?: false}},
           [ready: false, progressing: false, failed: false], :stopped}
        ] do
      test name do
        assert Controller.wire_state(
                 with_status(unquote(Macro.escape(status)), unquote(conditions))
               ) == unquote(wire)
      end
    end
  end

  describe "reconcile/2 is total" do
    @states [:created, :running, :exited, :dead, :restarting, :paused, :removing]

    defp stamp, do: %Stamp{incarnation: AppManifests.pick([1, 2]), at: :rand.uniform(2_000_000)}

    defp some(generator), do: AppManifests.pick([nil, generator]) |> then(&(&1 && &1.()))

    defp instance do
      AppManifests.pick([
        :absent,
        Rows.inst(AppManifests.pick(@states), %{
          id: AppManifests.pick(["c1", "c2"]),
          exit_code: AppManifests.pick([nil, 0, 1, 137]),
          started_at: AppManifests.pick([nil, "started-1", "started-2"]),
          restart_count: AppManifests.pick([0, 1, 7]),
          health: AppManifests.pick([:none, :starting, :healthy, :unhealthy]),
          address: AppManifests.pick([nil, "172.30.33.2"]),
          process: AppManifests.pick([nil, self()]),
          token?: AppManifests.pick([true, false]),
          grace: AppManifests.pick([nil, 30, 260])
        })
      ])
    end

    defp status(spec) do
      recorded = fn ->
        Rows.seen(%{
          id: AppManifests.pick(["c1", "c2"]),
          running?: AppManifests.pick([true, false]),
          since: some(&stamp/0),
          ready?: AppManifests.pick([true, false]),
          restart_count: AppManifests.pick([0, 1]),
          started_at: AppManifests.pick([nil, "started-1"])
        })
      end

      all = %{
        state: AppManifests.pick([:ready, :stopped, :failed, :starting]),
        instance: some(recorded),
        made_for:
          some(fn ->
            Map.merge(Rows.target(spec), %{
              AppManifests.pick([:restart_counter, :start_counter, :fingerprint]) =>
                AppManifests.pick([0, 1, 2])
            })
          end),
        expected_exit: AppManifests.pick([nil, "c1", "c2"]),
        recreate: AppManifests.pick([nil, "c1"]),
        failure:
          some(fn ->
            Rows.failure(%{
              class: AppManifests.pick([:permanent, :transient]),
              action: AppManifests.pick([:start, :create, :stop, :run, :pull]),
              generation: AppManifests.pick([2, 3]),
              at: stamp(),
              count: :rand.uniform(31) - 1
            })
          end),
        succeeded: AppManifests.pick([nil, 2, 3]),
        restarts: %{
          attempts: AppManifests.pick([0, 1, 5, 9]),
          last: stamp()
        },
        engine_restarts: %{
          seen: for(_ <- 1..AppManifests.pick([1, 3]), do: stamp()),
          actions: for(_ <- 1..AppManifests.pick([1, 11]), do: stamp())
        },
        probe: %{misses: AppManifests.pick([0, 1, 2]), at: some(&stamp/0)},
        pull:
          some(fn ->
            Rows.pulled(%{
              generation: AppManifests.pick([2, 3]),
              failures: :rand.uniform(10) - 1,
              seen: some(&stamp/0),
              after: some(&stamp/0)
            })
          end),
        wave_since: some(&stamp/0),
        ready_since: some(&stamp/0),
        cleaned: AppManifests.pick([[], [:image]])
      }

      # Any subset: status is merged, and a key may never have been written.
      Map.filter(all, fn _entry -> :rand.uniform(4) > 1 end)
    end

    defp observation do
      reason =
        AppManifests.pick([
          {:status, 500, "port is already allocated"},
          {:status, 404, nil},
          {:timeout, :recv},
          {:unreachable, :enoent},
          :already_exists,
          {:crashed, :error},
          {:stream, "manifest unknown"}
        ])

      AppManifests.pick([
        {:unavailable, AppManifests.pick([:engine_unavailable, :engine_error])},
        Rows.obs(%{
          now: stamp(),
          instance: instance(),
          leftover: AppManifests.pick([:absent, :absent, :running, :stopped]),
          image: AppManifests.pick([nil, "image:1"]),
          image_present?: AppManifests.pick([true, false]),
          pull:
            AppManifests.pick([
              :idle,
              {:pulling, true},
              {:pulling, false},
              {:failed, reason, stamp()}
            ]),
          token: AppManifests.pick([:none, :current, :other, :absent]),
          waiting_on: AppManifests.pick([[], ["a"]]),
          gates: AppManifests.pick([[], [:dns_ready]]),
          ready: AppManifests.pick([:none, :ready, :not_ready]),
          probes?: AppManifests.pick([true, false]),
          probe: AppManifests.pick([:none, :healthy, :unhealthy, :skipped]),
          data?: AppManifests.pick([true, false]),
          stale_pull: AppManifests.pick([nil, nil, "image:0"]),
          api?: AppManifests.pick([true, true, false]),
          failed_action:
            some(fn ->
              Rows.failed(
                AppManifests.pick([:create, :start, :stop, :remove, :put_token, :request_pull]),
                reason
              )
            end)
        })
      ])
    end

    defp resource do
      facts = Rows.facts()

      fields = %{
        run: AppManifests.pick([true, false]),
        restart_counter: AppManifests.pick([0, 1]),
        start_counter: AppManifests.pick([0, 1]),
        holds: AppManifests.pick([%{}, %{"backup" => AppManifests.plain()}])
      }

      spec =
        case AppManifests.pick([:generated, :corpus, :core]) do
          :core ->
            Map.merge(%{lifecycle: :core, version: "2026.8.0"}, fields)

          :corpus ->
            Schema.from_manifest(AppManifests.pick(AppManifests.all()), facts, fields)

          :generated ->
            Schema.from_manifest(AppManifests.manifest(), facts, fields)
        end

      spec =
        case Schema.validate(spec, facts) do
          {:ok, spec} ->
            spec

          # A manifest that wants a dynamic ingress port.
          {:error, :ingress_port_missing} ->
            {:ok, spec} = Schema.validate(Map.put(spec, :ingress_port, 62_000), facts)
            spec
        end

      Harness.resource(:app, "generated", spec,
        status: status(spec),
        generation: AppManifests.pick([2, 3]),
        deleting?: AppManifests.pick([false, false, true]),
        finalizers: AppManifests.pick([[:app], [:app, :dns], [:dns]])
      )
    end

    test "any admitted spec, any status and any observation give a return the runtime accepts" do
      AppManifests.each(1_000, fn -> {resource(), observation()} end, fn {resource, observation} ->
        row =
          if resource.deleting? and :app not in resource.finalizers,
            do: {resource, observation, :no_verdict},
            else: {resource, observation}

        Harness.assert_verdict_contract(Controller, [row])
      end)
    end
  end

  describe "states an app can be in" do
    # `[{weight, value}]`, one value by weight.
    defp of(weighted) do
      at = :rand.uniform(Enum.sum(Enum.map(weighted, &elem(&1, 0))))

      Enum.reduce_while(weighted, at, fn {weight, value}, left ->
        if left <= weight, do: {:halt, value}, else: {:cont, left - weight}
      end)
    end

    defp chance(percent), do: :rand.uniform(100) <= percent

    defp before,
      do:
        Rows.ago(of([{3, 0}, {3, 500}, {3, 30_000}, {2, 200_000}, {2, 700_000}, {1, 2_000_000}]))

    # An app with a history: what is recorded is of the instance observed,
    # or of the one before it, and for the generation current or the last.
    # One function on purpose: what is observed is chosen to fit what is
    # recorded, and what is recorded to fit the app.
    # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
    defp case_of_an_app do
      kind = of([{30, :plain}, {30, :watched}, {12, :once}, {13, :native}, {15, :core}])

      fields = %{
        run: chance(80),
        restart_counter: of([{4, 0}, {1, 1}]),
        start_counter: of([{4, 0}, {1, 1}]),
        holds: of([{9, %{}}, {1, %{"backup" => true}}])
      }

      deleting? = chance(15)
      base = build(kind, fields, [])
      profile = Vagus.App.Profile.of(base.spec)
      container? = kind not in [:native, :core]
      image = if container?, do: "image:1"
      now = Rows.now()

      instance =
        case {kind, of([{30, :absent}, {70, :there}])} do
          {_kind, :absent} ->
            :absent

          {:native, :there} ->
            Rows.process(id: of([{4, "c1"}, {1, "c2"}]))

          {_kind, :there} ->
            state =
              of(
                [{40, :running}, {12, :created}, {20, :exited}, {2, :dead}, {3, :paused}] ++
                  [{3, :restarting}, {2, :removing}]
              )

            Rows.inst(state, %{
              id: of([{4, "c1"}, {1, "c2"}]),
              exit_code:
                if(state in [:created, :running, :paused],
                  do: nil,
                  else: of([{2, 0}, {2, 1}, {1, 137}])
                ),
              started_at: if(state != :created, do: of([{4, "started-1"}, {1, "started-2"}])),
              restart_count: of([{4, 0}, {1, 1}, {1, 4}]),
              health: of([{6, :none}, {2, :healthy}, {1, :starting}, {2, :unhealthy}]),
              token?: chance(92),
              grace: if(kind == :core, do: of([{1, 30}, {3, 260}]))
            })
        end

      there? = instance != :absent
      up? = there? and instance.state in [:running, :paused, :restarting]

      recorded =
        of([
          {25, nil},
          {75,
           Rows.seen(%{
             id: of([{5, "c1"}, {1, "c2"}]),
             running?: chance(80),
             since: of([{1, nil}, {4, before()}]),
             ready?: chance(60),
             restart_count: of([{5, 0}, {1, 1}]),
             started_at: of([{5, "started-1"}, {1, nil}]),
             process: if(kind == :native, do: self()),
             address: if(kind == :native, do: nil, else: "172.30.33.2")
           })}
        ])

      failure = fn ->
        Rows.failure(%{
          class: of([{1, :permanent}, {1, :transient}]),
          action:
            of([
              {4, :start},
              {2, :create},
              {1, :put_token},
              {1, :request_pull},
              {1, :stop},
              {1, :run}
            ]),
          cause: of([{1, :port_conflict}, {1, :engine_error}, {1, :crashed}]),
          generation: of([{5, 3}, {1, 2}]),
          at: before(),
          count: of([{4, 1}, {2, 2}, {1, 9}])
        })
      end

      pull = fn ->
        Rows.pulled(%{
          image: of([{5, "image:1"}, {1, "image:0"}]),
          generation: of([{5, 3}, {1, 2}]),
          failures: of([{3, 0}, {2, 1}, {1, 4}]),
          seen: of([{1, nil}, {1, before()}]),
          after: of([{2, nil}, {1, before()}])
        })
      end

      status =
        %{
          state: of([{1, :ready}, {1, :stopped}, {1, :failed}, {1, :starting}]),
          instance: recorded,
          made_for:
            of([
              {70, Rows.target(base.spec)},
              {10, nil},
              {7, %{Rows.target(base.spec) | restart_counter: 7}},
              {6, %{Rows.target(base.spec) | start_counter: 7}},
              {7, %{Rows.target(base.spec) | fingerprint: 0}}
            ]),
          expected_exit: of([{8, nil}, {3, "c1"}, {1, "c2"}]),
          recreate: of([{12, nil}, {1, "c1"}]),
          failure: of([{7, nil}, {3, failure}]) |> then(&(is_function(&1) && &1.())) || nil,
          succeeded: if(kind == :once, do: of([{2, nil}, {2, 3}, {1, 2}])),
          restarts:
            of(
              [{6, View.blank().restarts}, {2, Rows.restarts(1, 4_000)}] ++
                [{1, Rows.restarts(2, 100_000)}, {2, Rows.restarts(5, 1_000_000)}]
            ),
          engine_restarts:
            if(kind == :core,
              do: %{
                seen:
                  Enum.take([before(), before(), before()], of([{3, 0}, {1, 1}, {2, 2}, {2, 3}])),
                actions: Enum.take(for(_ <- 1..10, do: before()), of([{4, 0}, {1, 3}, {1, 10}]))
              },
              else: View.blank().engine_restarts
            ),
          probe:
            of([
              {5, View.blank().probe},
              {2, %{misses: 0, at: before()}},
              {2, %{misses: 1, at: before()}}
            ]),
          pull:
            if(container?,
              do: of([{6, nil}, {4, pull}]) |> then(&(is_function(&1) && &1.())) || nil
            ),
          wave_since: of([{4, nil}, {1, before()}]),
          ready_since: of([{3, nil}, {2, before()}]),
          cleaned: of([{6, []}, {1, [:image]}])
        }

      # Any subset: a key may never have been written.
      status = if chance(10), do: Map.filter(status, fn _ -> chance(60) end), else: status

      resource =
        build(kind, fields,
          status: status,
          deleting?: deleting?,
          finalizers: of([{9, [:app]}, {1, [:app, :dns]}])
        )

      http? = match?(%{kind: {:http, _}}, profile.readiness(base.spec))
      # Asked only of the run that was ready, and only when it is due.
      was_ready? =
        there? and
          match?(
            %{ready?: true, id: id, started_at: at}
            when id == instance.id and at == instance.started_at,
            status[:instance]
          )

      probes? = was_ready? and chance(60)

      due? =
        Vagus.App.Readiness.probe_due?(Map.merge(View.blank().probe, status[:probe] || %{}), now)

      asked? = image != nil and (not there? or deleting?)

      reason =
        of([
          {2, {:status, 500, "port is already allocated"}},
          {2, {:status, 500, "x"}},
          {1, {:status, 404, nil}},
          {1, {:timeout, :recv}},
          {1, {:unreachable, :enoent}},
          {1, :already_exists},
          {1, {:crashed, RuntimeError}},
          {1, {:stream, "manifest unknown"}},
          {1, {:stream, "unexpected EOF"}},
          {1, {:status, 409, "in use"}}
        ])

      asked_image = get_in(status, [:pull, :image])

      observation =
        of([
          {4, {:unavailable, of([{1, :engine_unavailable}, {1, :engine_error}])}},
          {96,
           Rows.obs(%{
             now: now,
             instance: instance,
             leftover:
               if(container? and not up?,
                 do: of([{8, :absent}, {1, :running}, {1, :stopped}]),
                 else: :absent
               ),
             image: image,
             image_present?: not asked? or chance(65),
             pull:
               if(image,
                 do:
                   of([
                     {6, :idle},
                     {2, {:pulling, true}},
                     {1, {:pulling, false}},
                     {3, {:failed, reason, before()}}
                   ]),
                 else: :idle
               ),
             # The table has the instance's token only of an instance with one.
             token:
               cond do
                 kind == :native -> :none
                 there? and instance.token? -> of([{5, :current}, {3, :absent}, {2, :other}])
                 true -> of([{3, :absent}, {2, :other}])
               end,
             waiting_on: if(there?, do: [], else: of([{5, []}, {1, ["core_mosquitto"]}])),
             gates: of([{5, []}, {1, [:dns_ready]}]),
             ready:
               if(http? and there? and instance.state == :running,
                 do: of([{1, :ready}, {1, :not_ready}]),
                 else: :none
               ),
             probes?: probes?,
             probe:
               if(probes? and due?,
                 do: of([{1, :healthy}, {2, :unhealthy}, {1, :skipped}]),
                 else: :none
               ),
             data?: deleting? and chance(50),
             stale_pull:
               if(is_binary(asked_image) and asked_image != image and chance(50), do: asked_image),
             api?: chance(88),
             failed_action:
               if(chance(25),
                 do:
                   Rows.failed(
                     of([
                       {3, :start},
                       {2, :create},
                       {1, :put_token},
                       {1, :stop},
                       {1, :remove},
                       {1, :remove_image},
                       {1, :request_pull}
                     ]),
                     reason,
                     of([{5, 3}, {1, 2}])
                   )
               )
           })}
        ])

      resource =
        if chance(10) and there? do
          Resource.put_condition(
            resource,
            Resource.condition(
              :dns_ready,
              chance(80),
              :registered,
              3,
              of([{3, instance.id}, {1, "c0"}])
            )
          )
        else
          resource
        end

      # Three corners the weights above seldom reach.
      case of([{88, :as_it_is}, {4, :renamed}, {4, :pull_paused}, {4, :deadline}]) do
        :as_it_is ->
          {resource, observation}

        :renamed ->
          {%{resource | name: "another"}, observation}

        :pull_paused ->
          record =
            Rows.pulled(
              failures: of([{1, 0}, {1, 1}, {1, 3}]),
              after: of([{1, nil}, {1, before()}])
            )

          failed =
            {:failed, of([{1, {:stream, "unexpected EOF"}}, {1, {:timeout, :recv}}]),
             Rows.ago(of([{1, 0}, {1, 500}, {1, 5_000}]))}

          {Rows.app("only_host_uts", %{}, status: %{pull: record}),
           Rows.obs(image_present?: false, pull: failed)}

        :deadline ->
          since = Rows.ago(of([{1, 599_000}, {1, 600_000}, {1, 700_000}]))
          status = Rows.running(instance: Rows.seen(since: since))

          answering =
            Rows.obs(
              instance: Rows.inst(),
              token: :current,
              ready: of([{3, :not_ready}, {1, :ready}]),
              image: nil
            )

          {Rows.core(%{}, status: status), answering}
      end
    end

    defp build(:plain, fields, opts), do: Rows.app("only_host_uts", fields, opts)
    defp build(:watched, fields, opts), do: Rows.watched(fields, opts)
    defp build(:once, fields, opts), do: Rows.once(fields, opts)
    defp build(:native, fields, opts), do: Rows.native(fields, opts)
    defp build(:core, fields, opts), do: Rows.core(fields, opts)

    defp action(effects),
      do: Enum.find_value(effects, &(match?({:action, _name, _args}, &1) && elem(&1, 1)))

    defp failed?(%Verdict{conditions: %{failed: {failed?, _reason}}}), do: failed?

    # What a return is compared by: everything but nothing.
    defp same({%Verdict{} = verdict, effects}), do: {verdict.conditions, verdict.status, effects}
    defp same(other), do: other

    # How many passes over the same observation, each from the status the
    # one before wrote, until a pass changes nothing.
    defp settles_in(resource, observation, returned, passes \\ 1) do
      case returned do
        {%Verdict{} = verdict, _effects} when passes < 6 ->
          # A probe's answer is of one asking: the app is not asked again
          # in the instant it answered.
          observation = %{observation | probe: :none}
          next = Controller.reconcile(written(resource, verdict), observation)

          if same(next) == same(returned),
            do: passes,
            else: settles_in(written(resource, verdict), observation, next, passes + 1)

        {%Verdict{}, _effects} ->
          :never

        _nothing_to_write ->
          passes
      end
    end

    test "every clause is reached, and what must never happen never does" do
      tally = :ets.new(:tally, [:public])

      AppManifests.each(4_000, &case_of_an_app/0, fn {resource, o} ->
        assert Rows.problems(resource, o) == []
        returned = {verdict, effects} = Controller.reconcile(resource, o)
        Harness.assert_verdict_contract(Controller, [{resource, o}])
        clause = Rows.clause(resource, o, returned)
        :ets.update_counter(tally, clause, 1, {clause, 0})
        assert Rows.status_problems(resource, o, returned) == []
        action = action(effects)
        spec = resource.spec
        wanted? = Schema.wanted?(spec) and not resource.deleting?

        if match?({:unavailable, _reason}, o) do
          assert effects == []
        else
          v = View.view(resource, o)
          inst = if o.instance != :absent, do: o.instance

          if not wanted? do
            assert action not in [:create, :start, :start_process, :request_pull]
            # A token is put for an app not to run only where the action
            # that should have stopped it raised and left it running.
            assert action != :put_token or clause == :restore_token_raised
          end

          if failed?(verdict), do: assert(action == nil)

          # A row that is not the instance's token resolves to the app for
          # whoever holds that token: no pass that sees one leaves it. But
          # for an app nothing is done to, and a removal that raised.
          if o.token == :other and not v.mismatch? and not v.revoke_raised?,
            do: assert(action == :remove_token)

          healthy? =
            wanted? and inst != nil and inst.state == :running and
              inst.health in [:none, :healthy] and o.leftover == :absent and not v.mismatch? and
              (v.made_for == nil or v.made_for.restart_counter == v.target.restart_counter) and
              resource.status[:expected_exit] != inst.id and
              resource.status[:recreate] != inst.id and
              not Vagus.App.Readiness.unhealthy?(v.base.probe) and not v.crash_loop?

          if healthy?, do: assert(action not in [:stop, :stop_process, :remove])

          if Enum.any?(effects, &match?({:remove_finalizer, _, _, _}, &1)) do
            assert resource.deleting?

            assert v.mismatch? or
                     (inst == nil and o.leftover == :absent and o.token in [:absent, :none] and
                        not o.data?)
          end

          depth = settles_in(resource, o, returned)
          :ets.update_counter(tally, {:settles_in, depth}, 1, {{:settles_in, depth}, 0})
          :ets.update_counter(tally, {clause, depth}, 1, {{clause, depth}, 0})
          # A pass may record what the pass after it then decides from: an
          # instance first seen is judged by the next pass, and what that
          # one counts is not counted by the third. It never goes on
          # writing with nothing new to see.
          assert depth in 1..3, "the same observation is decided anew #{depth} times"
        end
      end)

      counts = Map.new(:ets.tab2list(tally))
      reached = for clause <- Rows.clauses(), counts[clause], do: clause
      # See `Rows.unreachable/0`.
      assert Rows.clauses() -- reached == [:crash_loop]

      if System.get_env("VAGUS_SHOW_TALLY") do
        for clause <- [:unavailable | Rows.clauses()] do
          again = Enum.sum(for {{^clause, depth}, n} <- counts, depth != 1, do: n)

          IO.puts(
            "#{String.pad_trailing(to_string(clause), 20)} #{counts[clause] || 0}\t#{again}"
          )
        end

        IO.puts(
          "settles in: " <> inspect(for({{:settles_in, depth}, n} <- counts, do: {depth, n}))
        )
      end
    end
  end
end
