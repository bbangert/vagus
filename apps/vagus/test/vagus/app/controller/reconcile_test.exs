defmodule Vagus.App.Controller.ReconcileTest.Rows do
  @moduledoc false

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
        exit_code: if(state in [:exited, :dead], do: 1),
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

  def restarts(attempts, last_ago \\ 1_000, sequences \\ nil) do
    %{attempts: attempts, last: ago(last_ago), sequences: sequences || [ago(last_ago)]}
  end

  def pulled(over \\ %{}) do
    Map.merge(
      %{image: "image:1", generation: 3, failures: 0, seen: nil, after: nil},
      Map.new(over)
    )
  end

  def action(name, args \\ %{}), do: [{:action, name, args}]
  def later(ms), do: [{:requeue_after, ms}]
  def failed(name, reason), do: %{name: name, reason: reason, at: ago(0)}

  @doc "`{name, resource, observation, {kind, reason, state, wire}, effects, status}`"
  def all do
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
      {"a stop takes the token away before the container",
       app(@container, %{run: false}, status: running()), up,
       {:progressing, :revoking_token, :stopping, :startup}, action(:remove_token), %{}},
      {"a token of an instance that is gone is taken away too", app(@container, %{run: false}),
       obs(token: :other), {:progressing, :revoking_token, :stopping, :stopped},
       action(:remove_token), %{}},
      {"not wanted and running: the exit is expected, then stop",
       app(@container, %{run: false}, status: running()), obs(instance: inst()),
       {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: nil}),
       %{expected_exit: "c1"}},
      {"held and running: stopped the same way",
       app(@container, %{holds: %{"backup" => true}}, status: running()), obs(instance: inst()),
       {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: nil}),
       %{expected_exit: "c1"}},
      {"a restart counter above the instance's: the instance is stopped",
       app(@container, %{restart_counter: 2}, status: running(made_for: %{restart_counter: 1})),
       up, {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: nil}),
       %{expected_exit: "c1"}},
      {"a start counter above a running instance's changes nothing",
       app(@container, %{start_counter: 2},
         status: Map.merge(ready, %{made_for: %{start_counter: 1}})
       ), up, {:ready, :ready, :ready, :started}, [], %{expected_exit: nil}},
      {"an instance whose exit is expected and that still runs is stopped again",
       app(@container, %{}, status: running(expected_exit: "c1")), up,
       {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: nil}), %{}},
      {"Core is stopped with the grace its image asks for",
       core(%{run: false}, status: running()),
       obs(instance: inst(:running, grace: 260), token: :absent),
       {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: 260}), %{}},
      {"a native app is stopped as a process", native(%{run: false}, status: running()),
       obs(instance: inst(:running, token?: false), token: :none, image: nil),
       {:progressing, :stopping, :stopping, :startup}, action(:stop_process, %{grace: nil}),
       %{expected_exit: "c1"}},
      {"stopped by request and still there: removed",
       app(@container, %{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove), %{expected_exit: "c1"}},
      {"an exit that was expected of a wanted app: removed, not counted",
       watched(%{}, status: running(expected_exit: "c1")), obs(instance: inst(:exited)),
       {:progressing, :removing, :stopping, :stopped}, action(:remove),
       %{restarts: View.blank().restarts}},
      {"a stopped instance made for an earlier start counter is replaced",
       app(@container, %{start_counter: 2}, status: running(made_for: %{start_counter: 1})),
       obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove), %{}},
      {"created from a spec that has changed since, and never started: made anew",
       app(@container, %{}, status: %{made_for: %{fingerprint: 0}}),
       obs(instance: inst(:created)), {:progressing, :removing, :stopping, :stopped},
       action(:remove), %{}},
      {"a container that has run and nothing is recorded of: removed, not counted", watched(),
       obs(instance: inst(:exited)), {:progressing, :removing, :stopping, :stopped},
       action(:remove), %{restarts: View.blank().restarts}},
      {"Core stopped by request stays", core(%{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(:exited)), {:idle, :stopped, :stopped, :stopped}, [], %{}},
      {"Core being deleted is removed", core(%{}, status: running(), deleting?: true),
       obs(instance: inst(:exited), image: nil), {:progressing, :removing, :stopping, :stopped},
       action(:remove), %{}},
      {"deleting: the token goes first, while the container still runs",
       app(@container, %{}, status: running(), deleting?: true), up,
       {:progressing, :revoking_token, :stopping, :startup}, action(:remove_token), %{}},
      {"deleting: then the container is stopped",
       app(@container, %{}, status: running(), deleting?: true), obs(instance: inst()),
       {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: nil}),
       %{expected_exit: "c1"}},
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
      {"deleting: Core's image stays", core(%{}, deleting?: true), obs(image: "image:1"),
       {:idle, :deleted, :deleting, :stopped}, [{:remove_finalizer, :app, "homeassistant", :app}],
       %{}},
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
       {:progressing, :starting, :starting, :stopped}, action(:start), %{}},
      {"a stop that timed out is still stopping: no failure, look again",
       app(@container, %{run: false}, status: running(expected_exit: "c1")),
       obs(instance: inst(), failed_action: failed(:stop, {:timeout, :recv})),
       {:progressing, :stopping, :stopping, :startup}, action(:stop, %{grace: nil}),
       %{failure: nil}},
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
      {"a restart count that rose with no new start is no restart", core(%{}, status: ready),
       obs(instance: inst(:running, restart_count: 1), token: :current, image: nil),
       {:ready, :ready, :ready, :started}, [], %{engine_restarts: %{seen: [], actions: []}}},
      {"Core in a crash loop, with a container to make it from: made anew",
       core(%{},
         status: running(engine_restarts: %{seen: [ago(2_000), ago(1_000)], actions: []})
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2", grace: 260),
         token: :current
       ), {:progressing, :crash_loop, :stopping, :startup}, action(:stop, %{grace: 260}),
       %{expected_exit: "c1", recreate: "c1", engine_restarts: %{seen: [], actions: [now()]}}},
      {"Core in a crash loop, and nothing to make it from: Failed",
       core(%{},
         status: running(engine_restarts: %{seen: [ago(2_000), ago(1_000)], actions: []})
       ),
       obs(
         instance: inst(:running, restart_count: 1, started_at: "started-2"),
         token: :current,
         image: nil
       ), {:failed, :crash_loop, :failed, :error}, [], %{}},
      {"Core in a crash loop too often: Failed",
       core(%{},
         status:
           running(
             engine_restarts: %{
               seen: [ago(2), ago(1), ago(0)],
               actions: for(n <- 1..10, do: ago(n))
             }
           )
       ), up, {:failed, :crash_loop, :failed, :error}, [], %{}},
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
      {"Core being made anew: stopped, then removed although it is kept",
       core(%{}, status: running(expected_exit: "c1", recreate: "c1")),
       obs(instance: inst(:exited), token: :current),
       {:progressing, :removing, :stopping, :stopped}, action(:remove), %{}},
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
      {"the runs of the window are spent: Failed",
       watched(%{},
         status:
           running(
             restarts: %{attempts: 0, last: nil, sequences: for(n <- 1..10, do: ago(n * 1_000))}
           )
       ), obs(instance: inst(:exited)), {:failed, :restart_budget_exhausted, :failed, :error}, [],
       %{}},
      {"unhealthy with the budget spent: Failed, and left running",
       watched(%{}, status: running(restarts: restarts(5))),
       obs(instance: inst(:running, health: :unhealthy), token: :current),
       {:failed, :restart_budget_exhausted, :failed, :error}, [], %{}},
      {"a crash: counted, and the dead container removed", watched(%{}, status: running()),
       obs(instance: inst(:exited)), {:progressing, :crashed, :restarting, :stopped},
       action(:remove),
       %{restarts: %{attempts: 1, last: now(), sequences: [now()]}, expected_exit: "c1"}},
      {"a second crash of the run: counted in the same run",
       watched(%{}, status: running(restarts: restarts(1, 20_000))), obs(instance: inst(:exited)),
       {:progressing, :crashed, :restarting, :stopped}, action(:remove),
       %{restarts: %{attempts: 2, last: now(), sequences: [ago(20_000)]}}},
      {"runs older than the window do not count against a new one",
       watched(%{},
         status:
           running(
             restarts: %{
               attempts: 0,
               last: nil,
               sequences: for(n <- 1..10, do: ago(1_800_000 + n))
             }
           )
       ), obs(instance: inst(:exited)), {:progressing, :crashed, :restarting, :stopped},
       action(:remove), %{restarts: %{attempts: 1, last: now(), sequences: [now()]}}},
      {"a native app that ended: counted, nothing to remove", native(%{}, status: running()),
       obs(token: :none, image: nil), {:progressing, :crashed, :restarting, :stopped}, later(0),
       %{restarts: %{attempts: 1, last: now(), sequences: [now()]}, instance: nil}},
      {"unhealthy while running: counted and stopped", watched(%{}, status: ready),
       obs(instance: inst(:running, health: :unhealthy), token: :current),
       {:progressing, :unhealthy, :restarting, :startup}, action(:stop, %{grace: nil}),
       %{restarts: %{attempts: 1, last: now(), sequences: [now()]}, expected_exit: "c1"}},
      {"a second probe unanswered: unhealthy",
       watched(%{}, status: Map.merge(ready, %{probe: %{misses: 1, at: ago(120_000)}})),
       obs(instance: inst(), token: :current, probes?: true, probe: :unhealthy),
       {:progressing, :unhealthy, :restarting, :startup}, action(:stop, %{grace: nil}),
       %{probe: %{misses: 2, at: now()}}},
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
      {"created, the table holding another instance's token: put this one's",
       app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created), token: :other),
       {:progressing, :indexing_token, :starting, :stopped},
       action(:put_token, %{instance: "c1"}), %{}},
      {"running, the table without its token: put back, the container untouched",
       app(@container, %{}, status: ready), obs(instance: inst()),
       {:progressing, :indexing_token, :starting, :startup},
       action(:put_token, %{instance: "c1"}), %{}},
      {"created and its token known: start", app(@container, %{}, status: %{made_for: :this}),
       obs(instance: inst(:created), token: :current),
       {:progressing, :starting, :starting, :stopped}, action(:start), %{}},
      {"Core stopped and wanted: the container is started again, for what is wanted now",
       core(%{restart_counter: 1},
         status: running(expected_exit: "c1", made_for: %{restart_counter: 0})
       ), obs(instance: inst(:exited), token: :current, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start),
       %{expected_exit: nil, made_for: target(core(%{restart_counter: 1}).spec)}},
      {"Core found stopped by something else: started, not counted", core(%{}, status: running()),
       obs(instance: inst(:exited), token: :current, image: nil),
       {:progressing, :starting, :starting, :stopped}, action(:start), %{}},
      {"Core not answering yet: asked again shortly", core(%{}, status: running()),
       obs(instance: inst(), token: :current, ready: :not_ready, image: nil),
       {:progressing, :not_answering, :starting, :startup}, later(5_000), %{}},
      {"Core not answering past its deadline: Failed, and still asked",
       core(%{}, status: running(instance: seen(since: ago(600_000)))),
       obs(instance: inst(), token: :current, ready: :not_ready, image: nil),
       {:failed, :readiness_timeout, :failed, :error}, later(5_000), %{}},
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
       obs(instance: inst(:running, token?: false, address: nil), token: :none, image: nil),
       {:ready, :ready, :ready, :started}, [], %{}},
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
       action(:remove), %{restarts: View.blank().restarts}}
    ]
  end

  defp gated(app, id) do
    Resource.put_condition(app, Resource.condition(:dns_ready, true, :registered, 3, id))
  end
end

defmodule Vagus.App.Controller.ReconcileTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Controller
  alias Vagus.App.Controller.ReconcileTest.Rows
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.{Harness, Stamp, Verdict}
  alias Vagus.Test.AppManifests

  @moduletag :capture_log

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

  for {name, _resource, _observation, _expected, _effects, _status} <- Rows.all() do
    test name do
      {_name, resource, observation, expected, effects, status} =
        Enum.find(Rows.all(), &(elem(&1, 0) == unquote(name)))

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

      assert returned == effects
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
    defp with_status(status, conditions) do
      Enum.reduce(conditions, Harness.resource(:app, "a", %{}, status: status), fn
        {type, value}, app ->
          Resource.put_condition(app, Resource.condition(type, value, :reason, 1))
      end)
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
              count: :rand.uniform(30)
            })
          end),
        succeeded: AppManifests.pick([nil, 2, 3]),
        restarts: %{
          attempts: AppManifests.pick([0, 1, 5, 9]),
          last: stamp(),
          sequences: for(_ <- 1..AppManifests.pick([1, 3, 11]), do: stamp())
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
              failures: :rand.uniform(9),
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
      AppManifests.each(3_000, fn -> {resource(), observation()} end, fn {resource, observation} ->
        row =
          if resource.deleting? and :app not in resource.finalizers,
            do: {resource, observation, :no_verdict},
            else: {resource, observation}

        Harness.assert_verdict_contract(Controller, [row])
      end)
    end
  end
end
