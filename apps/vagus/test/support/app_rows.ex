defmodule Vagus.Test.AppRows do
  @moduledoc """
  The App controller's decision as a table: resources and observations
  built by hand, each with the verdict, effects and status it must give.

  `obs/1` and `inst/2` build what `Vagus.App.Controller.Observe` returns.
  That they do is `problems/2`, which every row here and every observation
  the controller really makes (`Vagus.App.Controller.ObserveTest`) is held
  to. `clause/3` names the clause of the decision a return came from, and
  `status_problems/3` says what that clause must have written.
  """

  alias Vagus.App.Controller.View
  alias Vagus.App.Facts
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.{Harness, Stamp}
  alias Vagus.Test.AppManifests

  @container "only_host_uts"
  @watched "45df7312_zigbee2mqtt"
  @once "local_once"
  @now 1_000_000

  def facts, do: Facts.read(data_root: "/nowhere")
  def t(ms), do: %Stamp{incarnation: 1, at: ms}
  def now, do: t(@now)
  def ago(ms), do: t(@now - ms)

  def app(slug \\ @container, fields \\ %{}, opts \\ []) do
    spec =
      case slug do
        :core -> Map.merge(%{lifecycle: :core, version: "2026.8.0", run: true}, fields)
        slug -> slug |> AppManifests.get() |> Schema.from_manifest(facts(), with_run(fields))
      end

    {:ok, spec} = Schema.validate(spec, facts())
    name = if slug == :core, do: "homeassistant", else: slug
    status = opts |> Keyword.get(:status, %{}) |> made(spec)

    Harness.resource(:app, name, spec,
      status: status,
      generation: Keyword.get(opts, :generation, 3),
      deleting?: Keyword.get(opts, :deleting?, false),
      finalizers: Keyword.get(opts, :finalizers, [:app])
    )
  end

  defp with_run(fields), do: Map.merge(%{run: true}, fields)

  # `made_for: :this` is "made for the spec as it is"; a map is merged over that.
  defp made(%{made_for: :this} = status, spec), do: %{status | made_for: target(spec)}

  defp made(%{made_for: %{} = other} = status, spec),
    do: %{status | made_for: Map.merge(target(spec), other)}

  defp made(status, _spec), do: status

  def target(spec) do
    %{
      restart_counter: spec.restart_counter,
      start_counter: spec.start_counter,
      fingerprint: View.fingerprint(spec)
    }
  end

  def watched(fields \\ %{}, opts \\ []),
    do: app(@watched, Map.merge(%{settings: %{watchdog: true}}, fields), opts)

  def once(fields \\ %{}, opts \\ []), do: app(@once, fields, opts)
  def native(fields \\ %{}, opts \\ []), do: app("core_mqtt", fields, opts)
  def core(fields \\ %{}, opts \\ []), do: app(:core, fields, opts)

  def obs(over \\ %{}) do
    Map.merge(
      %{
        now: now(),
        instance: :absent,
        leftover: :absent,
        image: "image:1",
        image_present?: true,
        pull: :idle,
        token: :absent,
        waiting_on: [],
        gates: [],
        ready: :none,
        probes?: false,
        probe: :none,
        data?: false,
        stale_pull: nil,
        api?: true,
        failed_action: nil
      },
      Map.new(over)
    )
  end

  def inst(state \\ :running, over \\ %{}) do
    Map.merge(
      %{
        id: "c1",
        state: state,
        exit_code: if(state not in [:created, :running, :paused], do: 1),
        started_at: if(state != :created, do: "started-1"),
        restart_count: 0,
        health: :none,
        health_failing_streak: 0,
        image: "image:1",
        image_id: "sha256:1",
        labels: %{},
        address: "172.30.33.2",
        process: nil,
        token?: true,
        grace: nil
      },
      Map.new(over)
    )
  end

  # A native app's instance: a process, and nothing an engine would give it.
  def process(over \\ %{}) do
    inst(
      :running,
      Map.merge(
        %{
          started_at: nil,
          image: nil,
          image_id: nil,
          address: nil,
          process: self(),
          token?: false
        },
        Map.new(over)
      )
    )
  end

  # The record status keeps of the instance of `inst/2`.
  def seen(over \\ %{}) do
    Map.merge(
      %{
        id: "c1",
        address: "172.30.33.2",
        process: nil,
        running?: true,
        since: ago(60_000),
        ready?: false,
        restart_count: 0,
        started_at: "started-1"
      },
      Map.new(over)
    )
  end

  def running(over \\ %{}),
    do: Map.merge(%{instance: seen(), made_for: :this}, Map.new(over))

  def failure(over \\ %{}) do
    Map.merge(
      %{
        action: :start,
        class: :permanent,
        cause: :port_conflict,
        detail: %{port: 80},
        at: ago(5_000),
        generation: 3,
        count: 1
      },
      Map.new(over)
    )
  end

  def restarts(attempts, last_ago \\ 1_000), do: %{attempts: attempts, last: ago(last_ago)}

  def pulled(over \\ %{}) do
    Map.merge(
      %{image: "image:1", generation: 3, failures: 0, seen: nil, after: nil},
      Map.new(over)
    )
  end

  def action(name, args \\ %{}), do: [{:action, name, args}]
  def later(ms), do: [{:requeue_after, ms}]

  def failed(name, reason, generation \\ 3),
    do: %{name: name, reason: reason, at: ago(0), generation: generation}

  @doc "`{name, resource, observation, {kind, reason, state, wire}, effects, status}`"
  def all, do: decisions() ++ order() ++ guards() ++ raised()

  defp decisions do
    up = obs(instance: inst(), token: :current)
    ready = running(instance: seen(ready?: true), ready_since: ago(30_000))

    [
      {"the engine cannot be reached", app(), {:unavailable, :engine_unavailable},
       {:progressing, :engine_unavailable, nil, :unknown}, [], %{}},
      {"unreachable, with a status from before: the state stays",
       app(@container, %{}, status: %{state: :ready}), {:unavailable, :engine_unavailable},
       {:progressing, :engine_unavailable, :ready, :stopped}, [], %{}},
      {"a leftover container that runs is stopped first", app(), obs(leftover: :running),
       {:progressing, :removing_leftover, :stopping, :stopped}, action(:stop_leftover), %{}},
      {"a leftover container that is stopped is removed, before anything is created", app(),
       obs(leftover: :stopped), {:progressing, :removing_leftover, :stopping, :stopped},
       action(:remove_leftover), %{}},
      {"a leftover is removed for an app that is not to run as well",
       app(@container, %{run: false}), obs(leftover: :stopped),
       {:progressing, :removing_leftover, :stopping, :stopped}, action(:remove_leftover), %{}},
      {"a container the engine is removing is waited for", app(), obs(instance: inst(:removing)),
       {:progressing, :removing, :stopping, :stopped}, later(1_000), %{}},
      {"a stop cancels the pull the app waits for",
       app(@container, %{run: false},
         status: %{pull: %{image: "image:1", generation: 2, attempts: 1}}
       ), obs(image_present?: false, pull: {:pulling, true}),
       {:progressing, :cancelling_pull, :stopping, :stopped},
       action(:cancel_pull, %{image: "image:1"}), %{pull: nil}},
      {"a pull another app waits for is not this one's to cancel", app(@container, %{run: false}),
       obs(image_present?: false, pull: {:pulling, false}), {:idle, :stopped, :stopped, :stopped},
       [], %{}},
      {"a plain stop leaves the token for as long as the container runs",
       app(@container, %{run: false}, status: running()), up,
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{expected_exit: "c1"}},
      {"a stopped container goes before its token does",
       app(@container, %{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited), token: :current),
       {:progressing, :removing, :stopping, :stopped}, action(:remove, %{instance: "c1"}), %{}},
      {"Core stopped and kept: then its token goes",
       core(%{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited), token: :current, image: nil),
       {:progressing, :revoking_token, :stopping, :stopped}, action(:remove_token), %{}},
      {"deleting, nothing left but a token of some instance: it goes before the finalizer",
       app(@container, %{}, deleting?: true), obs(image_present?: false, token: :other),
       {:progressing, :revoking_token, :stopping, :stopped}, action(:remove_token), %{}},
      {"Failed and running, the token table replaced: its token is put back all the same",
       watched(%{},
         status: running(failure: failure(action: :run, cause: :restart_budget_exhausted))
       ), obs(instance: inst(:running, health: :unhealthy)),
       {:progressing, :indexing_token, :starting, :startup},
       action(:put_token, %{instance: "c1"}), %{}},
      {"a start asked for during a back-off starts at once, the count forgotten",
       watched(%{start_counter: 1},
         status: %{made_for: %{start_counter: 0}, restarts: restarts(3, 1_000)}
       ), obs(), {:progressing, :creating, :creating, :stopped}, action(:create),
       %{restarts: View.blank().restarts}},
      {"what the count was made under is kept while there is no instance",
       watched(%{}, status: %{made_for: :this, restarts: restarts(2, 1_000)}), obs(),
       {:progressing, :backing_off, :restarting, :stopped}, later(19_000),
       %{made_for: target(watched().spec), restarts: restarts(2, 1_000)}},
      {"a failure of an action decided for an earlier generation is not this one's", app(),
       obs(failed_action: failed(:create, {:status, 400, "bad"}, 2)),
       {:progressing, :creating, :creating, :stopped}, action(:create), %{failure: nil}},
      {"a failure handed over twice is counted once",
       app(@container, %{},
         status: %{
           made_for: :this,
           failure: failure(class: :transient, cause: :engine_error, at: ago(0))
         }
       ),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:status, 500, "x"})
       ), {:progressing, :engine_error, :starting, :stopped}, later(1_000), %{}},
      {"a run-once container that exited with 0 and nothing is recorded of has succeeded", once(),
       obs(instance: inst(:exited, exit_code: 0)), {:idle, :succeeded, :succeeded, :stopped}, [],
       %{succeeded: 3, made_for: target(once().spec)}},
      {"a start asked for of a run-once app that succeeded runs it again",
       once(%{start_counter: 1}, status: %{made_for: %{start_counter: 0}}),
       obs(instance: inst(:exited, exit_code: 0)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{}},
      {"a plain app that exited with 0 has not succeeded: it crashed",
       app(@container, %{}, status: running()), obs(instance: inst(:exited, exit_code: 0)),
       {:failed, :crashed, :failed, :error}, [], %{}},
      {"a pull of an image that is not wanted any more is cancelled",
       app(@container, %{}, status: %{pull: pulled(image: "image:0")}),
       obs(image_present?: false, stale_pull: "image:0"),
       {:progressing, :cancelling_pull, :pulling, :stopped},
       action(:cancel_pull, %{image: "image:0"}), %{pull: pulled(image: "image:0")}},
      {"Core's token not there yet is waited for", core(%{}, status: running()),
       obs(instance: inst(:running, token?: false), image: nil),
       {:progressing, :waiting_for_token, :starting, :startup}, later(5_000), %{}},
      {"deleting: an image whose removal failed otherwise is asked for again",
       app(@container, %{}, deleting?: true),
       obs(data?: true, failed_action: failed(:remove_image, {:timeout, :recv})),
       {:progressing, :removing_image, :deleting, :stopped},
       action(:remove_image, %{image: "image:1"}), %{cleaned: []}},
      {"an app named otherwise than its manifest's slug: Failed, and nothing is done",
       %{app() | name: "another"}, obs(leftover: :running),
       {:failed, :name_mismatch, :failed, :error}, [], %{}},
      {"such an app being deleted is let go, its data untouched",
       %{app(@container, %{}, deleting?: true) | name: "another"}, obs(data?: true),
       {:idle, :deleted, :deleting, :stopped}, [{:remove_finalizer, :app, "another", :app}], %{}},
      {"the API not accepting: nothing is created", app(), obs(api?: false),
       {:progressing, :waiting_for_api, :waiting, :stopped}, later(2_000), %{}},
      {"the API not accepting: a container that was created is not started",
       app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created), token: :current, api?: false),
       {:progressing, :waiting_for_api, :waiting, :stopped}, later(2_000), %{}},
      {"the API not accepting is nothing to a running app", app(@container, %{}, status: ready),
       Map.put(up, :api?, false), {:ready, :ready, :ready, :started}, [], %{}},
      {"an expected exit of another instance is not this one's: a crash",
       watched(%{}, status: running(expected_exit: "c0")), obs(instance: inst(:exited)),
       {:progressing, :crashed, :restarting, :stopped}, action(:remove, %{instance: "c1"}),
       %{restarts: %{attempts: 1, last: now()}, expected_exit: "c1"}},
      {"an instance other than the one recorded, running: taken as it is, nothing counted",
       watched(%{},
         status: running(instance: seen(id: "c0", ready?: true), restarts: restarts(1))
       ), up, {:ready, :ready, :ready, :started}, later(600_000),
       %{instance: seen(ready?: true, since: now()), restarts: restarts(1)}},
      {"a gate that is false but names the instance is closed",
       gated(app(@container, %{}, status: running()), "c1", false),
       obs(instance: inst(), token: :current, gates: [:dns_ready]),
       {:progressing, :waiting_for_gate, :starting, :startup}, [], %{ready_since: nil}},
      {"a transient failure of a stop holds nothing back: asked again",
       app(@container, %{run: false}, status: running()),
       obs(instance: inst(), failed_action: failed(:stop, {:status, 500, "x"})),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}),
       %{
         failure:
           failure(
             action: :stop,
             class: :transient,
             cause: :engine_error,
             detail: {:status, 500, "x"},
             at: ago(0)
           )
       }},
      {"a paused instance of an app not to run is stopped",
       app(@container, %{run: false}, status: running()), obs(instance: inst(:paused)),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{}},
      {"a stamp from another incarnation has no age: the back-off starts over",
       watched(%{},
         status: %{made_for: :this, restarts: %{attempts: 1, last: %Stamp{incarnation: 9, at: 5}}}
       ), obs(), {:progressing, :backing_off, :restarting, :stopped}, later(10_000), %{}},
      {"a token of an instance that is gone is taken away too", app(@container, %{run: false}),
       obs(token: :other), {:progressing, :revoking_token, :stopping, :stopped},
       action(:remove_token), %{}},
      {"not wanted and running: the exit is expected, then stop",
       app(@container, %{run: false}, status: running()), obs(instance: inst()),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{expected_exit: "c1"}},
      {"held and running: stopped the same way",
       app(@container, %{holds: %{"backup" => true}}, status: running()), obs(instance: inst()),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{expected_exit: "c1"}},
      {"a restart counter above the instance's: the instance is stopped",
       app(@container, %{restart_counter: 2}, status: running(made_for: %{restart_counter: 1})),
       up, {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{expected_exit: "c1"}},
      {"a start counter above a running instance's changes nothing",
       app(@container, %{start_counter: 2},
         status: Map.merge(ready, %{made_for: %{start_counter: 1}})
       ), up, {:ready, :ready, :ready, :started}, [], %{expected_exit: nil}},
      {"an instance whose exit is expected and that still runs is stopped again",
       app(@container, %{}, status: running(expected_exit: "c1")), up,
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{}},
      {"Core is stopped with the grace its image asks for",
       core(%{run: false}, status: running()),
       obs(instance: inst(:running, grace: 260), token: :absent, image: nil),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: 260, instance: "c1"}), %{}},
      {"a native app is stopped as a process", native(%{run: false}, status: running()),
       obs(instance: process(), token: :none, image: nil),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop_process, %{grace: nil, instance: "c1"}), %{expected_exit: "c1"}},
      {"stopped by request and still there: removed",
       app(@container, %{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{expected_exit: "c1"}},
      {"an exit that was expected of a wanted app: removed, not counted",
       watched(%{}, status: running(expected_exit: "c1")), obs(instance: inst(:exited)),
       {:progressing, :removing, :stopping, :stopped}, action(:remove, %{instance: "c1"}),
       %{restarts: View.blank().restarts}},
      {"a stopped instance made for an earlier start counter is replaced",
       app(@container, %{start_counter: 2}, status: running(made_for: %{start_counter: 1})),
       obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{}},
      {"created from a spec that has changed since, and never started: made anew",
       app(@container, %{}, status: %{made_for: %{fingerprint: 0}}),
       obs(instance: inst(:created)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{}},
      {"a container that has run and nothing is recorded of: removed, not counted", watched(),
       obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{restarts: View.blank().restarts}},
      {"Core stopped by request stays", core(%{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited), image: nil), {:idle, :stopped, :stopped, :stopped}, [], %{}},
      {"Core being deleted is removed", core(%{}, status: running(), deleting?: true),
       obs(instance: inst(:exited), image: nil), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{}},
      {"deleting: the token goes first, while the container still runs",
       app(@container, %{}, status: running(), deleting?: true), up,
       {:progressing, :revoking_token, :stopping, :startup}, action(:remove_token), %{}},
      {"deleting: then the container is stopped",
       app(@container, %{}, status: running(), deleting?: true), obs(instance: inst()),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{expected_exit: "c1"}},
      {"deleting: then the image", app(@container, %{}, deleting?: true), obs(),
       {:progressing, :removing_image, :deleting, :stopped},
       action(:remove_image, %{image: "image:1"}), %{cleaned: []}},
      {"deleting: an image that could not be removed is left",
       app(@container, %{}, deleting?: true),
       obs(data?: true, failed_action: failed(:remove_image, {:status, 409, "in use"})),
       {:progressing, :removing_data, :deleting, :stopped}, action(:remove_data),
       %{cleaned: [:image]}},
      {"deleting: then the app's data", app(@container, %{}, deleting?: true),
       obs(image_present?: false, data?: true),
       {:progressing, :removing_data, :deleting, :stopped}, action(:remove_data), %{}},
      {"deleting: with nothing left the finalizer is released",
       app(@container, %{}, deleting?: true), obs(image_present?: false),
       {:idle, :deleted, :deleting, :stopped}, [{:remove_finalizer, :app, @container, :app}],
       %{}},
      {"deleting, the finalizer released: nothing to say",
       app(@container, %{}, deleting?: true, finalizers: [:dns]), obs(), :no_verdict, [], %{}},
      {"not to run, nothing there",
       app(@container, %{run: false}, status: %{restarts: restarts(3), wave_since: ago(9)}),
       obs(), {:idle, :stopped, :stopped, :stopped}, [],
       %{restarts: View.blank().restarts, wave_since: nil, instance: nil}},
      {"held, nothing there", app(@container, %{holds: %{"backup" => true}}), obs(),
       {:idle, :held, :stopped, :stopped}, [], %{}},
      {"a run-once app that succeeded, its container since removed, is not run again",
       once(%{}, status: %{succeeded: 3}), obs(), {:idle, :succeeded, :succeeded, :stopped}, [],
       %{succeeded: 3}},
      {"a permanent failure holds for its generation",
       app(@container, %{}, status: %{failure: failure(), made_for: :this}),
       obs(instance: inst(:created), token: :current), {:failed, :port_conflict, :failed, :error},
       [], %{}},
      {"a failure of an earlier generation holds nothing",
       app(@container, %{}, status: %{failure: failure(generation: 2)}), obs(),
       {:progressing, :creating, :creating, :stopped}, action(:create), %{failure: nil}},
      {"an action failed for good: Failed, with the cause",
       app(@container, %{}, status: %{made_for: :this}),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action:
           failed(
             :start,
             {:status, 500, "Bind for 0.0.0.0:8080 failed: port is already allocated"}
           )
       ), {:failed, :port_conflict, :failed, :error}, [],
       %{failure: failure(detail: %{port: 8080}, at: ago(0))}},
      {"an action failed for now: held back, then tried again",
       app(@container, %{}, status: %{made_for: :this}),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:status, 500, "x"})
       ), {:progressing, :engine_error, :starting, :stopped}, later(1_000), %{}},
      {"the second failure of the same action waits twice as long",
       app(@container, %{},
         status: %{
           made_for: :this,
           failure: failure(class: :transient, cause: :engine_error, at: ago(500))
         }
       ),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:status, 500, "x"})
       ), {:progressing, :engine_error, :starting, :stopped}, later(2_000), %{}},
      {"its wait over, the action is asked for again",
       app(@container, %{},
         status: %{
           instance: seen(running?: false, since: nil),
           made_for: :this,
           failure: failure(class: :transient, cause: :engine_error, at: ago(1_000))
         }
       ), obs(instance: inst(:created), token: :current),
       {:progressing, :starting, :starting, :stopped}, action(:start, %{instance: "c1"}), %{}},
      {"a stop that timed out is still stopping: no failure, look again",
       app(@container, %{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(), failed_action: failed(:stop, {:timeout, :recv})),
       {:progressing, :stopping, :stopping, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{failure: nil}},
      {"Core restarted by the engine, below the rule: counted, left alone",
       core(%{},
         status: Map.merge(ready, %{engine_restarts: %{seen: [ago(1_000)], actions: []}})
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:progressing, :not_answering, :starting, :startup}, later(5_000),
       %{engine_restarts: %{seen: [now(), ago(1_000)], actions: []}}},
      {"Core restarted three times between two passes: each is counted, and that is a crash loop",
       core(%{}, status: running()),
       obs(
         instance: inst(:running, restart_count: 3, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:failed, :crash_loop, :failed, :error}, [],
       %{engine_restarts: %{seen: [now(), now(), now()], actions: []}}},
      {"restarted twice between two passes: both counted, and below the rule",
       core(%{}, status: running()),
       obs(
         instance: inst(:running, restart_count: 2, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:progressing, :not_answering, :starting, :startup}, later(5_000),
       %{engine_restarts: %{seen: [now(), now()], actions: []}}},
      {"restarted once, and twice more by the next pass: a crash loop",
       core(%{},
         status:
           running(
             instance: seen(restart_count: 1, started_at: "started-2"),
             engine_restarts: %{seen: [ago(1_000)], actions: []}
           )
       ),
       obs(
         instance: inst(:running, restart_count: 3, started_at: "started-3"),
         token: :current,
         image: nil
       ), {:failed, :crash_loop, :failed, :error}, [],
       %{engine_restarts: %{seen: [now(), now(), ago(1_000)], actions: []}}},
      {"a restart count lower than the one recorded of the same container counts nothing",
       core(%{}, status: running(instance: seen(restart_count: 3))),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:progressing, :not_answering, :starting, :startup}, later(5_000),
       %{engine_restarts: %{seen: [], actions: []}}},
      {"however far the count rose, no more restarts are kept than the rule asks for",
       core(%{}, status: running()),
       obs(
         instance: inst(:running, restart_count: 500, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:failed, :crash_loop, :failed, :error}, [],
       %{engine_restarts: %{seen: [now(), now(), now()], actions: []}}},
      {"and of those kept, the newest: an earlier one makes room",
       core(%{},
         status: running(engine_restarts: %{seen: [ago(1_000), ago(2_000)], actions: []})
       ),
       obs(
         instance: inst(:running, restart_count: 2, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:failed, :crash_loop, :failed, :error}, [],
       %{engine_restarts: %{seen: [now(), now(), ago(1_000)], actions: []}}},
      {"restarts seen at once are forgotten at once, the window after they were seen",
       core(%{},
         status:
           Map.merge(ready, %{
             engine_restarts: %{seen: [ago(600_000), ago(600_000), ago(600_000)], actions: []}
           })
       ), obs(instance: inst(), token: :current, image: nil), {:ready, :ready, :ready, :started},
       [], %{engine_restarts: %{seen: [], actions: []}}},
      {"a restart count that rose with no new start is no restart", core(%{}, status: ready),
       obs(instance: inst(:running, restart_count: 1), token: :current, image: nil),
       {:ready, :ready, :ready, :started}, [], %{engine_restarts: %{seen: [], actions: []}}},
      {"Core in a crash loop, and nothing to make it from: Failed",
       core(%{},
         status: running(engine_restarts: %{seen: [ago(2_000), ago(1_000)], actions: []})
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:failed, :crash_loop, :failed, :error}, [], %{}},
      {"restarts older than the rule's window are forgotten",
       core(%{},
         status:
           Map.merge(ready, %{engine_restarts: %{seen: [ago(700_000), ago(650_000)], actions: []}})
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:progressing, :not_answering, :starting, :startup}, later(5_000),
       %{engine_restarts: %{seen: [now()], actions: []}}},
      {"a run-once app that exited with 0 has succeeded", once(%{}, status: running()),
       obs(instance: inst(:exited, exit_code: 0)), {:idle, :succeeded, :succeeded, :stopped}, [],
       %{succeeded: 3}},
      {"a run-once app that exited otherwise has failed", once(%{}, status: running()),
       obs(instance: inst(:exited, exit_code: 2)), {:failed, :crashed, :failed, :error}, [], %{}},
      {"watchdog off: a dead container is Failed and stays",
       app(@container, %{}, status: running()), obs(instance: inst(:exited, exit_code: 137)),
       {:failed, :crashed, :failed, :error}, [],
       %{
         failure: %{
           action: :run,
           class: :permanent,
           cause: :crashed,
           detail: %{exit_code: 137},
           at: now(),
           generation: 3,
           count: 1
         }
       }},
      {"watchdog off: an instance that is gone is Failed too",
       native(%{settings: %{watchdog: false}}, status: running()), obs(token: :none, image: nil),
       {:failed, :crashed, :failed, :error}, [], %{instance: nil}},
      {"an instance removed by request is not a crash",
       native(%{}, status: running(expected_exit: "c1")), obs(token: :none, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start_process),
       %{expected_exit: nil}},
      {"the attempts of the run are spent: Failed",
       watched(%{}, status: running(restarts: restarts(5))), obs(instance: inst(:exited)),
       {:failed, :restart_budget_exhausted, :failed, :error}, [], %{}},
      {"unhealthy with the budget spent: Failed, and left running",
       watched(%{}, status: running(restarts: restarts(5))),
       obs(instance: inst(:running, health: :unhealthy), token: :current),
       {:failed, :restart_budget_exhausted, :failed, :error}, [], %{}},
      {"a crash: counted, and the dead container removed", watched(%{}, status: running()),
       obs(instance: inst(:exited)), {:progressing, :crashed, :restarting, :stopped},
       action(:remove, %{instance: "c1"}),
       %{restarts: %{attempts: 1, last: now()}, expected_exit: "c1"}},
      {"a second crash of the run: counted in the same run",
       watched(%{}, status: running(restarts: restarts(1, 20_000))), obs(instance: inst(:exited)),
       {:progressing, :crashed, :restarting, :stopped}, action(:remove, %{instance: "c1"}),
       %{restarts: %{attempts: 2, last: now()}}},
      {"a native app that ended: counted, nothing to remove", native(%{}, status: running()),
       obs(token: :none, image: nil), {:progressing, :crashed, :restarting, :stopped}, later(0),
       %{restarts: %{attempts: 1, last: now()}, instance: nil}},
      {"unhealthy while running: counted and stopped", watched(%{}, status: ready),
       obs(instance: inst(:running, health: :unhealthy), token: :current),
       {:progressing, :unhealthy, :restarting, :startup},
       action(:stop, %{grace: nil, instance: "c1"}),
       %{restarts: %{attempts: 1, last: now()}, expected_exit: "c1"}},
      {"a second probe unanswered: unhealthy",
       watched(%{}, status: Map.merge(ready, %{probe: %{misses: 1, at: ago(120_000)}})),
       obs(instance: inst(), token: :current, probes?: true, probe: :unhealthy),
       {:progressing, :unhealthy, :restarting, :startup},
       action(:stop, %{grace: nil, instance: "c1"}), %{probe: %{misses: 2, at: now()}}},
      {"one probe unanswered: still Ready, asked again in two minutes",
       watched(%{}, status: Map.merge(ready, %{probe: %{misses: 0, at: ago(120_000)}})),
       obs(instance: inst(), token: :current, probes?: true, probe: :unhealthy),
       {:ready, :ready, :ready, :started}, later(120_000), %{probe: %{misses: 1, at: now()}}},
      {"a probe answered forgets the miss before it",
       watched(%{}, status: Map.merge(ready, %{probe: %{misses: 1, at: ago(120_000)}})),
       obs(instance: inst(), token: :current, probes?: true, probe: :healthy),
       {:ready, :ready, :ready, :started}, later(120_000), %{probe: %{misses: 0, at: now()}}},
      {"a probe that could not be aimed is neither",
       watched(%{}, status: Map.merge(ready, %{probe: %{misses: 1, at: ago(120_000)}})),
       obs(instance: inst(), token: :current, probes?: true, probe: :skipped),
       {:ready, :ready, :ready, :started}, later(120_000), %{probe: %{misses: 1, at: now()}}},
      {"unhealthy with the watchdog off: not Ready, not restarted",
       app(@container, %{}, status: ready),
       obs(instance: inst(:running, health: :unhealthy), token: :current),
       {:progressing, :unhealthy, :starting, :startup}, [], %{}},
      {"after a crash the next start waits out its back-off",
       watched(%{}, status: %{restarts: restarts(1, 4_000)}), obs(),
       {:progressing, :backing_off, :restarting, :stopped}, later(6_000), %{}},
      {"the back-off doubles with each attempt",
       watched(%{}, status: %{restarts: restarts(3, 4_000)}), obs(),
       {:progressing, :backing_off, :restarting, :stopped}, later(36_000), %{}},
      {"the back-off over: the start sequence",
       watched(%{}, status: %{restarts: restarts(1, 10_000)}), obs(),
       {:progressing, :creating, :creating, :stopped}, action(:create),
       %{restarts: restarts(1, 10_000)}},
      {"an earlier wave still starting: wait, from now", app(),
       obs(waiting_on: ["core_mosquitto"]), {:progressing, :waiting_for_wave, :waiting, :stopped},
       later(120_000), %{wave_since: now(), waiting_on: ["core_mosquitto"]}},
      {"the wait is measured from when it began",
       app(@container, %{}, status: %{wave_since: ago(100_000)}),
       obs(waiting_on: ["core_mosquitto"]), {:progressing, :waiting_for_wave, :waiting, :stopped},
       later(20_000), %{wave_since: ago(100_000)}},
      {"a container in the place of one that was Ready has held Ready from now, not from then",
       watched(%{},
         status:
           running(
             instance: seen(id: "c0", ready?: true),
             restarts: restarts(1),
             ready_since: ago(600_000)
           )
       ), up, {:ready, :ready, :ready, :started}, later(600_000),
       %{ready_since: now(), restarts: restarts(1)}},
      {"and so has the same container started again since",
       watched(%{},
         status: Map.merge(ready, %{restarts: restarts(1), ready_since: ago(600_000)})
       ), obs(instance: inst(:running, started_at: "started-2"), token: :current),
       {:ready, :ready, :ready, :started}, later(600_000),
       %{ready_since: now(), restarts: restarts(1)}},
      {"the image there and no pull under way: what was counted of the pull is forgotten",
       app(@container, %{}, status: %{pull: pulled(failures: 2, seen: ago(9_000))}), obs(),
       {:progressing, :creating, :creating, :stopped}, action(:create), %{pull: nil}},
      {"Ready: the wave that was waited for, and since when, are forgotten",
       app(@container, %{},
         status: Map.merge(ready, %{wave_since: ago(300_000), waiting_on: ["core_mosquitto"]})
       ), up, {:ready, :ready, :ready, :started}, [], %{wave_since: nil, waiting_on: []}},
      {"a wait that begins after a restart was asked for is measured from its own beginning",
       app(@container, %{restart_counter: 1}, status: %{made_for: %{restart_counter: 0}}),
       obs(waiting_on: ["core_mosquitto"]), {:progressing, :waiting_for_wave, :waiting, :stopped},
       later(120_000), %{wave_since: now(), waiting_on: ["core_mosquitto"]}},
      {"and a minute on it has a minute left, from that beginning",
       app(@container, %{restart_counter: 1},
         status: %{made_for: %{restart_counter: 0}, wave_since: now()}
       ), obs(now: t(@now + 60_000), waiting_on: ["core_mosquitto"]),
       {:progressing, :waiting_for_wave, :waiting, :stopped}, later(60_000),
       %{wave_since: now(), waiting_on: ["core_mosquitto"]}},
      {"created, nobody waited for any more: the wait's beginning is forgotten before the start",
       app(@container, %{}, status: %{made_for: :this, wave_since: ago(120_000)}),
       obs(instance: inst(:created), token: :current),
       {:progressing, :starting, :starting, :stopped}, action(:start, %{instance: "c1"}),
       %{wave_since: nil}},
      {"the wait over: start anyway", app(@container, %{}, status: %{wave_since: ago(120_000)}),
       obs(waiting_on: ["core_mosquitto"]), {:progressing, :creating, :creating, :stopped},
       action(:create), %{waiting_on: []}},
      {"Core with no container: nothing here can make one", core(), obs(image: nil),
       {:failed, :no_container_builder, :failed, :error}, [], %{}},
      {"the image is being pulled for this app: wait",
       app(@container, %{}, status: %{pull: pulled()}),
       obs(image_present?: false, pull: {:pulling, true}),
       {:progressing, :pulling, :pulling, :stopped}, [], %{pull: pulled()}},
      {"the image is being pulled for another: join", app(),
       obs(image_present?: false, pull: {:pulling, false}),
       {:progressing, :pulling, :pulling, :stopped},
       action(:request_pull, %{image: "image:1", priority: 50}), %{pull: pulled()}},
      {"no image: ask for the pull", app(), obs(image_present?: false),
       {:progressing, :pulling, :pulling, :stopped},
       action(:request_pull, %{image: "image:1", priority: 50}), %{pull: pulled()}},
      {"the pull this app asked for was refused: Failed, not asked again",
       app(@container, %{}, status: %{pull: pulled()}),
       obs(image_present?: false, pull: {:failed, {:status, 404, "no such image"}, ago(50)}),
       {:failed, :image_not_found, :failed, :error}, [],
       %{pull: pulled(failures: 1, seen: ago(50))}},
      {"a refusal from an earlier generation's pull: asked again, and not taken for the answer",
       app(@container, %{}, status: %{pull: pulled(generation: 2, failures: 1, seen: ago(50))}),
       obs(image_present?: false, pull: {:failed, {:status, 404, "no such image"}, ago(50)}),
       {:progressing, :pulling, :pulling, :stopped},
       action(:request_pull, %{image: "image:1", priority: 50}), %{pull: pulled(after: ago(50))}},
      {"the refusal that stood when this generation asked is not this generation's",
       app(@container, %{}, status: %{pull: pulled(after: ago(50))}),
       obs(image_present?: false, pull: {:failed, {:status, 404, "no such image"}, ago(50)}),
       {:progressing, :pulling, :pulling, :stopped},
       action(:request_pull, %{image: "image:1", priority: 50}), %{pull: pulled(after: ago(50))}},
      {"the pull failed for now: counted, and waited for from when it failed",
       app(@container, %{},
         status: %{pull: pulled(failures: 1, seen: ago(9_000), after: ago(9_000))}
       ), obs(image_present?: false, pull: {:failed, {:stream, "unexpected EOF"}, ago(500)}),
       {:progressing, :pull_failed, :pulling, :stopped}, later(1_500),
       %{pull: pulled(failures: 2, seen: ago(500), after: ago(9_000))}},
      {"a failure seen before is counted once",
       app(@container, %{}, status: %{pull: pulled(failures: 2, seen: ago(500))}),
       obs(image_present?: false, pull: {:failed, {:stream, "unexpected EOF"}, ago(500)}),
       {:progressing, :pull_failed, :pulling, :stopped}, later(1_500),
       %{pull: pulled(failures: 2, seen: ago(500))}},
      {"that wait over: ask again",
       app(@container, %{}, status: %{pull: pulled(failures: 2, seen: ago(2_000))}),
       obs(image_present?: false, pull: {:failed, {:stream, "unexpected EOF"}, ago(2_000)}),
       {:progressing, :pulling, :pulling, :stopped},
       action(:request_pull, %{image: "image:1", priority: 50}),
       %{pull: pulled(failures: 2, seen: ago(2_000), after: ago(2_000))}},
      {"a native app with no instance is started", native(), obs(token: :none, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start_process),
       %{made_for: target(native().spec)}},
      {"image there, no container: create, recording what for",
       app(@container, %{restart_counter: 4}), obs(),
       {:progressing, :creating, :creating, :stopped}, action(:create),
       %{made_for: target(app(@container, %{restart_counter: 4}).spec), expected_exit: nil}},
      {"a container without a token cannot be started",
       app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created, token?: false)), {:failed, :no_token, :failed, :error}, [],
       %{}},
      {"created, its token not in the table: put it, before any start",
       app(@container, %{}, status: %{made_for: :this}), obs(instance: inst(:created)),
       {:progressing, :indexing_token, :starting, :stopped},
       action(:put_token, %{instance: "c1"}),
       %{instance: seen(running?: false, since: nil, started_at: nil)}},
      {"created, the table holding another instance's token: that one goes before this one's is put",
       app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created), token: :other),
       {:progressing, :revoking_token, :starting, :stopped}, action(:remove_token), %{}},
      {"running with no token to put, the table holding another instance's: that one goes",
       app(@container, %{}, status: running()),
       obs(instance: inst(:running, token?: false), token: :other),
       {:progressing, :revoking_token, :starting, :startup}, action(:remove_token),
       %{instance: seen()}},
      {"and with no row left, a running instance without a token is Failed",
       app(@container, %{}, status: running()), obs(instance: inst(:running, token?: false)),
       {:failed, :no_token, :failed, :error}, [], %{}},
      {"Core's token not there, the table holding an earlier one: that goes before the wait",
       core(%{}, status: running()),
       obs(instance: inst(:running, token?: false), token: :other, image: nil),
       {:progressing, :revoking_token, :starting, :startup}, action(:remove_token), %{}},
      {"Failed for good with no instance, a token of the one before in the table: it goes",
       app(@container, %{}, status: %{failure: failure(action: :create, cause: :invalid_config)}),
       obs(token: :other), {:progressing, :revoking_token, :starting, :stopped},
       action(:remove_token), %{failure: failure(action: :create, cause: :invalid_config)}},
      {"an instance that is gone, its token in the table: the token goes, the instance is not judged",
       watched(%{}, status: running()), obs(token: :other),
       {:progressing, :revoking_token, :starting, :startup}, action(:remove_token),
       %{instance: seen(), restarts: View.blank().restarts}},
      {"and is judged by the pass after, from what was kept of it",
       watched(%{}, status: running()), obs(), {:progressing, :crashed, :restarting, :stopped},
       later(0), %{restarts: %{attempts: 1, last: now()}, instance: nil}},
      {"an exit that was asked for stays asked for while the token of the instance that is gone goes",
       watched(%{}, status: running(expected_exit: "c1")), obs(token: :other),
       {:progressing, :revoking_token, :starting, :startup}, action(:remove_token),
       %{instance: seen(), expected_exit: "c1"}},
      {"running, the table without its token: put back, the container untouched",
       app(@container, %{}, status: ready), obs(instance: inst()),
       {:progressing, :indexing_token, :starting, :startup},
       action(:put_token, %{instance: "c1"}), %{}},
      {"created and its token known: start", app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created), token: :current),
       {:progressing, :starting, :starting, :stopped}, action(:start, %{instance: "c1"}), %{}},
      {"Core stopped and wanted: the container is started again, for what is wanted now",
       core(%{restart_counter: 1},
         status: running(expected_exit: "c1", made_for: %{restart_counter: 0})
       ), obs(instance: inst(:exited), token: :current, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start, %{instance: "c1"}),
       %{expected_exit: nil, made_for: target(core(%{restart_counter: 1}).spec)}},
      {"Core found stopped by something else: started, not counted", core(%{}, status: running()),
       obs(instance: inst(:exited), token: :current, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start, %{instance: "c1"}), %{}},
      {"Core not answering yet: asked again shortly", core(%{}, status: running()),
       obs(instance: inst(), token: :current, ready: :not_ready, image: nil),
       {:progressing, :not_answering, :starting, :startup}, later(5_000), %{}},
      {"Core not answering past its deadline: Failed, and still asked",
       core(%{}, status: running(instance: seen(since: ago(600_000)))),
       obs(instance: inst(), token: :current, ready: :not_ready, image: nil),
       {:failed, :readiness_timeout, :failed, :error}, later(30_000), %{failure: nil}},
      {"Core answering after its deadline has passed: Ready, with nothing written to its spec",
       core(%{}, status: running(instance: seen(since: ago(700_000)))),
       obs(instance: inst(), token: :current, ready: :ready, image: nil),
       {:ready, :ready, :ready, :started}, [],
       %{failure: nil, instance: seen(since: ago(700_000), ready?: true)}},
      {"Core answering: Ready, and not asked again", core(%{}, status: running()),
       obs(instance: inst(), token: :current, ready: :ready, image: nil),
       {:ready, :ready, :ready, :started}, [], %{instance: seen(ready?: true)}},
      {"a healthcheck that has not passed yet: starting", app(@container, %{}, status: running()),
       obs(instance: inst(:running, health: :starting), token: :current),
       {:progressing, :health_starting, :starting, :startup}, [], %{}},
      {"paused is not ready", app(@container, %{}, status: running()),
       obs(instance: inst(:paused), token: :current),
       {:progressing, :not_running, :starting, :startup}, [], %{}},
      {"ready but for a gate: running, not Ready, never Failed",
       app(@container, %{}, status: running()),
       obs(instance: inst(), token: :current, gates: [:dns_ready]),
       {:progressing, :waiting_for_gate, :starting, :startup}, [], %{}},
      {"a gate that names an earlier instance is closed",
       gated(app(@container, %{}, status: running()), "c0"),
       obs(instance: inst(), token: :current, gates: [:dns_ready]),
       {:progressing, :waiting_for_gate, :starting, :startup}, [], %{}},
      {"a gate that names this instance is open",
       gated(app(@container, %{}, status: running()), "c1"),
       obs(instance: inst(), token: :current, gates: [:dns_ready]),
       {:ready, :ready, :ready, :started}, [], %{ready_since: now()}},
      {"running, healthy, token known: Ready", app(@container, %{}, status: running()),
       obs(instance: inst(:running, health: :healthy), token: :current),
       {:ready, :ready, :ready, :started}, [],
       %{ready_since: now(), instance: seen(ready?: true), failure: nil, restart_required: false}},
      {"a running container nothing is recorded of is taken as it is", app(), up,
       {:ready, :ready, :ready, :started}, [],
       %{made_for: target(app().spec), instance: seen(ready?: true, since: now())}},
      {"a native app that runs is Ready", native(%{}, status: running()),
       obs(instance: process(), token: :none, image: nil), {:ready, :ready, :ready, :started}, [],
       %{}},
      {"Ready, with attempts spent: forgotten once Ready has held",
       watched(%{},
         status: Map.merge(ready, %{restarts: restarts(2), ready_since: ago(600_000)})
       ), up, {:ready, :ready, :ready, :started}, [], %{restarts: View.blank().restarts}},
      {"Ready, with attempts spent, too briefly: looked at again when it has held",
       watched(%{},
         status: Map.merge(ready, %{restarts: restarts(2), ready_since: ago(400_000)})
       ), up, {:ready, :ready, :ready, :started}, later(200_000), %{restarts: restarts(2)}},
      {"options changed under a running app: recorded, nothing done",
       app(@container, %{options: %{}}, status: Map.merge(ready, %{made_for: %{fingerprint: 0}})),
       up, {:ready, :ready, :ready, :started}, [], %{restart_required: true}},
      {"a restart counter that rose forgets the attempts of the instance before",
       watched(%{restart_counter: 1},
         status: running(made_for: %{restart_counter: 0}, restarts: restarts(5))
       ), obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{restarts: View.blank().restarts}}
    ]
  end

  @running [:running, :paused, :restarting]
  @states [:created, :exited, :dead, :removing | @running]

  @doc """
  What is wrong with `observation` as something
  `Vagus.App.Controller.Observe` could have returned for `resource`: its
  keys, the shape of each value, and what one part of it rules out in
  another. Nothing, for an observation it could.
  """
  def problems(_resource, {:unavailable, reason}),
    do:
      if(reason in [:engine_unavailable, :engine_error, :native_supervisor_down],
        do: [],
        else: [:reason]
      )

  def problems(resource, o) do
    keys = if Enum.sort(Map.keys(o)) == Enum.sort(Map.keys(obs())), do: [], else: [:keys]
    keys ++ if(keys == [], do: shapes(o) ++ rules(resource, o), else: [])
  end

  defp shapes(o) do
    for {key, ok?} <- [
          now: match?(%Stamp{}, o.now),
          instance: o.instance == :absent or instance_problems(o.instance) == [],
          leftover: o.leftover in [:absent, :running, :stopped],
          image: is_nil(o.image) or is_binary(o.image),
          image_present?: is_boolean(o.image_present?),
          pull:
            match?(:idle, o.pull) or
              match?({:pulling, waiting?} when is_boolean(waiting?), o.pull) or
              match?({:failed, _reason, %Stamp{}}, o.pull),
          token: o.token in [:none, :current, :other, :absent],
          waiting_on: is_list(o.waiting_on) and Enum.all?(o.waiting_on, &is_binary/1),
          gates: is_list(o.gates) and Enum.all?(o.gates, &is_atom/1),
          ready: o.ready in [:none, :ready, :not_ready],
          probes?: is_boolean(o.probes?),
          probe: o.probe in [:none, :healthy, :unhealthy, :skipped],
          data?: is_boolean(o.data?),
          stale_pull: is_nil(o.stale_pull) or is_binary(o.stale_pull),
          api?: is_boolean(o.api?),
          failed_action:
            is_nil(o.failed_action) or
              match?(
                %{name: name, reason: _, at: %Stamp{}, generation: _} when is_atom(name),
                o.failed_action
              )
        ],
        not ok?,
        do: key
  end

  @doc "As `problems/2`, of the instance alone."
  def instance_problems(i) do
    keys =
      if Enum.sort(Map.keys(i)) == Enum.sort(Map.keys(inst())), do: [], else: [:instance_keys]

    keys ++
      if keys == [] do
        for {key, ok?} <- [
              id: is_binary(i.id),
              state: i.state in @states,
              # The engine's 0 for a container that has not exited is no exit code.
              exit_code:
                if(i.state in [:created, :running, :paused],
                  do: is_nil(i.exit_code),
                  else: is_integer(i.exit_code)
                ),
              started_at: is_nil(i.started_at) or is_binary(i.started_at),
              restart_count: is_integer(i.restart_count) and i.restart_count >= 0,
              health: i.health in [:none, :starting, :healthy, :unhealthy],
              health_failing_streak: is_integer(i.health_failing_streak),
              image: is_nil(i.image) or is_binary(i.image),
              image_id: is_nil(i.image_id) or is_binary(i.image_id),
              labels: is_map(i.labels),
              address: is_nil(i.address) or is_binary(i.address),
              process: is_nil(i.process) or is_pid(i.process),
              token?: is_boolean(i.token?),
              grace: is_nil(i.grace) or (is_integer(i.grace) and i.grace >= 0)
            ],
            not ok?,
            do: {:instance, key}
      else
        []
      end
  end

  # What one part of an observation rules out in another, each as the name
  # of the rule broken.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp rules(%Resource{spec: spec} = resource, o) do
    profile = Vagus.App.Profile.of(spec)
    there? = o.instance != :absent
    up? = there? and o.instance.state in @running
    container? = profile.container_name(resource.name) == "app_" <> resource.name
    native? = profile.container_name(resource.name) == nil
    asked? = is_binary(o.image) and (not there? or resource.deleting?)
    http? = match?(%{kind: {:http, _path}}, profile.readiness(spec))
    recorded = resource.status[:pull]

    for {rule, ok?} <- [
          leftover_only_beside_an_own_container_that_does_not_run:
            o.leftover == :absent or (container? and not up?),
          image_only_of_a_manifest_with_one: container? or o.image == nil,
          image_asked_after_only_when_it_decides: asked? or o.image_present?,
          no_token_only_without_one: profile.token() == :none == (o.token == :none),
          current_only_of_an_instance_with_a_token:
            o.token != :current or (there? and o.instance.token?),
          native_instance: not (native? and there?) or native?(o.instance),
          waits_only_before_its_instance: o.waiting_on == [] or not there?,
          answer_only_of_a_running_http_app:
            o.ready == :none or (http? and there? and o.instance.state == :running),
          probe_only_of_a_watched_app_when_due:
            o.probe == :none or
              (o.probes? and
                 Vagus.App.Readiness.probe_due?(
                   Map.merge(View.blank().probe, resource.status[:probe] || %{}),
                   o.now
                 )),
          probes_only_of_the_run_that_was_ready:
            not o.probes? or
              (there? and
                 match?(
                   %{ready?: true, id: id, started_at: at}
                   when id == o.instance.id and at == o.instance.started_at,
                   resource.status[:instance]
                 )),
          data_only_of_an_app_being_deleted: not o.data? or resource.deleting?,
          stale_pull_only_of_another_image_asked_for:
            o.stale_pull == nil or
              (match?(%{image: asked} when is_binary(asked), recorded) and
                 recorded.image == o.stale_pull and o.stale_pull != o.image),
          pull_only_of_an_image: o.pull == :idle or is_binary(o.image)
        ],
        not ok?,
        do: rule
  end

  defp native?(instance) do
    match?(%{state: :running, address: nil, image: nil, token?: false, grace: nil}, instance) and
      is_pid(instance.process)
  end

  @clauses [
    :mismatch_deleted,
    :name_mismatch,
    :revoke_stale_token,
    :restore_token_raised,
    :raised,
    :stop_leftover,
    :remove_leftover,
    :await_removal,
    :cancel_stale_pull,
    :cancel_pull,
    :revoke_token_first,
    :stop,
    :remove,
    :revoke_token,
    :remove_image,
    :remove_data,
    :deleted,
    :not_wanted,
    :restore_token,
    :succeeded_before,
    :failed_before,
    :retry_pause,
    :crash_loop_spent,
    :crash_loop,
    :succeeded,
    :crashed,
    :budget_spent,
    :remove_crashed,
    :gone,
    :unhealthy,
    :await_api,
    :back_off,
    :await_wave,
    :no_builder,
    :pulling,
    :pull_refused,
    :pull_pause,
    :request_pull,
    :start_process,
    :create,
    :await_token,
    :no_token,
    :put_token,
    :start,
    :readiness_timeout,
    :await_readiness,
    :await_gate,
    :ready
  ]

  @doc "The clauses of `Vagus.App.Controller.Reconcile.decide/1`, each by a name, in its order."
  def clauses, do: @clauses

  @doc """
  Which clause of the decision a return came from, told from the return
  and, where two clauses return the same, from the fact that parts them.
  A return no clause is known to give raises: a clause added to the
  decision is to be named here.

  Reasons alone do not tell: `:deleted`, `:removing_leftover`, `:removing`,
  `:cancelling_pull`, `:revoking_token`, `:indexing_token`, `:succeeded`,
  `:crashed`, `:crash_loop`, `:pulling`, `:starting` and `:unhealthy` are
  each the reason of two clauses or more, and a failure's cause is the
  reason of whichever clause reports it.
  """
  def clause(_resource, {:unavailable, _reason}, _returned), do: :unavailable
  def clause(_resource, _observation, {:no_verdict, []}), do: :released

  def clause(resource, observation, {verdict, effects}) do
    v = View.view(resource, observation)
    reason = elem(verdict.conditions.ready, 1)

    action =
      Enum.find_value(effects, fn effect -> match?({:action, _, _}, effect) && elem(effect, 1) end)

    later? = Enum.any?(effects, &match?({:requeue_after, _ms}, &1))

    kind =
      case {verdict.conditions.ready, verdict.conditions.progressing, verdict.conditions.failed} do
        {{true, _}, {false, _}, {false, _}} -> :ready
        {{false, _}, {true, _}, {false, _}} -> :progressing
        {{false, _}, {false, _}, {true, _}} -> :failed
        {{false, _}, {false, _}, {false, _}} -> :idle
      end

    named(kind, reason, verdict.status.state, action, later?, v) ||
      raise "no clause is known to return #{inspect({kind, reason, verdict.status.state, action})}"
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp named(kind, reason, state, action, later?, v) do
    case {kind, reason, state, action} do
      {:idle, :deleted, :deleting, nil} ->
        if(v.mismatch?, do: :mismatch_deleted, else: :deleted)

      {:failed, :name_mismatch, :failed, nil} ->
        :name_mismatch

      {:progressing, :removing_leftover, :stopping, :stop_leftover} ->
        :stop_leftover

      {:progressing, :removing_leftover, :stopping, :remove_leftover} ->
        :remove_leftover

      {:progressing, :removing, :stopping, nil} ->
        :await_removal

      {:progressing, :cancelling_pull, :pulling, :cancel_pull} ->
        :cancel_stale_pull

      {:progressing, :cancelling_pull, :stopping, :cancel_pull} ->
        :cancel_pull

      {:progressing, :revoking_token, :starting, :remove_token} ->
        :revoke_stale_token

      {:progressing, :revoking_token, :stopping, :remove_token} ->
        revoking(v)

      {:progressing, :stopping, :stopping, stop} when stop in [:stop, :stop_process] ->
        :stop

      {:progressing, :removing, :stopping, :remove} ->
        :remove

      {:progressing, :removing_image, :deleting, :remove_image} ->
        :remove_image

      {:progressing, :removing_data, :deleting, :remove_data} ->
        :remove_data

      {:idle, stopped, :stopped, nil} when stopped in [:stopped, :held] ->
        :not_wanted

      {:progressing, :indexing_token, :starting, :put_token} ->
        restoring(v)

      {:idle, :succeeded, :succeeded, nil} ->
        if(v.succeeded?, do: :succeeded_before, else: :succeeded)

      {:failed, _cause, :failed, nil} when not later? ->
        failed_clause(reason, v)

      {:failed, :readiness_timeout, :failed, nil} ->
        :readiness_timeout

      {:progressing, :crash_loop, :stopping, stop} when stop in [:stop, :stop_process] ->
        :crash_loop

      {:progressing, :crashed, :restarting, :remove} ->
        :remove_crashed

      {:progressing, :crashed, :restarting, nil} ->
        :gone

      {:progressing, :unhealthy, :restarting, stop} when stop in [:stop, :stop_process] ->
        :unhealthy

      {:progressing, :waiting_for_api, :waiting, nil} ->
        :await_api

      {:progressing, :backing_off, :restarting, nil} ->
        :back_off

      {:progressing, :waiting_for_wave, :waiting, nil} ->
        :await_wave

      {:progressing, :pulling, :pulling, nil} ->
        :pulling

      {:progressing, _cause, :pulling, nil} ->
        :pull_pause

      {:progressing, :pulling, :pulling, :request_pull} ->
        :request_pull

      {:progressing, :starting, :starting, :start_process} ->
        :start_process

      {:progressing, :creating, :creating, :create} ->
        :create

      {:progressing, :starting, :starting, :start} ->
        :start

      {:progressing, _cause, :starting, nil} when later? and v.retry_in > 0 ->
        :retry_pause

      {:progressing, :waiting_for_token, :starting, nil} ->
        :await_token

      {:progressing, :waiting_for_gate, :starting, nil} ->
        :await_gate

      {:progressing, waiting, :starting, nil} when waiting == v.waiting and waiting != nil ->
        :await_readiness

      {:ready, :ready, :ready, nil} ->
        :ready

      _unknown ->
        nil
    end
  end

  @doc """
  What is wrong with the status and the action a return carries, for the
  clause it came from: what every pass must keep of the instance and of its
  own records, and what each clause exists to write or clear. Nothing, for
  a return as the decision makes them.
  """
  def status_problems(_resource, {:unavailable, _reason}, {verdict, effects}),
    do:
      for(
        {rule, false} <- [nothing_written: verdict.status == %{}, no_effect: effects == []],
        do: rule
      )

  def status_problems(_resource, _observation, {:no_verdict, effects}),
    do: for({rule, false} <- [no_effect: effects == []], do: rule)

  # One list on purpose: each rule is a line, and reads beside the others.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def status_problems(resource, o, {verdict, effects} = returned) do
    clause = clause(resource, o, returned)
    v = View.view(resource, o)
    st = verdict.status
    inst = if o.instance == :absent, do: nil, else: o.instance
    id = inst && inst.id
    up? = inst != nil and inst.state in @running
    generation = resource.generation
    reason = elem(verdict.conditions.ready, 1)
    args = Enum.find_value(effects, %{}, &(match?({:action, _, _}, &1) && elem(&1, 2)))
    action = Enum.find_value(effects, &(match?({:action, _, _}, &1) && elem(&1, 1)))
    stopping? = clause in [:stop, :remove, :remove_crashed, :unhealthy, :crash_loop]
    launching? = clause in [:start_process, :create, :start]
    counted? = clause in [:remove_crashed, :unhealthy, :gone]
    given_up? = clause in [:crashed, :budget_spent, :crash_loop_spent, :pull_refused]
    # The one pass that judges nothing of an instance that is gone.
    kept? = clause == :revoke_stale_token and inst == nil

    for {rule, ok?} <- [
          every_key: Enum.sort(Map.keys(st)) == Enum.sort([:state | Map.keys(View.blank())]),
          instance_is_the_one_observed:
            if(inst,
              do:
                match?(%{id: ^id, running?: ^up?}, st.instance) and
                  Enum.sort(Map.keys(st.instance)) ==
                    Enum.sort(
                      [:id, :address, :process, :running?, :since, :ready?] ++
                        [:restart_count, :started_at]
                    ),
              else: st.instance == if(kept?, do: v.known)
            ),
          since_only_while_it_runs:
            kept? or st.instance == nil or st.instance.since != nil == up?,
          ready_recorded_only_of_a_running_instance:
            kept? or not match?(%{ready?: true}, st.instance) or up?,
          ready_since_only_while_ready: match?(%Stamp{}, st.ready_since) == (clause == :ready),
          ready_instance: clause != :ready or match?(%{ready?: true}, st.instance),
          ready_forgets: clause != :ready or (st.failure == nil and st.pull == nil),
          waits_on_what_it_observed:
            st.waiting_on == if(clause == :await_wave, do: o.waiting_on, else: []),
          wave_since_when_waiting: clause != :await_wave or match?(%Stamp{}, st.wave_since),
          wave_since_only_while_waited_on: o.waiting_on != [] or st.wave_since == nil,
          restart_required_is_drift_under_a_running_instance:
            st.restart_required ==
              (up? and st.made_for != nil and st.made_for.fingerprint != v.target.fingerprint),
          expected_exit_is_of_this_instance:
            if(kept?,
              do: st.expected_exit == v.st.expected_exit,
              else: st.expected_exit in [nil, id]
            ),
          stale_row_only: clause != :revoke_stale_token or o.token == :other,
          recreate_is_of_this_instance: st.recreate in [nil, id],
          exit_expected_of_what_is_taken_away:
            not stopping? or (id != nil and st.expected_exit == id),
          made_anew:
            clause != :crash_loop or
              (st.recreate == id and
                 match?(%{seen: [], actions: [at | _]} when at == o.now, st.engine_restarts)),
          made_for_what_is_wanted:
            not launching? or
              (st.made_for == v.target and st.expected_exit == nil and st.recreate == nil),
          made_for_only_of_an_instance_or_a_count:
            clause != :not_wanted or inst != nil or st.made_for == nil,
          failure_is_of_this_generation: st.failure == nil or st.failure.generation == generation,
          success_is_of_this_generation: st.succeeded in [nil, generation],
          succeeded_recorded:
            clause not in [:succeeded, :succeeded_before] or st.succeeded == generation,
          given_up_with_its_cause:
            not given_up? or
              match?(
                %{class: :permanent, cause: ^reason, generation: ^generation, count: 1, at: at}
                when at == o.now,
                st.failure
              ),
          failed_with_its_cause:
            clause not in [:failed_before, :raised] or
              match?(%{class: :permanent, cause: ^reason}, st.failure),
          paused_with_its_cause:
            clause != :retry_pause or match?(%{class: :transient, cause: ^reason}, st.failure),
          attempt_counted:
            not counted? or
              st.restarts == %{attempts: v.restarts.attempts + 1, last: o.now},
          attempts_only_counted_by_a_crash:
            counted? or clause in [:ready, :not_wanted] or st.restarts == v.restarts,
          gone_instance_forgotten: clause != :gone or st.instance == nil,
          not_wanted_forgets:
            clause != :not_wanted or
              Map.take(st, [:failure, :succeeded, :restarts, :probe, :pull, :wave_since]) ==
                Map.take(View.blank(), [
                  :failure,
                  :succeeded,
                  :restarts,
                  :probe,
                  :pull,
                  :wave_since
                ]),
          pull_cancelled: clause != :cancel_pull or st.pull == nil,
          pull_asked_for:
            clause != :request_pull or
              (match?(%{image: image, generation: ^generation} when image == o.image, st.pull) and
                 args.image == o.image),
          stale_pull_named: clause != :cancel_stale_pull or args.image == o.stale_pull,
          stop_with_the_grace_observed:
            clause not in [:stop, :unhealthy, :crash_loop] or args.grace == inst.grace,
          token_of_this_instance:
            clause not in [:put_token, :restore_token, :restore_token_raised] or
              args.instance == id,
          acts_on_the_instance_observed:
            action not in [:start, :stop, :stop_process, :remove] or
              (id != nil and args.instance == id),
          decided_for_this_generation: args == %{} or args.generation == generation
        ],
        not ok?,
        do: rule
  end

  # Every clause that reports Failed and no time to look again. One that
  # was Failed before the pass comes first among them in the decision.
  defp revoking(%{token: :other}), do: :revoke_stale_token
  defp revoking(%{deleting?: true}), do: :revoke_token_first
  defp revoking(_v), do: :revoke_token

  defp restoring(%{raised?: true}), do: :restore_token_raised
  defp restoring(%{running?: true}), do: :restore_token
  defp restoring(_v), do: :put_token

  defp failed_clause(_reason, %{raised?: true}), do: :raised
  defp failed_clause(_reason, %{failed?: true}), do: :failed_before
  defp failed_clause(:crash_loop, _v), do: :crash_loop_spent
  defp failed_clause(:crashed, _v), do: :crashed
  defp failed_clause(:restart_budget_exhausted, _v), do: :budget_spent
  defp failed_clause(:no_container_builder, _v), do: :no_builder
  defp failed_clause(:no_token, _v), do: :no_token
  defp failed_clause(cause, %{pull_failure: %{cause: cause}}), do: :pull_refused
  defp failed_clause(_reason, _v), do: nil

  # Two clauses that can both hold, in the order the decision has them: each
  # row's outcome is the other clause's if the two change places.
  #
  # The neighbours that have no row here cannot both hold. One fact with one
  # value: a leftover that runs or is stopped; a pull that is in flight,
  # refused, or paused; a token there is none of to put, or one to put; a
  # row in the table that is another token's, or none. An
  # instance that runs and one that does not: stop and remove; the crash
  # loop and the run that succeeded; the instance gone and the unhealthy
  # one; unhealthy and waiting for the API; a start and a readiness
  # deadline, which is counted only while the instance runs. A permanent
  # failure and the pause of a transient one. A policy that never restarts
  # and a budget that is spent. No image to make it from and an image to
  # pull; an image to pull and a native app; no instance and an instance
  # without a token. And two that an earlier clause has taken apart: a
  # deleting app's token went before its image is looked at, and an app
  # that is not to run was stopped before its token could be missed.
  defp order do
    held = %{pull: pulled(image: "image:0")}
    paused = failure(class: :transient, cause: :engine_error, at: ago(0))

    [
      {"order: a leftover goes before the app's own container that is being removed is waited for",
       app(), obs(leftover: :stopped, instance: inst(:removing)),
       {:progressing, :removing_leftover, :stopping, :stopped}, action(:remove_leftover), %{}},
      {"order: a container being removed is waited for before a stale pull is cancelled",
       app(@container, %{}, status: held), obs(instance: inst(:removing), stale_pull: "image:0"),
       {:progressing, :removing, :stopping, :stopped}, later(1_000), %{pull: held.pull}},
      {"order: and before the pull of an app that is not to run is cancelled",
       app(@container, %{run: false}), obs(instance: inst(:removing), pull: {:pulling, true}),
       {:progressing, :removing, :stopping, :stopped}, later(1_000), %{}},
      {"order: a pull of an image moved on from is cancelled before the one of the image wanted",
       app(@container, %{run: false}, status: held),
       obs(image_present?: false, pull: {:pulling, true}, stale_pull: "image:0"),
       {:progressing, :cancelling_pull, :pulling, :stopped},
       action(:cancel_pull, %{image: "image:0"}), %{pull: held.pull}},
      {"order: deleting, the pull is cancelled before the token of the running instance goes",
       app(@container, %{}, status: running(), deleting?: true),
       obs(instance: inst(), token: :current, pull: {:pulling, true}),
       {:progressing, :cancelling_pull, :stopping, :startup},
       action(:cancel_pull, %{image: "image:1"}), %{pull: nil}},
      {"order: a token row that is nobody's goes before a leftover does", app(),
       obs(leftover: :running, token: :other),
       {:progressing, :revoking_token, :starting, :stopped}, action(:remove_token), %{}},
      {"order: and before the pull of an app that is not to run is cancelled, a token left behind",
       app(@container, %{run: false}),
       obs(image_present?: false, pull: {:pulling, true}, token: :other),
       {:progressing, :revoking_token, :stopping, :stopped}, action(:remove_token), %{}},
      {"order: deleting, the container goes before the image and the data",
       app(@container, %{}, status: running(expected_exit: "c1"), deleting?: true),
       obs(instance: inst(:exited), data?: true), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{expected_exit: "c1", cleaned: []}},
      {"order: deleting, the image goes before the data", app(@container, %{}, deleting?: true),
       obs(data?: true), {:progressing, :removing_image, :deleting, :stopped},
       action(:remove_image, %{image: "image:1"}), %{cleaned: []}},
      {"order: not to run comes before having succeeded, and forgets it",
       once(%{run: false}, status: %{succeeded: 3}), obs(), {:idle, :stopped, :stopped, :stopped},
       [], %{succeeded: nil}},
      {"order: not to run comes before having failed, and forgets it",
       app(@container, %{run: false}, status: %{failure: failure()}), obs(),
       {:idle, :stopped, :stopped, :stopped}, [], %{failure: nil}},
      {"order: a token the table lacks is put back before the app is called succeeded",
       once(%{}, status: running(succeeded: 3)), obs(instance: inst()),
       {:progressing, :indexing_token, :starting, :startup},
       action(:put_token, %{instance: "c1"}), %{succeeded: 3}},
      {"order: having succeeded comes before a failure recorded for the same generation",
       once(%{}, status: %{succeeded: 3, failure: failure()}), obs(),
       {:idle, :succeeded, :succeeded, :stopped}, [], %{succeeded: 3}},
      {"order: the pause after a failed start comes before a crash of the instance is judged",
       watched(%{}, status: running(failure: paused)), obs(instance: inst(:exited)),
       {:progressing, :engine_error, :starting, :stopped}, later(1_000),
       %{restarts: View.blank().restarts, expected_exit: nil}},
      {"order: and before a crash loop is",
       core(%{},
         status:
           running(
             failure: paused,
             engine_restarts: %{seen: [ago(3_000), ago(2_000)], actions: []}
           )
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:progressing, :engine_error, :starting, :startup}, later(1_000),
       %{engine_restarts: %{seen: [now(), ago(3_000), ago(2_000)], actions: []}}},
      {"order: the API not accepting comes before a back-off is waited out",
       watched(%{}, status: %{restarts: restarts(1, 4_000)}), obs(api?: false),
       {:progressing, :waiting_for_api, :waiting, :stopped}, later(2_000),
       %{restarts: restarts(1, 4_000)}},
      {"order: a back-off comes before an earlier wave is waited for",
       watched(%{}, status: %{restarts: restarts(1, 4_000)}), obs(waiting_on: ["core_mosquitto"]),
       {:progressing, :backing_off, :restarting, :stopped}, later(6_000),
       %{wave_since: nil, waiting_on: []}},
      {"order: and before the image is asked for",
       watched(%{}, status: %{restarts: restarts(1, 4_000)}), obs(image_present?: false),
       {:progressing, :backing_off, :restarting, :stopped}, later(6_000), %{pull: nil}},
      {"order: an earlier wave is waited for before Core is found to have no builder", core(),
       obs(image: nil, waiting_on: ["core_mosquitto"]),
       {:progressing, :waiting_for_wave, :waiting, :stopped}, later(120_000),
       %{wave_since: now(), waiting_on: ["core_mosquitto"]}},
      {"order: and before the image is asked for, too", app(),
       obs(image_present?: false, waiting_on: ["core_mosquitto"]),
       {:progressing, :waiting_for_wave, :waiting, :stopped}, later(120_000),
       %{pull: nil, wave_since: now()}},
      {"order: a running instance's token is put back before its readiness is waited for",
       app(@container, %{}, status: running()), obs(instance: inst(:running, health: :starting)),
       {:progressing, :indexing_token, :starting, :startup},
       action(:put_token, %{instance: "c1"}), %{}},
      {"order: an instance that is not ready is waited for before its gate is",
       app(@container, %{}, status: running()),
       obs(instance: inst(:running, health: :starting), token: :current, gates: [:dns_ready]),
       {:progressing, :health_starting, :starting, :startup}, [], %{}}
    ]
  end

  # One row for each guard of a fact the decision turns on: what the fact
  # is when the guard does not hold.
  # An action that raised or whose call exited, as the pass after it
  # is handed it.
  defp raised do
    crash = {:crashed, RuntimeError}

    gave_up = fn action ->
      failure(action: action, cause: :crashed, detail: crash, at: ago(0))
    end

    [
      {"a start that raised: Failed, recorded, and not asked for again",
       app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created), token: :current, failed_action: failed(:start, crash)),
       {:failed, :crashed, :failed, :error}, [], %{failure: gave_up.(:start)}},
      {"a remove that raised: Failed too, though the container is still to go",
       app(@container, %{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited), failed_action: failed(:remove, crash)),
       {:failed, :crashed, :failed, :error}, [], %{failure: gave_up.(:remove)}},
      {"and it stays Failed in the passes after, with nothing done",
       app(@container, %{run: false},
         status: running(expected_exit: "c1", failure: gave_up.(:remove))
       ), obs(instance: inst(:exited)), {:failed, :crashed, :failed, :error}, [],
       %{failure: gave_up.(:remove)}},
      {"a leftover's stop that raised keeps the app from being made beside it", app(),
       obs(leftover: :running, failed_action: failed(:stop_leftover, crash)),
       {:failed, :crashed, :failed, :error}, [], %{}},
      {"a stop that raised left the instance running: its token is put back all the same",
       app(@container, %{run: false}, status: running(failure: gave_up.(:stop))),
       obs(instance: inst()), {:progressing, :indexing_token, :starting, :startup},
       action(:put_token, %{instance: "c1"}), %{failure: gave_up.(:stop)}},
      {"and with its token there, it is Failed as the stop left it",
       app(@container, %{run: false}, status: running(failure: gave_up.(:stop))),
       obs(instance: inst(), token: :current), {:failed, :crashed, :failed, :error}, [],
       %{failure: gave_up.(:stop)}},
      {"a token put that raised is not asked for again, though the instance runs without one",
       app(@container, %{}, status: running(failure: gave_up.(:put_token))),
       obs(instance: inst()), {:failed, :crashed, :failed, :error}, [],
       %{failure: gave_up.(:put_token)}},
      {"order: an app named otherwise than its slug has nothing put, raised action or not",
       %{app(@container, %{}, status: running(failure: gave_up.(:stop))) | name: "another"},
       obs(instance: inst()), {:failed, :name_mismatch, :failed, :error}, [], %{}},
      {"order: nor is a token row that is nobody's taken from it", %{app() | name: "another"},
       obs(token: :other), {:failed, :name_mismatch, :failed, :error}, [], %{}},
      {"order: a token row that is nobody's goes before an app whose action raised is left Failed",
       app(@container, %{}, status: %{made_for: :this, failure: gave_up.(:start)}),
       obs(instance: inst(:created), token: :other),
       {:progressing, :revoking_token, :starting, :stopped}, action(:remove_token),
       %{failure: gave_up.(:start)}},
      {"the removal of such a row that raised is not asked for again", app(),
       obs(token: :other, failed_action: failed(:remove_token, crash)),
       {:failed, :crashed, :failed, :error}, [], %{failure: gave_up.(:remove_token)}},
      {"a gate opened for the spec before a write that kept the instance is closed",
       gated(app(@container, %{}, status: running()), "c1", true, 2),
       obs(instance: inst(), token: :current, gates: [:dns_ready]),
       {:progressing, :waiting_for_gate, :starting, :startup}, [], %{}},
      {"deleting: a remove that raised is asked for again, there being no other way on",
       app(@container, %{}, status: running(expected_exit: "c1"), deleting?: true),
       obs(instance: inst(:exited), failed_action: failed(:remove, crash)),
       {:progressing, :removing, :stopping, :stopped}, action(:remove, %{instance: "c1"}), %{}},
      {"an app that crashed and is not restarted is no action that raised: stopped when told to",
       app(@container, %{run: false},
         status: running(failure: failure(action: :run, cause: :crashed, generation: 3))
       ), obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove, %{instance: "c1"}), %{}},
      {"a token removal whose call exited, the table being replaced: asked for again",
       app(@container, %{run: false}),
       obs(token: :other, failed_action: failed(:remove_token, {:exit, :noproc})),
       {:progressing, :revoking_token, :stopping, :stopped}, action(:remove_token),
       %{
         failure:
           failure(
             action: :remove_token,
             class: :transient,
             cause: :call_exited,
             detail: {:exit, :noproc},
             at: ago(0)
           )
       }},
      {"a start whose call timed out is tried again after its pause, like any failure for now",
       app(@container, %{}, status: %{made_for: :this}),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:exit, :timeout})
       ), {:progressing, :call_exited, :starting, :stopped}, later(1_000), %{}}
    ]
  end

  defp guards do
    ready = running(instance: seen(ready?: true), ready_since: ago(30_000))
    refused = {:failed, {:status, 404, "no such image"}, ago(50)}
    transient = failure(class: :transient, cause: :engine_error, detail: {:status, 500, "x"})

    [
      {"guard: a new start with the same restart count is no restart by the engine",
       core(%{}, status: ready),
       obs(instance: inst(:running, started_at: "started-2"), token: :current, image: nil),
       {:progressing, :not_answering, :starting, :startup}, later(5_000),
       %{engine_restarts: %{seen: [], actions: []}}},
      {"guard: a failure of another action than the one recorded is counted from one",
       app(@container, %{},
         status: %{made_for: :this, failure: Map.merge(transient, %{action: :create, count: 3})}
       ),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:status, 500, "x"})
       ), {:progressing, :engine_error, :starting, :stopped}, later(1_000),
       %{failure: Map.merge(transient, %{action: :start, count: 1, at: ago(0)})}},
      {"guard: a failure recorded for an earlier generation is not counted on",
       app(@container, %{},
         status: %{made_for: :this, failure: Map.merge(transient, %{generation: 2, count: 3})}
       ),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:status, 500, "x"})
       ), {:progressing, :engine_error, :starting, :stopped}, later(1_000),
       %{failure: Map.merge(transient, %{count: 1, at: ago(0)})}},
      {"guard: the pause after a failed action stops doubling at a minute",
       app(@container, %{},
         status: %{made_for: :this, failure: Map.merge(transient, %{count: 9, at: ago(99)})}
       ),
       obs(
         instance: inst(:created),
         token: :current,
         failed_action: failed(:start, {:status, 500, "x"})
       ), {:progressing, :engine_error, :starting, :stopped}, later(60_000),
       %{failure: Map.merge(transient, %{count: 10, at: ago(0)})}},
      {"guard: a failure of an action that takes something away holds no start back", app(),
       obs(failed_action: failed(:remove_leftover, {:status, 500, "x"})),
       {:progressing, :creating, :creating, :stopped}, action(:create),
       %{failure: Map.merge(transient, %{action: :remove_leftover, at: ago(0)})}},
      {"guard: an instance that was never seen running and is gone is no crash",
       watched(%{}, status: %{instance: seen(running?: false, since: nil), made_for: :this}),
       obs(), {:progressing, :creating, :creating, :stopped}, action(:create),
       %{restarts: View.blank().restarts, instance: nil}},
      {"guard: an expected exit of another instance does not excuse this one's going",
       native(%{}, status: running(expected_exit: "c0")), obs(token: :none, image: nil),
       {:progressing, :crashed, :restarting, :stopped}, later(0),
       %{restarts: %{attempts: 1, last: now()}, expected_exit: nil}},
      {"guard: Ready, a probe and the reset both to come: looked at again for the probe, the sooner",
       watched(%{},
         status:
           Map.merge(ready, %{
             restarts: restarts(2),
             ready_since: ago(400_000),
             probe: %{misses: 0, at: ago(100_000)}
           })
       ), obs(instance: inst(), token: :current, probes?: true),
       {:ready, :ready, :ready, :started}, later(20_000), %{restarts: restarts(2)}},
      {"guard: Ready, the reset sooner than the probe: looked at again for the reset",
       watched(%{},
         status:
           Map.merge(ready, %{
             restarts: restarts(2),
             ready_since: ago(550_000),
             probe: %{misses: 0, at: ago(10_000)}
           })
       ), obs(instance: inst(), token: :current, probes?: true),
       {:ready, :ready, :ready, :started}, later(50_000), %{restarts: restarts(2)}},
      {"guard: an instance no longer Ready stops counting towards the reset",
       watched(%{}, status: Map.merge(ready, %{restarts: restarts(2)})),
       obs(instance: inst(:running, health: :starting), token: :current),
       {:progressing, :health_starting, :starting, :startup}, [],
       %{ready_since: nil, restarts: restarts(2)}},
      {"guard: a pull recorded for another image is not this image's: its refusal is not judged",
       app(@container, %{},
         status: %{pull: pulled(image: "image:0", failures: 3, seen: ago(50))}
       ), obs(image_present?: false, pull: refused), {:progressing, :pulling, :pulling, :stopped},
       action(:request_pull, %{image: "image:1", priority: 50}), %{pull: pulled(after: ago(50))}},
      {"guard: making anew is of the instance it was decided for, not of another",
       core(%{}, status: running(recreate: "c0")),
       obs(instance: inst(:exited), token: :current, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start, %{instance: "c1"}),
       %{recreate: nil}},
      {"guard: a success recorded for an earlier generation is no success of this one",
       once(%{}, status: %{succeeded: 2}), obs(), {:progressing, :creating, :creating, :stopped},
       action(:create), %{succeeded: nil}},
      {"guard: the misses of an instance that has ended are forgotten",
       watched(%{}, status: running(probe: %{misses: 1, at: ago(5)})),
       obs(instance: inst(:exited)), {:progressing, :crashed, :restarting, :stopped},
       action(:remove, %{instance: "c1"}), %{probe: View.blank().probe}}
    ]
  end

  @doc """
  Rows the decision is held to and no observation reaches today: Core with
  an image. `Vagus.App.Controller.Observe` has none for it until Core's
  container can be made here, so making Core anew after a crash loop, the
  bound on doing that, and leaving its image at a delete are decided and
  cannot happen.
  """
  def unreachable do
    [
      {"Core made anew long enough ago: those times are forgotten, and it is made anew again",
       core(%{},
         status:
           running(
             engine_restarts: %{
               seen: [ago(2), ago(1), ago(0)],
               actions: for(n <- 1..10, do: ago(1_800_000 + n))
             }
           )
       ), obs(instance: inst(:running, grace: 260), token: :current),
       {:progressing, :crash_loop, :stopping, :startup},
       action(:stop, %{grace: 260, instance: "c1"}),
       %{engine_restarts: %{seen: [], actions: [now()]}}},
      {"deleting: Core's image stays", core(%{}, deleting?: true), obs(image: "image:1"),
       {:idle, :deleted, :deleting, :stopped}, [{:remove_finalizer, :app, "homeassistant", :app}],
       %{}},
      {"Core in a crash loop, with a container to make it from: made anew",
       core(%{},
         status: running(engine_restarts: %{seen: [ago(2_000), ago(1_000)], actions: []})
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2", grace: 260),
         token: :current
       ), {:progressing, :crash_loop, :stopping, :startup},
       action(:stop, %{grace: 260, instance: "c1"}),
       %{expected_exit: "c1", recreate: "c1", engine_restarts: %{seen: [], actions: [now()]}}},
      {"Core in a crash loop too often: Failed",
       core(%{},
         status:
           running(
             engine_restarts: %{
               seen: [ago(2), ago(1), ago(0)],
               actions: for(n <- 1..10, do: ago(n))
             }
           )
       ), obs(instance: inst(), token: :current), {:failed, :crash_loop, :failed, :error}, [],
       %{}},
      {"Core being made anew: stopped, then removed although it is kept",
       core(%{}, status: running(expected_exit: "c1", recreate: "c1")),
       obs(instance: inst(:exited), token: :current),
       {:progressing, :removing, :stopping, :stopped}, action(:remove, %{instance: "c1"}), %{}}
    ]
  end

  defp gated(app, id, open? \\ true, generation \\ 3) do
    Resource.put_condition(
      app,
      Resource.condition(:dns_ready, open?, :registered, generation, id)
    )
  end
end
