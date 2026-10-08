defmodule Vagus.App.Controller.View do
  @moduledoc """
  Everything `Vagus.App.Controller.Reconcile` decides from, worked out once
  from an App resource and an observation: each fact under a name, and
  `base`, the status the pass writes whatever it decides.

  Pure, like the decision it serves. The instants in it are stamps compared
  with the observation's `now`.
  """

  alias Vagus.Addon.Config
  alias Vagus.App.{Failure, Profile, Readiness}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.Stamp

  # A transient failure of an action or a pull is tried again after this,
  # doubling.
  @retry_ms {1_000, 60_000}
  @readiness_poll_ms 5_000

  # The actions of the start sequence: a failure of one of these holds the
  # sequence back. One of an action that takes an instance away does not,
  # being asked for again by every pass that still sees the instance.
  @start_actions [:request_pull, :create, :put_token, :start, :start_process]

  @pull %{image: nil, generation: nil, failures: 0, seen: nil, after: nil}

  @blank %{
    instance: nil,
    made_for: nil,
    expected_exit: nil,
    recreate: nil,
    failure: nil,
    succeeded: nil,
    restarts: %{attempts: 0, last: nil},
    engine_restarts: %{seen: [], actions: []},
    probe: %{misses: 0, at: nil},
    pull: nil,
    wave_since: nil,
    waiting_on: [],
    ready_since: nil,
    cleaned: [],
    restart_required: false
  }

  @doc "The status of an app nothing has been recorded about."
  @spec blank() :: map()
  def blank, do: @blank

  @doc """
  What of a spec an instance is made from. A running instance made from
  another is reported (`restart_required`) and left; one that was created
  and never started is made anew.
  """
  @spec fingerprint(map()) :: non_neg_integer()
  def fingerprint(spec) do
    :erlang.phash2({
      Map.take(spec, [:lifecycle, :config, :version, :options, :ingress_port]),
      spec |> Map.get(:settings, %{}) |> Map.take([:ports, :protected])
    })
  end

  @doc """
  In four parts, each a map merged into the one before: who the instance
  is, what is carried in status, what is owed to an instance that is to go
  or has ended, and what the start sequence waits for.
  """
  @spec view(Resource.t(), map()) :: map()
  def view(%Resource{} = resource, o) do
    v = resource |> identity(o) |> carried(o)
    v |> Map.merge(going(v, o)) |> Map.merge(ended(v, o)) |> Map.merge(starting(v, o))
  end

  defp identity(%Resource{spec: spec, generation: generation} = resource, o) do
    profile = Profile.of(spec)
    st = Map.merge(@blank, Map.take(resource.status, Map.keys(@blank)))
    inst = if o.instance == :absent, do: nil, else: o.instance
    known = st.instance
    same? = inst != nil and known != nil and known.id == inst.id
    running? = inst != nil and inst.state in [:running, :paused, :restarting]

    target = %{
      restart_counter: spec.restart_counter,
      start_counter: spec.start_counter,
      fingerprint: fingerprint(spec)
    }

    run_once? = match?(%{config: %Config{startup: "once"}}, spec)
    wanted? = Schema.wanted?(spec) and not resource.deleting?

    # A run-once app's container that ran and exited with 0 is its success
    # to see, with or without a record of it.
    done? = run_once? and done?(inst)

    # An instance nothing is recorded about, running or done, was made
    # before this status existed, and is taken as made for what is wanted.
    made_for = st.made_for || if(running? or done?, do: target)
    counters? = made_for != nil and counters(made_for) == counters(target)
    expected? = inst != nil and st.expected_exit == inst.id

    %{
      resource: resource,
      name: resource.name,
      generation: generation,
      now: o.now,
      profile: profile,
      policy: profile.restart_policy(spec),
      st: st,
      inst: inst,
      known: known,
      same?: same?,
      # The same instance in the same run of it: the engine starts a
      # container again under its id, and readiness and probes are of one
      # run.
      same_run?: same? and known.started_at == inst.started_at,
      running?: running?,
      target: target,
      made_for: made_for,
      counters?: counters?,
      expected?: expected?,
      finished?: finished?(wanted?, done?, counters?, expected?),
      # An app is its manifest's slug: the container, the data directory
      # and the token row are all named for one or the other.
      mismatch?: mismatch?(resource),
      api?: o.api?,
      token_pending?: profile.token() == :supervisor,
      deleting?: resource.deleting?,
      wanted?: wanted?,
      held?: Map.get(spec, :holds, %{}) != %{},
      removes?: profile.on_stop() == :remove,
      native?: profile.backend() == Vagus.App.Backend.Native,
      run_once?: run_once?,
      image: o.image
    }
    |> Map.merge(named(inst, st))
  end

  defp named(nil, _st), do: %{id: nil, grace: nil, exit_code: nil, recreate?: false}

  defp named(inst, st) do
    %{
      id: inst.id,
      grace: inst[:grace],
      exit_code: inst.exit_code,
      recreate?: st.recreate == inst.id
    }
  end

  defp finished?(wanted?, done?, counters?, expected?),
    do: wanted? and done? and counters? and not expected?

  defp done?(%{state: state, exit_code: 0}) when state in [:exited, :dead], do: true
  defp done?(_instance), do: false

  defp mismatch?(%Resource{name: name, spec: %{config: %Config{slug: slug}}}), do: slug != name
  defp mismatch?(_core), do: false

  # What status carries from pass to pass, brought up to this one.
  defp carried(%{st: st, inst: inst, known: known, now: now} = v, o) do
    watched? = v.same_run? and v.running?
    restarts = if v.counters? or v.made_for == nil, do: st.restarts, else: @blank.restarts
    engine = engine_restarts(st.engine_restarts, v.policy, inst, known, v.same?, now)
    pull = pull(o.pull, st.pull, o.image, v.generation, now)

    record =
      inst &&
        %{
          id: inst.id,
          address: inst.address,
          process: inst.process,
          running?: v.running?,
          since: if(v.running?, do: (v.same_run? && known.since) || now),
          ready?: watched? and known.ready?,
          restart_count: inst.restart_count,
          started_at: inst.started_at
        }

    # An image that could not be removed, another container using it, is
    # left: learnt from the failure, since the image is there either way.
    cleaned =
      if match?(%{name: :remove_image, reason: {:status, 409, _message}}, o.failed_action),
        do: Enum.uniq([:image | st.cleaned]),
        else: st.cleaned

    base = %{
      st
      | instance: record,
        made_for: v.made_for,
        expected_exit: if(v.expected?, do: st.expected_exit),
        recreate: if(v.recreate?, do: st.recreate),
        failure: failure(st.failure, o.failed_action, v.generation),
        succeeded: if(st.succeeded == v.generation, do: v.generation),
        restarts: restarts,
        engine_restarts: engine,
        probe: probe(st.probe, o.probe, watched?, now),
        pull: if(o.stale_pull, do: st.pull, else: pull.record),
        cleaned: cleaned,
        waiting_on: [],
        restart_required: v.running? and drifted?(v)
    }

    Map.merge(v, %{base: base, record: record, restarts: restarts, engine: engine, pulled: pull})
  end

  defp drifted?(v), do: v.made_for != nil and v.made_for.fingerprint != v.target.fingerprint

  defp going(%{inst: inst, base: base} = v, o) do
    %{
      down?: not v.wanted?,
      leftover: o.leftover,
      removing?: inst != nil and inst.state == :removing,
      present?: inst != nil and not v.running?,
      absent?: inst == nil,
      retire?: not v.wanted? or v.expected? or v.recreate? or stale?(v),
      dispose?: v.deleting? or v.recreate? or (v.removes? and discarded?(v)),
      pull_waiting?: match?({:pulling, true}, o.pull),
      stale_pull: o.stale_pull,
      # What the table holds for the app, apart from what the instance has
      # to put there: a row that is another token's is nobody's, whether or
      # not this instance has one of its own.
      token: o.token,
      token_held?: o.token in [:current, :other],
      token_owed?: inst != nil and inst.token? and o.token == :absent,
      no_token?: inst != nil and not inst.token? and o.token != :none,
      image_owed?: image_owed?(v, o),
      data?: o.data?,
      buildable?: v.native? or o.image != nil
    }
    |> Map.put(:failure, base.failure)
  end

  defp stale?(v), do: v.made_for != nil and not restart?(v.made_for, v.target)

  # A container that is not running and will not be started as it is: the
  # app is not to run, its exit was asked for, it was made for other
  # counters, it was created from a spec that has changed since, or it has
  # run and nothing is recorded of it.
  defp discarded?(%{inst: inst} = v) do
    created? = inst != nil and inst.state == :created

    not v.wanted? or v.expected? or not v.counters? or
      if(created?, do: drifted?(v), else: not v.same? and not v.finished?)
  end

  # Of an app being removed, an image that is still there; of any other,
  # one that is missing and wanted.
  defp image_owed?(%{deleting?: true} = v, o),
    do: v.removes? and o.image != nil and o.image_present? and :image not in v.base.cleaned

  defp image_owed?(v, o),
    do: v.inst == nil and not v.native? and o.image != nil and not o.image_present?

  defp ended(%{st: st, base: base} = v, o) do
    exited? = exited?(v)
    gone? = gone?(v)
    {spend, spent?} = spend(v.restarts, v.policy, v.now)
    loop = loop(v.engine, v.policy, v.now)

    # An action that raised, whichever it was: asked for again it raises
    # again. Not of an app being deleted, which nothing but its removal
    # can move on, and whose spec no write will change.
    raised? =
      not v.deleting? and match?(%{class: :permanent, cause: :crashed}, base.failure) and
        base.failure.action != :run

    %{
      succeeded?: st.succeeded == v.generation,
      failed?: base.failure != nil and base.failure.class == :permanent,
      raised?: raised?,
      # A running instance has its token in the table whatever became of
      # the app, the action that raised included. Unless that action was
      # the put: asked for again by every pass, it would raise in every one.
      put_raised?: match?(%{action: :put_token}, base.failure),
      # The same of the removal of a row that is nobody's.
      revoke_raised?: raised? and match?(%{action: :remove_token}, base.failure),
      retry_in: retry_in(base.failure, v.now),
      crash_loop?: v.running? and loop.looping?,
      loop_spent?: loop.spent? or o.image == nil,
      loop_actions: loop.actions,
      exited?: exited?,
      ended?: exited? or gone?,
      unhealthy?: unhealthy?(v),
      spend: spend,
      spent?: spent?
    }
  end

  # Ended by itself: there, and having run. One whose exit was asked for,
  # that was made for other counters or that nothing is recorded of has
  # been removed by a clause before any that reads this.
  defp exited?(%{inst: inst} = v),
    do: judged?(v) and inst != nil and not v.running? and inst.state != :created

  # Or gone, after it was seen running.
  defp gone?(%{inst: nil, known: %{running?: true, id: id}} = v),
    do: judged?(v) and v.st.expected_exit != id

  defp gone?(_v), do: false

  defp judged?(v), do: v.wanted? and policy_restarts?(v.policy)

  defp unhealthy?(%{inst: inst} = v) do
    v.wanted? and v.same? and v.running? and not v.expected? and
      match?({:restart, _budget}, v.policy) and
      (inst.health == :unhealthy or Readiness.unhealthy?(v.base.probe))
  end

  defp starting(%{inst: inst, record: record, st: st, pulled: pull, now: now} = v, o) do
    spec = v.resource.spec
    readiness = v.profile.readiness(spec)
    wave_since = st.wave_since || now

    %{
      backoff_in: backoff_in(v.restarts, v.policy, now),
      waiting_on: o.waiting_on,
      wave_since: wave_since,
      wave_wait_in:
        if(o.waiting_on == [],
          do: 0,
          else: max(v.profile.wave_wait_ms(spec) - Stamp.age(wave_since, now), 0)
        ),
      wave: v.profile.wave(spec),
      pull: pull.state,
      pull_failure: pull.failure,
      pull_retry_in: pull.retry_in,
      pull_next: pull.next,
      waiting: inst && waiting(readiness, inst, record.ready? or o.ready == :ready),
      past_deadline?: record != nil and Readiness.past_deadline?(readiness, record.since, now),
      readiness_poll: if(match?(%{kind: {:http, _}}, readiness), do: @readiness_poll_ms),
      gates_closed: for(gate <- o.gates, not open?(v.resource, gate, v.id), do: gate),
      reset_in: reset_in(v.restarts, v.policy, st.ready_since || now, now),
      probe_in: if(o.probes?, do: Readiness.probe_due_in(v.base.probe, now))
    }
  end

  defp counters(made_for), do: Map.take(made_for, [:restart_counter, :start_counter])
  defp restart?(made_for, target), do: made_for.restart_counter == target.restart_counter

  defp policy_restarts?({:crash_loop, _rule}), do: false
  defp policy_restarts?(_never_or_restart), do: true

  # The failure of the pass before, classified, or the one recorded while
  # it is about this generation. A stop that is still under way is none.
  defp failure(recorded, nil, generation),
    do: if(recorded != nil and recorded.generation == generation, do: recorded)

  # A failure is of the generation whose pass performed the action, which
  # the action's arguments say: one of another generation is about a spec
  # that has been written to since. It is counted once, known by its
  # stamp: a pass that fails after its commit is handed the same again.
  defp failure(recorded, %{generation: other}, generation) when other != generation,
    do: failure(recorded, nil, generation)

  defp failure(%{action: action, at: at} = recorded, %{name: action, at: at}, generation),
    do: failure(recorded, nil, generation)

  defp failure(recorded, %{name: action, reason: reason, at: at}, generation) do
    case Failure.classify(action, reason) do
      %{class: :pending} ->
        failure(recorded, nil, generation)

      %{class: class, cause: cause, detail: detail} ->
        again? =
          recorded != nil and recorded.action == action and recorded.generation == generation

        %{
          action: action,
          class: class,
          cause: cause,
          detail: detail,
          at: at,
          generation: generation,
          count: if(again?, do: recorded.count + 1, else: 1)
        }
    end
  end

  defp retry_in(%{class: :transient, action: action, count: count, at: at}, now)
       when action in @start_actions,
       do: max(retry_delay(count) - Stamp.age(at, now), 0)

  defp retry_in(_none, _now), do: 0

  # A count below one is none this controller writes. Status is read as it
  # is found, and a pass that raised on it would raise again every time.
  defp retry_delay(count) do
    {base, max} = @retry_ms
    min(base * Integer.pow(2, count |> Kernel.-(1) |> max(0) |> min(20)), max)
  end

  defp probe(probe, result, _watched?, now) when result in [:healthy, :unhealthy, :skipped],
    do: Readiness.strike(probe, result, now)

  defp probe(probe, _none, true, now), do: %{probe | at: probe.at || now}
  defp probe(_probe, _none, false, _now), do: @blank.probe

  # The engine restarted the instance: the same container, started again.
  defp engine_restarts(%{seen: seen} = engine, {:crash_loop, rule}, inst, known, true, now) do
    seen = Enum.filter(seen, &(Stamp.age(&1, now) < rule.window_ms))

    restarted? =
      inst.restart_count > known.restart_count and inst.started_at != known.started_at

    %{engine | seen: if(restarted?, do: [now | seen], else: seen)}
  end

  defp engine_restarts(engine, {:crash_loop, _rule}, _inst, _known, false, _now),
    do: %{engine | seen: []}

  defp engine_restarts(_engine, _policy, _inst, _known, _same?, _now), do: @blank.engine_restarts

  defp loop(%{seen: seen, actions: actions}, {:crash_loop, rule}, now) do
    actions = Enum.filter(actions, &(Stamp.age(&1, now) < rule.action_window_ms))

    %{
      looping?: length(seen) >= rule.restarts,
      spent?: length(actions) >= rule.max_actions,
      actions: actions
    }
  end

  defp loop(_engine, _policy, _now), do: %{looping?: false, spent?: false, actions: []}

  # One more attempt, and whether there is none left.
  defp spend(%{attempts: attempts} = restarts, {:restart, budget}, now) do
    if attempts >= budget.attempts,
      do: {restarts, true},
      else: {%{attempts: attempts + 1, last: now}, false}
  end

  defp spend(restarts, _policy, _now), do: {restarts, false}

  defp backoff_in(%{attempts: attempts, last: last}, {:restart, budget}, now) when attempts > 0,
    do: max(budget.backoff_ms * Integer.pow(2, attempts - 1) - Stamp.age(last, now), 0)

  defp backoff_in(_restarts, _policy, _now), do: 0

  defp reset_in(%{attempts: attempts}, {:restart, budget}, ready_since, now) when attempts > 0,
    do: max(budget.reset_after_ms - Stamp.age(ready_since, now), 0)

  defp reset_in(_restarts, _policy, _ready_since, _now), do: nil

  defp waiting(readiness, inst, answered?) do
    case Readiness.decide(readiness, inst, answered?) do
      :ready -> nil
      {:waiting, reason} -> reason
    end
  end

  # `recorded` is the pull this app asked for: only a failure of that one,
  # for this generation, is this app's to judge, and any other is asked for
  # anew. `after` is the failure that stood when it asked, which is the one
  # being tried again and not its answer. Failures are counted as they are
  # seen, by their stamp: a pass cut after its commit has asked for nothing.
  defp pull(state, recorded, image, generation, now) do
    mine? = recorded != nil and recorded.image == image and recorded.generation == generation
    record = if(mine?, do: recorded, else: %{@pull | image: image, generation: generation})

    none = %{
      state: :idle,
      failure: nil,
      retry_in: 0,
      record: if(mine?, do: recorded),
      next: record
    }

    case state do
      {:pulling, true} ->
        %{none | state: :pulling}

      {:failed, _reason, stamp} when mine? and stamp != recorded.after ->
        failure = Failure.of_pull(state)
        failures = if(stamp == recorded.seen, do: recorded.failures, else: recorded.failures + 1)
        record = %{recorded | failures: failures, seen: stamp}
        seen = %{none | failure: failure, record: record, next: %{record | after: stamp}}

        if failure.class == :permanent,
          do: %{seen | state: :refused},
          else: %{seen | retry_in: max(retry_delay(failures) - Stamp.age(stamp, now), 0)}

      {:failed, _reason, stamp} ->
        %{none | next: %{record | after: stamp}}

      _idle_or_not_mine ->
        none
    end
  end

  # A gate is open when its condition is true, names this instance, and was
  # written for the spec as it is: one from before a write that kept the
  # instance is its owner's word on a spec it has yet to look at.
  defp open?(_resource, _gate, nil), do: false

  defp open?(%Resource{generation: generation} = resource, gate, id) do
    match?(
      %{status: true, message: ^id, observed_generation: ^generation},
      Resource.get_condition(resource, gate)
    )
  end
end
