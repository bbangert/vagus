defmodule Vagus.Resource.Runtime do
  @moduledoc """
  Runs one controller against the resources of its kind.

  It owns a queue of resource names with at most one step in flight per
  name and at most `:max_in_flight_steps` in all, and what it remembers of
  each resource: its timer, its failure count, the references it reported.
  That is kept by uid, so a resource created under a deleted one's name
  starts with nothing. None of it is durable and none needs to be: a start
  lists the kind and looks at everything.

  A step (`Vagus.Resource.Runtime.Step`) runs in a task under the
  controller's own `Task.Supervisor`, and every callback of the controller
  runs there: this process handles only data, so nothing a controller does
  can stop or stall it. A change that arrives while a name's step is in
  flight marks the name dirty and it runs once more afterwards, however many
  changes there were: notifications become set members, never queued work.

  The queue is first come, first served: a name already waiting keeps its
  place whatever else asks for it, and one whose step has ended and is
  wanted again goes to the back, so none is held back by another that keeps
  coming round. The bound is on steps, observations included, which the
  lanes do not count: without it a start would observe every resource of
  the kind at once. A step holds its place until it ends, a wait for a lane
  and the action included: a stop holds one for its grace plus a margin, so
  as many long actions as the bound leave the rest of the kind unobserved
  meanwhile, and what bounds a step is the timeout of the calls it makes.

  A step that crashes frees its name and is retried with back-off. The same
  back-off spaces passes that keep ending in a failed action, and passes
  that keep performing the action of the same name, whatever its arguments:
  an action that succeeds without changing what is observed would otherwise
  be repeated without pause. A pass that performs none in between ends the
  run.

  What such a timer holds back is only the dirty mark made while the failing
  step was in flight: that mark may be the step's own write, announced like
  any other, and a step that writes and then fails must not bring itself
  back. A change that arrives after the step has ended queues the name at
  once, timer or no timer, since by then it can only be news.

  Controllers are level-triggered, so a notification is only a hint to look.
  Whatever one missed is found by a resync, which looks at every resource of
  the kind: at start, every `:resync` milliseconds, and on `resync/2`.
  `enqueue/3` is the hint for one resource, from a source the store does not
  announce.

  While the host is shutting down (`:shutdown?`) no step starts and a step
  in flight stops before its next write or action: the containers the
  shutdown stops are not crashes.

  **When this process is absent** nothing reconciles the kind for this
  controller. Its supervisor replaces it together with its task supervisor,
  and the replacement starts from a listing. A new store leaves this
  process as it is, and has it look at everything again.

  ## Options

    * `:instance`, `:declaration` (the controller's
      `t:Vagus.Resource.Controller.declaration/0`), `:tasks` (the task
      supervisor's name)
    * `:context`, a map merged into what `observe/2` and `act/3` are given
    * `:clock`, `:shutdown?` (default `Vagus.Host.Shutdown.in_flight?/0`)
    * `:max_in_flight_steps` (default `config :vagus, :max_in_flight_steps`,
      else 4)
    * `:resync`, milliseconds or `:infinity` (default five minutes)
    * `:backoff`, `{base_ms, max_ms}` for crashed steps
    * `:unavailable_retry` and `:gate_poll`, milliseconds
    * `:boundary`, called in the step's task after its commit and after its
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
  alias Vagus.Resource.{Clock, Store, Watch}
  alias Vagus.Resource.Runtime.Step

  @typedoc "`queued` is in the order the names will be served."
  @type info :: %{
          queued: [Resource.name()],
          in_flight: %{optional(Resource.name()) => pid()},
          dirty: [Resource.name()],
          hinted: [Resource.name()],
          timers: [Resource.name()],
          failures: %{optional(Resource.name()) => pos_integer()},
          references: %{optional(Resource.name()) => [Resource.key()]},
          steps: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = name(instance(opts), Keyword.fetch!(opts, :declaration).controller)
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

  @doc """
  Looks at one resource again. For whoever knows that something outside the
  store changed for it, which no notification announces: an engine event
  about its container, a pull it waits for that has ended. A name the kind
  does not hold is dropped when its turn comes, and with no runtime nothing
  is lost: its replacement looks at everything.

  One that arrives during the resource's pass gets a pass of its own right
  after, whatever that pass ends in and whatever timer it arms. A change in
  the store that arrives then may wait for a back-off, because it may be the
  pass's own write; this cannot be, and what it announces may be what the
  failing pass was waiting for.
  """
  @spec enqueue(module(), Resource.name(), keyword()) :: :ok
  def enqueue(controller, name, opts \\ []),
    do: GenServer.cast(name(instance(opts), controller), {:enqueue, name})

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

  @doc """
  The options one controller's runtime may be given apart from the others'
  (`Vagus.Resource.Supervisor`): how often it looks at everything, how many
  steps it has in flight, its pacing, and what its callbacks are handed.
  """
  @spec controller_options() :: [atom()]
  def controller_options,
    do: [:resync, :max_in_flight_steps, :context, :backoff, :unavailable_retry, :gate_poll]

  defp instance(opts), do: Keyword.get(opts, :instance, Resource)

  @impl true
  def init(opts) do
    instance = instance(opts)
    # Data: what the controller declares was evaluated before this process
    # existed, and nothing here or below calls the controller.
    %{controller: controller, kind: kind, owner?: owner?} =
      declaration = Keyword.fetch!(opts, :declaration)

    clock = Keyword.get(opts, :clock, Clock.System)
    shutdown? = Keyword.get(opts, :shutdown?, &Shutdown.in_flight?/0)

    max_in_flight =
      Keyword.get_lazy(opts, :max_in_flight_steps, fn ->
        Application.get_env(:vagus, :max_in_flight_steps, 4)
      end)

    # Zero would start nothing, ever, and say nothing about it.
    if not (is_integer(max_in_flight) and max_in_flight > 0),
      do: raise(ArgumentError, "max_in_flight_steps must be a positive integer")

    state = %{
      i: [instance: instance],
      controller: controller,
      kind: kind,
      tasks: Keyword.fetch!(opts, :tasks),
      shutdown?: shutdown?,
      max_in_flight: max_in_flight,
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
        boundary: Keyword.get(opts, :boundary),
        types: declaration.conditions,
        retention: declaration.retention
      },
      # In the order to be served. A list: a kind has tens of resources.
      queued: [],
      # `name => %{task, uid}`: the step in flight and the resource it is
      # about.
      in_flight: %{},
      refs: %{},
      dirty: MapSet.new(),
      # Names `enqueue/3` asked for while their step was in flight. Kept
      # apart from `dirty`, which a failing step's timer may hold back.
      hinted: MapSet.new(),
      # Everything remembered about a resource, by name, each record saying
      # which uid it is about. See `record/3`.
      known: %{},
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
  def handle_continue(:start, state) do
    :ok = Watch.subscribe({:kind, state.kind}, state.i)
    :ok = Watch.subscribe(:store, state.i)
    {:noreply, state |> schedule_resync() |> relist() |> dispatch()}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast(:resync, state), do: {:noreply, state |> look_again() |> settle()}

  def handle_cast({:enqueue, name}, state), do: {:noreply, state |> hint(name) |> settle()}

  @impl true
  def handle_info({Watch, _event, _meta}, %{deliver_events: false} = state),
    do: {:noreply, state}

  def handle_info({Watch, event, %{kind: kind, name: name} = meta}, state) do
    state = if kind == state.kind, do: own(state, event, meta), else: state

    state.refs_in
    |> Map.get({kind, name}, [])
    |> Enum.reduce(state, &queue(&2, &1))
    |> settle()
    |> noreply()
  end

  def handle_info({Watch, :restarted}, state),
    do: {:noreply, state |> look_again() |> settle()}

  def handle_info(:resync, state),
    do: {:noreply, state |> schedule_resync() |> look_again() |> settle()}

  # The token: a timer cancelled after it fired has its message in the
  # mailbox already, and for a resource since deleted that message must not
  # queue the name again.
  def handle_info({:requeue, name, uid, token}, state) do
    case record(state, name, uid) do
      %{timer: {_timer, ^token}} = record ->
        {:noreply, state |> put_record(name, %{record | timer: nil}) |> queue(name) |> settle()}

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
    names = fn keep? -> for {name, record} <- state.known, keep?.(record), do: name end

    %{
      queued: state.queued,
      in_flight: Map.new(state.in_flight, fn {name, flight} -> {name, flight.task.pid} end),
      dirty: state.dirty |> MapSet.to_list() |> Enum.sort(),
      hinted: state.hinted |> MapSet.to_list() |> Enum.sort(),
      timers: Enum.sort(names.(&(&1.timer != nil))),
      failures: for({name, %{failures: n}} <- state.known, n > 0, into: %{}, do: {name, n}),
      references:
        for({name, %{refs: [_ | _] = refs}} <- state.known, into: %{}, do: {name, refs}),
      steps: state.steps
    }
  end

  # What is remembered about a resource is about that resource, not about
  # its name: a failure count, a failed action, the name of the action the
  # last pass performed, a pending timer and the references it reported. `record/3` is the
  # only way to read it and `put_record/3` the only way to write it, both by
  # name and uid, so that nothing remembered of a deleted resource is ever
  # read as, or added to, what is known of a later one of the same name.
  defp record(state, name, uid) do
    case state.known do
      %{^name => %{uid: ^uid} = record} -> record
      _none_or_another -> %{uid: uid, failures: 0, failed: nil, acted: nil, timer: nil, refs: []}
    end
  end

  # Uids only grow. So a record for a higher uid replaces what was known of
  # the name, after that has been dropped whole, and one for a lower uid is
  # about a resource already replaced and is not kept.
  defp put_record(state, name, %{uid: uid} = record) do
    case state.known do
      %{^name => %{uid: held}} when held > uid -> state
      %{^name => %{uid: held}} when held < uid -> put_record(forget(state, name), name, record)
      _same_or_none -> %{state | known: Map.put(state.known, name, record)}
    end
  end

  # Having seen `uid` under `name`: whatever was known of an earlier resource
  # of that name is dropped now, before anything is decided from it.
  defp seen(state, name, uid), do: put_record(state, name, record(state, name, uid))

  defp forget(state, name) do
    case Map.pop(state.known, name) do
      {nil, _known} ->
        state

      {record, known} ->
        cancel(record.timer)
        %{state | known: known, refs_in: unrefer(state.refs_in, record.refs, name)}
    end
  end

  defp cancel(nil), do: :ok
  defp cancel({timer, _token}), do: Process.cancel_timer(timer)

  defp unrefer(refs_in, keys, name) do
    Enum.reduce(keys, refs_in, fn key, refs_in ->
      case List.delete(Map.fetch!(refs_in, key), name) do
        [] -> Map.delete(refs_in, key)
        names -> Map.put(refs_in, key, names)
      end
    end)
  end

  defp own(state, :changed, %{name: name, uid: uid}),
    do: state |> seen(name, uid) |> queue(name)

  # Only what was known of the resource that went: a removal read late must
  # not cost its successor anything.
  defp own(state, :removed, %{name: name, uid: uid}) do
    case state.known do
      %{^name => %{uid: ^uid}} -> forget(state, name)
      _none_or_another -> state
    end
  end

  defp schedule_resync(%{resync: :infinity} = state), do: state

  defp schedule_resync(state) do
    Process.send_after(self(), :resync, state.resync)
    state
  end

  defp look_again(%{skip_resync: true} = state), do: state
  defp look_again(state), do: relist(state)

  defp relist(state) do
    listed = for resource <- Store.list(state.kind, state.i), do: {resource.name, resource.uid}

    state =
      Enum.reduce(listed, state, fn {name, uid}, state ->
        state |> seen(name, uid) |> queue(name)
      end)

    # What a missed removal notice left behind.
    Enum.reduce(Map.keys(state.known) -- Enum.map(listed, &elem(&1, 0)), state, &forget(&2, &1))
  end

  # Returns whether `keys` holds a reference the index did not have for the
  # resource, having subscribed to its kind if nobody had.
  defp index(state, name, uid, keys) do
    record = record(state, name, uid)
    added = keys -- record.refs

    refs_in =
      Enum.reduce(
        added,
        unrefer(state.refs_in, record.refs -- keys, name),
        &Map.update(&2, &1, [name], fn names -> [name | names] end)
      )

    state = put_record(%{state | refs_in: refs_in}, name, %{record | refs: keys})
    {watch(state, added), added != []}
  end

  defp watch(state, keys) do
    kinds =
      for {kind, _name} <- keys, not MapSet.member?(state.watched, kind), uniq: true, do: kind

    for kind <- kinds, do: :ok = Watch.subscribe({:kind, kind}, state.i)
    %{state | watched: Enum.into(kinds, state.watched)}
  end

  defp queue(state, name) do
    cond do
      # At the back, and only once: a name that waits keeps its place.
      not is_map_key(state.in_flight, name) or state.double_step ->
        if name in state.queued, do: state, else: %{state | queued: state.queued ++ [name]}

      state.ignore_dirty ->
        state

      true ->
        %{state | dirty: MapSet.put(state.dirty, name)}
    end
  end

  defp hint(state, name) do
    if is_map_key(state.in_flight, name) and not state.double_step,
      do: %{state | hinted: MapSet.put(state.hinted, name)},
      else: queue(state, name)
  end

  defp settle(state), do: state |> dispatch() |> answer_probes()

  defp dispatch(state) do
    free = state.max_in_flight - map_size(state.in_flight)

    cond do
      state.queued == [] or free <= 0 ->
        state

      state.shutdown?.() ->
        # Nothing announces the end of a shutdown that did not happen.
        timer = state.gate_timer || Process.send_after(self(), :gate, state.gate_poll)
        %{state | gate_timer: timer}

      # Again afterwards: a name whose resource is gone took no place.
      true ->
        {next, waiting} = Enum.split(state.queued, free)
        next |> Enum.reduce(%{state | queued: waiting}, &start_step/2) |> dispatch()
    end
  end

  # The row is read here, a table read, so that the runtime knows which
  # resource the step is about before the step says anything: a step that
  # crashes says nothing.
  defp start_step(name, state) do
    case Store.get(state.kind, name, state.i) do
      nil ->
        forget(state, name)

      %Resource{uid: uid} = resource ->
        state = seen(state, name, uid)

        step =
          Map.merge(state.step, %{
            name: name,
            resource: resource,
            failed_action: record(state, name, uid).failed
          })

        task = Task.Supervisor.async_nolink(state.tasks, Step, :run, [step])

        %{
          state
          | in_flight: Map.put(state.in_flight, name, %{task: task, uid: uid}),
            refs: Map.put(state.refs, task.ref, name),
            steps: state.steps + 1
        }
    end
  end

  defp finish(state, ref, result) do
    {name, refs} = Map.pop!(state.refs, ref)
    {%{uid: uid}, in_flight} = Map.pop!(state.in_flight, name)
    dirty? = MapSet.member?(state.dirty, name)
    hinted? = MapSet.member?(state.hinted, name)

    state = %{
      state
      | refs: refs,
        in_flight: in_flight,
        dirty: MapSet.delete(state.dirty, name),
        hinted: MapSet.delete(state.hinted, name)
    }

    # The store writes its table before it sends a notice. So a resource
    # missing here is gone, whatever this step or a notice not yet read
    # says, and one created after this read has its own notice still to come.
    case Store.get(state.kind, name, state.i) do
      nil ->
        forget(state, name)

      # The step was about an earlier resource of this name, whether it
      # ended or crashed and whether or not the notices have been read.
      # Nothing it found is true of this one, which is only looked at.
      %Resource{uid: other} when other != uid ->
        state |> seen(name, other) |> queue(name)

      %Resource{} ->
        state = disarm(state, name, uid)
        {state, new_reference?} = learn(state, name, uid, result)
        {state, carried?} = outcome(state, name, uid, result)
        state = again?(state, name, dirty?, new_reference?, carried?)
        # The hint's pass is the one the timer would have brought: left
        # armed, the timer would fire into that pass and bring another.
        if hinted?, do: state |> disarm(name, uid) |> queue(name), else: state
    end
  end

  defp learn(state, name, uid, %{refs: keys}), do: index(state, name, uid, keys)
  defp learn(state, _name, _uid, _crashed), do: {state, false}

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
    if new_reference? or (dirty? and not carried?), do: queue(state, name), else: state
  end

  # Each returns whether it armed a timer that is to carry the next pass.
  defp outcome(state, name, uid, %{outcome: {:ok, next}, action: action}) do
    record = %{record(state, name, uid) | failed: nil}
    # By name: arguments that differ each time, a counter or a stamp, would
    # make every repeat look new.
    acted = action && elem(action, 0)

    if acted != nil and record.acted == acted do
      # The same action as the pass before, which therefore changed nothing
      # that this pass could observe.
      {paced(state, name, record), true}
    else
      record = %{record | failures: 0, acted: acted}

      case next do
        :rest -> {put_record(state, name, record), false}
        :now -> {state |> put_record(name, record) |> queue(name), false}
        {:after, ms} -> {arm(state, name, record, ms), false}
      end
    end
  end

  # Not a failure: nothing was tried. The failed action of the pass before
  # is kept for the next pass that can observe.
  defp outcome(state, name, uid, %{outcome: {:unavailable, next}}) do
    ms =
      case next do
        {:after, ms} -> min(ms, state.unavailable_retry)
        _other -> state.unavailable_retry
      end

    {arm(state, name, %{record(state, name, uid) | acted: nil}, ms), true}
  end

  # The controller counts these and paces its own retries, so the next pass
  # is at once, to let its verdict say what happened. Should that pass end
  # the same way, nothing is pacing them, and the back-off does.
  defp outcome(state, name, uid, %{outcome: {:action_failed, failure}}) do
    record = %{record(state, name, uid) | failed: failure, acted: nil}

    if record.failures > 0,
      do: {paced(state, name, record), true},
      else: {state |> put_record(name, %{record | failures: 1}) |> queue(name), false}
  end

  defp outcome(state, name, _uid, %{outcome: :gated}), do: {queue(state, name), false}
  defp outcome(state, _name, _uid, %{outcome: :gone}), do: {state, false}

  defp outcome(state, name, uid, crashed) do
    record = record(state, name, uid)

    Logger.warning(
      "#{inspect(state.controller)}: step for #{state.kind}/#{name} failed " <>
        "(#{record.failures + 1}): #{inspect(crashed)}"
    )

    {paced(state, name, record), true}
  end

  defp paced(%{backoff: {base, max}} = state, name, record) do
    count = record.failures + 1
    ms = min(base * Integer.pow(2, min(count - 1, 20)), max)
    arm(state, name, %{record | failures: count}, ms)
  end

  defp arm(state, name, %{uid: uid} = record, ms) do
    cancel(record.timer)
    token = make_ref()
    timer = Process.send_after(self(), {:requeue, name, uid, token}, ms)
    put_record(state, name, %{record | timer: {timer, token}})
  end

  defp disarm(state, name, uid) do
    record = record(state, name, uid)
    cancel(record.timer)
    put_record(state, name, %{record | timer: nil})
  end

  defp answer_probes(%{probes: []} = state), do: state

  defp answer_probes(state) do
    quiet? =
      map_size(state.in_flight) == 0 and (state.queued == [] or state.shutdown?.())

    {answered, waiting} =
      Enum.split_with(state.probes, fn {_reply_to, _ref, timers} ->
        quiet? and (timers == :any or Enum.all?(state.known, &(elem(&1, 1).timer == nil)))
      end)

    for {reply_to, ref, _timers} <- answered, do: send(reply_to, {ref, self(), state.steps})
    %{state | probes: waiting}
  end
end
