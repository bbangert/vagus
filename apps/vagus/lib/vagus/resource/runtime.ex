defmodule Vagus.Resource.Runtime do
  @moduledoc """
  Runs one controller against the resources of its kind.

  It owns a queue of resource names with at most one step in flight per
  name, the timers and failure counts of those names, and an index of which
  other resources each one refers to. None of it is durable and none needs
  to be: a start lists the kind and looks at everything.

  A step (`Vagus.Resource.Runtime.Step`) runs in a task under the
  controller's own `Task.Supervisor`, and every callback of the controller
  runs there: this process handles only data, so nothing a controller does
  can stop or stall it. A change that arrives while a name's step is in
  flight marks the name dirty and it runs once more afterwards, however many
  changes there were: notifications become set members, never queued work.

  A step that crashes frees its name and is retried with back-off. The same
  back-off spaces passes that keep ending in a failed action, and passes
  that keep performing the same actions: an action that succeeds without
  changing what is observed would otherwise be repeated without pause. While
  such a timer is armed it alone brings the next pass: a change that arrives
  during the failing step waits for it.

  Controllers are level-triggered, so a notification is only a hint to look.
  Whatever one missed is found by a resync, which looks at every resource of
  the kind: at start, every `:resync` milliseconds, and on `resync/2`, which
  the engine's event stream calls after each reconnect because it cannot say
  what it dropped.

  While the host is shutting down (`:shutdown?`) no step starts and a step
  in flight stops before its next write or action: the containers the
  shutdown stops are not crashes.

  **When this process is absent** nothing reconciles the kind for this
  controller. Its supervisor replaces it together with its task supervisor,
  and the replacement registers with the store again, under the same
  identity, and starts from a listing. The store forgets registrations when
  it restarts, and this process is restarted with it.

  ## Options

    * `:instance`, `:controller`, `:tasks` (the task supervisor's name)
    * `:context`, a map merged into what `observe/2` and `act/3` are given
    * `:clock`, `:shutdown?` (default `Vagus.Host.Shutdown.in_flight?/0`)
    * `:resync`, milliseconds or `:infinity` (default five minutes)
    * `:backoff`, `{base_ms, max_ms}` for crashed steps
    * `:unavailable_retry` and `:gate_poll`, milliseconds
    * `:strict_verdicts`: raise in the step on a verdict that does not match
      the controller's declaration, instead of logging and writing nothing
      (default `config :vagus, :strict_verdicts`)
    * `:boundary`, called in the step's task after each commit and each
      action, for a harness that interrupts there, with a map whose `:after`
      is `:commit`, `:idle_commit` for one that changed nothing, or `:action`

  The remaining options each take a mechanism away or break a rule, to
  prove that a test suite notices: `deliver_events: false` drops change
  notifications, `skip_resync: true` makes every resync after the start a
  no-op, `ignore_dirty: true` forgets a change that arrives during a step,
  `skip_collector: true` collects nothing, `double_step: true` starts a step
  for a name that has one in flight, `stamp_current_generation: true` marks
  a verdict with the generation current at its commit, and
  `repeat_action: true` performs every action twice.
  """

  use GenServer

  require Logger

  alias Vagus.Host.Shutdown
  alias Vagus.Resource
  alias Vagus.Resource.{Clock, Controller, Store, Watch}
  alias Vagus.Resource.Runtime.Step

  @type info :: %{
          queued: [Resource.name()],
          in_flight: %{optional(Resource.name()) => pid()},
          dirty: [Resource.name()],
          timers: [Resource.name()],
          failures: %{optional(Resource.name()) => pos_integer()},
          references: %{optional(Resource.name()) => [Resource.key()]},
          steps: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = name(instance(opts), Keyword.fetch!(opts, :controller))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec name(atom(), module()) :: atom()
  def name(instance, controller), do: Module.concat([instance, Runtime, controller])

  @doc "The name of the controller's task supervisor."
  @spec tasks(atom(), module()) :: atom()
  def tasks(instance, controller), do: Module.concat([instance, Tasks, controller])

  @doc """
  Looks at every resource of the kind again. For whoever knows that changes
  may have gone unannounced.
  """
  @spec resync(module(), keyword()) :: :ok
  def resync(controller, opts \\ []),
    do: GenServer.cast(name(instance(opts), controller), :resync)

  @spec info(module(), keyword()) :: info()
  def info(controller, opts \\ []), do: GenServer.call(name(instance(opts), controller), :info)

  @doc """
  A message a runtime answers, once it has nothing queued and nothing in
  flight, with `{ref, runtime_pid, steps_started}` to `reply_to`. A runtime
  resting for a shutdown counts as having nothing queued. With
  `timers: :none` it answers only once no timer is pending either.

  Sent through `Vagus.Resource.Store.relay/3` it arrives behind every
  notification the store has sent, so the answer covers them.
  """
  @spec quiet_probe(pid(), reference(), timers: :any | :none) :: term()
  def quiet_probe(reply_to, ref, opts \\ []) when is_pid(reply_to) and is_reference(ref),
    do: {__MODULE__, :quiet?, reply_to, ref, Keyword.get(opts, :timers, :any)}

  @doc "As `quiet_probe/2`, answered at once with `{ref, runtime_pid, info}`."
  @spec info_probe(pid(), reference()) :: term()
  def info_probe(reply_to, ref) when is_pid(reply_to) and is_reference(ref),
    do: {__MODULE__, :info, reply_to, ref}

  defp instance(opts), do: Keyword.get(opts, :instance, Resource)

  @impl true
  def init(opts) do
    instance = instance(opts)
    controller = Keyword.fetch!(opts, :controller)
    Code.ensure_loaded!(controller)
    kind = controller.kind()
    owner? = Controller.owner?(controller)
    clock = Keyword.get(opts, :clock, Clock.System)
    shutdown? = Keyword.get(opts, :shutdown?, &Shutdown.in_flight?/0)

    state = %{
      i: [instance: instance],
      controller: controller,
      kind: kind,
      owner?: owner?,
      tasks: Keyword.fetch!(opts, :tasks),
      shutdown?: shutdown?,
      resync: Keyword.get(opts, :resync, :timer.minutes(5)),
      backoff: Keyword.get(opts, :backoff, {500, 60_000}),
      unavailable_retry: Keyword.get(opts, :unavailable_retry, 5_000),
      gate_poll: Keyword.get(opts, :gate_poll, 1_000),
      deliver_events: Keyword.get(opts, :deliver_events, true),
      skip_resync: Keyword.get(opts, :skip_resync, false),
      ignore_dirty: Keyword.get(opts, :ignore_dirty, false),
      double_step: Keyword.get(opts, :double_step, false),
      step: %{
        runtime: self(),
        controller: controller,
        kind: kind,
        owner?: owner?,
        instance: instance,
        i: [instance: instance],
        clock: clock,
        shutdown?: shutdown?,
        skip_collector: Keyword.get(opts, :skip_collector, false),
        stamp_current_generation: Keyword.get(opts, :stamp_current_generation, false),
        repeat_action: Keyword.get(opts, :repeat_action, false),
        context: Keyword.get(opts, :context, %{}),
        strict:
          Keyword.get_lazy(opts, :strict_verdicts, fn ->
            Application.get_env(:vagus, :strict_verdicts, false)
          end),
        boundary: Keyword.get(opts, :boundary),
        types: Controller.conditions(controller),
        retention: Controller.optional(controller, :retention, [], nil),
        finalize_after: Controller.optional(controller, :finalize_after, [], []),
        priority: 0
      },
      queued: MapSet.new(),
      in_flight: %{},
      refs: %{},
      dirty: MapSet.new(),
      # Names removed while their step was in flight: what that step reports
      # is about a resource that is gone.
      stale: MapSet.new(),
      timers: %{},
      failures: %{},
      failed: %{},
      acted: %{},
      refs_out: %{},
      refs_in: %{},
      watched: MapSet.new([kind]),
      steps: 0,
      probes: [],
      gate_timer: nil
    }

    {:ok, state, {:continue, :start}}
  end

  # Not in `init/1`: the supervisor's start sequence does not wait for a
  # listing, and nothing later in it depends on this process being ready.
  @impl true
  def handle_continue(:start, %{controller: controller, kind: kind, i: i} = state) do
    declared = [conditions: state.step.types] ++ i

    registered =
      if state.owner?,
        do: Store.register_kind(kind, controller, declared),
        else: Store.register_writer(kind, controller, declared)

    case registered do
      :ok ->
        :ok = Watch.subscribe({:kind, kind}, i)
        {:noreply, state |> schedule_resync() |> relist() |> dispatch()}

      # `Vagus.Resource.Controller.kinds/1` refuses every list of controllers
      # the store would refuse, before anything starts. Reaching this means
      # the two disagree, and no restart will change that.
      {:error, reason} ->
        {:stop, {:registration_refused, controller, reason}, state}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast(:resync, state), do: {:noreply, state |> look_again() |> settle()}

  @impl true
  def handle_info({Watch, _event, _meta}, %{deliver_events: false} = state),
    do: {:noreply, state}

  def handle_info({Watch, event, %{kind: kind, name: name}}, state) do
    state = if kind == state.kind, do: own(state, event, name), else: state

    state.refs_in
    |> Map.get({kind, name}, [])
    |> Enum.reduce(state, &enqueue(&2, &1))
    |> settle()
    |> noreply()
  end

  def handle_info(:resync, state),
    do: {:noreply, state |> schedule_resync() |> look_again() |> settle()}

  # The token: a timer cancelled after it fired has its message in the
  # mailbox already, and for a resource since deleted that message must not
  # queue the name again.
  def handle_info({:requeue, name, token}, state) do
    case state.timers do
      %{^name => {_timer, ^token}} ->
        {:noreply, %{state | timers: Map.delete(state.timers, name)} |> enqueue(name) |> settle()}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info(:gate, state), do: {:noreply, settle(%{state | gate_timer: nil})}

  def handle_info({__MODULE__, :quiet?, reply_to, ref, timers}, state),
    do: {:noreply, answer_probes(%{state | probes: [{reply_to, ref, timers} | state.probes]})}

  def handle_info({__MODULE__, :info, reply_to, ref}, state) do
    send(reply_to, {ref, self(), snapshot(state)})
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish(ref, result) |> settle()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.refs, ref),
    do: {:noreply, state |> finish(ref, {:crashed, reason}) |> settle()}

  def handle_info(_other, state), do: {:noreply, state}

  defp noreply(state), do: {:noreply, state}

  defp snapshot(state) do
    %{
      queued: state.queued |> MapSet.to_list() |> Enum.sort(),
      in_flight: Map.new(state.in_flight, fn {name, task} -> {name, task.pid} end),
      dirty: state.dirty |> MapSet.to_list() |> Enum.sort(),
      timers: state.timers |> Map.keys() |> Enum.sort(),
      failures: state.failures,
      references: state.refs_out,
      steps: state.steps
    }
  end

  defp own(state, :changed, name), do: enqueue(state, name)

  defp own(state, :removed, name) do
    stale =
      if is_map_key(state.in_flight, name), do: MapSet.put(state.stale, name), else: state.stale

    forget(%{state | stale: stale}, name)
  end

  defp schedule_resync(%{resync: :infinity} = state), do: state

  defp schedule_resync(state) do
    Process.send_after(self(), :resync, state.resync)
    state
  end

  defp look_again(%{skip_resync: true} = state), do: state
  defp look_again(state), do: relist(state)

  defp relist(state) do
    names = for resource <- Store.list(state.kind, state.i), do: resource.name
    state = Enum.reduce(names, state, &enqueue(&2, &1))

    # What a missed removal notice left behind.
    [state.timers, state.failures, state.failed, state.acted, state.refs_out]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Kernel.--(names)
    |> Enum.reduce(state, &forget(&2, &1))
  end

  defp forget(state, name) do
    state = state |> cancel_timer(name) |> index(name, []) |> elem(0)

    %{
      state
      | queued: MapSet.delete(state.queued, name),
        failures: Map.delete(state.failures, name),
        failed: Map.delete(state.failed, name),
        acted: Map.delete(state.acted, name)
    }
  end

  # Returns whether `keys` holds a reference the index did not have for the
  # name, having subscribed to its kind if nobody had.
  defp index(state, name, keys) do
    old = Map.get(state.refs_out, name, [])
    added = keys -- old

    refs_in =
      Enum.reduce(old -- keys, state.refs_in, fn key, refs_in ->
        case List.delete(Map.fetch!(refs_in, key), name) do
          [] -> Map.delete(refs_in, key)
          names -> Map.put(refs_in, key, names)
        end
      end)

    refs_in =
      Enum.reduce(added, refs_in, &Map.update(&2, &1, [name], fn names -> [name | names] end))

    refs_out =
      if keys == [],
        do: Map.delete(state.refs_out, name),
        else: Map.put(state.refs_out, name, keys)

    {watch(%{state | refs_in: refs_in, refs_out: refs_out}, added), added != []}
  end

  defp watch(state, keys) do
    kinds =
      for {kind, _name} <- keys, not MapSet.member?(state.watched, kind), uniq: true, do: kind

    for kind <- kinds, do: :ok = Watch.subscribe({:kind, kind}, state.i)
    %{state | watched: Enum.into(kinds, state.watched)}
  end

  defp enqueue(state, name) do
    cond do
      not is_map_key(state.in_flight, name) or state.double_step ->
        %{state | queued: MapSet.put(state.queued, name)}

      state.ignore_dirty ->
        state

      true ->
        %{state | dirty: MapSet.put(state.dirty, name)}
    end
  end

  defp settle(state), do: state |> dispatch() |> answer_probes()

  defp dispatch(state) do
    cond do
      MapSet.size(state.queued) == 0 ->
        state

      state.shutdown?.() ->
        # Nothing announces the end of a shutdown that did not happen.
        timer = state.gate_timer || Process.send_after(self(), :gate, state.gate_poll)
        %{state | gate_timer: timer}

      # In no order: every step is started at once, and what orders the
      # work is the lane each action waits in.
      true ->
        Enum.reduce(state.queued, %{state | queued: MapSet.new()}, &start_step/2)
    end
  end

  defp start_step(name, state) do
    step = Map.merge(state.step, %{name: name, failed_action: Map.get(state.failed, name)})
    task = Task.Supervisor.async_nolink(state.tasks, Step, :run, [step])

    %{
      state
      | in_flight: Map.put(state.in_flight, name, task),
        refs: Map.put(state.refs, task.ref, name),
        steps: state.steps + 1
    }
  end

  defp finish(state, ref, result) do
    {name, refs} = Map.pop!(state.refs, ref)
    dirty? = MapSet.member?(state.dirty, name)
    stale? = MapSet.member?(state.stale, name)

    state =
      cancel_timer(
        %{
          state
          | refs: refs,
            in_flight: Map.delete(state.in_flight, name),
            dirty: MapSet.delete(state.dirty, name),
            stale: MapSet.delete(state.stale, name)
        },
        name
      )

    # The store writes its table before it sends a notice. So a resource
    # missing here is gone, whatever this step or a notice not yet read
    # says, and one created after this read has its own notice still to come.
    case Store.get(state.kind, name, state.i) do
      nil ->
        forget(state, name)

      stored ->
        if stale? or other?(result, stored) do
          # The step was about an earlier resource of this name. Nothing it
          # found is true of this one, which has only been announced.
          state = forget(state, name)
          if dirty?, do: enqueue(state, name), else: state
        else
          {state, new_reference?} = learn(state, name, result)
          {state, carried?} = outcome(state, name, result)
          again?(state, name, dirty?, new_reference?, carried?)
        end
    end
  end

  defp other?(%{uid: uid}, stored), do: uid != stored.uid
  defp other?(_gone_or_crashed, _stored), do: false

  defp learn(state, name, %{refs: keys}), do: index(state, name, keys)
  defp learn(state, _name, _gone_or_crashed), do: {state, false}

  # A reference the index learns only now may have changed after the step
  # observed it and before this: that notice came while nothing pointed from
  # it to this name. One more pass sees what it announced; it reports the
  # same references, so there is no third.
  #
  # While a failure's timer is armed the timer brings the next pass and a
  # dirty mark does not. The mark may be the step's own doing: its commit
  # is announced like any other, and a pass that writes status and then
  # fails would bring itself back at once, each time. Told apart it cannot
  # be, since a commit's result already holds any write that landed between
  # the step's read and that commit. The cost is that a real change during
  # a failing step waits for the back-off, at most its cap.
  defp again?(state, name, dirty?, new_reference?, carried?) do
    if new_reference? or (dirty? and not carried?), do: enqueue(state, name), else: state
  end

  # Each returns whether it armed a timer that is to carry the next pass.
  defp outcome(state, name, %{outcome: {:ok, next}, actions: actions}) do
    state = %{state | failed: Map.delete(state.failed, name)}

    if actions != [] and Map.get(state.acted, name) == actions do
      # The same actions as the pass before, which therefore changed nothing
      # that this pass could observe.
      {paced(state, name), true}
    else
      acted =
        if actions == [],
          do: Map.delete(state.acted, name),
          else: Map.put(state.acted, name, actions)

      {next(%{state | failures: Map.delete(state.failures, name), acted: acted}, name, next),
       false}
    end
  end

  # Not a failure: nothing was tried. The failed action of the pass before
  # is kept for the next pass that can observe.
  defp outcome(state, name, %{outcome: {:unavailable, next}}) do
    ms =
      case next do
        {:after, ms} -> min(ms, state.unavailable_retry)
        _other -> state.unavailable_retry
      end

    {arm(state, name, ms), true}
  end

  # The controller counts these and paces its own retries, so the next pass
  # is at once, to let its verdict say what happened. Should that pass end
  # the same way, nothing is pacing them, and the back-off does.
  defp outcome(state, name, %{outcome: {:action_failed, failure}}) do
    state = %{state | failed: Map.put(state.failed, name, failure)}

    if is_map_key(state.failures, name),
      do: {paced(state, name), true},
      else: {enqueue(%{state | failures: Map.put(state.failures, name, 1)}, name), false}
  end

  defp outcome(state, name, %{outcome: :gated}), do: {enqueue(state, name), false}
  defp outcome(state, _name, %{outcome: :gone}), do: {state, false}
  defp outcome(state, _name, :gone), do: {state, false}

  defp outcome(state, name, crashed) do
    state = paced(state, name)

    Logger.warning(
      "#{inspect(state.controller)}: step for #{state.kind}/#{name} failed " <>
        "(#{state.failures[name]}): #{inspect(crashed)}"
    )

    {state, true}
  end

  defp paced(%{backoff: {base, max}} = state, name) do
    count = Map.get(state.failures, name, 0) + 1
    ms = min(base * Integer.pow(2, min(count - 1, 20)), max)
    arm(%{state | failures: Map.put(state.failures, name, count)}, name, ms)
  end

  defp next(state, _name, :rest), do: state
  defp next(state, name, :now), do: enqueue(state, name)
  defp next(state, name, {:after, ms}), do: arm(state, name, ms)

  defp arm(state, name, ms) do
    state = cancel_timer(state, name)
    token = make_ref()
    timer = Process.send_after(self(), {:requeue, name, token}, ms)
    %{state | timers: Map.put(state.timers, name, {timer, token})}
  end

  defp cancel_timer(state, name) do
    case Map.pop(state.timers, name) do
      {nil, _timers} ->
        state

      {{timer, _token}, timers} ->
        Process.cancel_timer(timer)
        %{state | timers: timers}
    end
  end

  defp answer_probes(%{probes: []} = state), do: state

  defp answer_probes(state) do
    quiet? =
      map_size(state.in_flight) == 0 and (MapSet.size(state.queued) == 0 or state.shutdown?.())

    {answered, waiting} =
      Enum.split_with(state.probes, fn {_reply_to, _ref, timers} ->
        quiet? and (timers == :any or map_size(state.timers) == 0)
      end)

    for {reply_to, ref, _timers} <- answered, do: send(reply_to, {ref, self(), state.steps})
    %{state | probes: waiting}
  end
end
