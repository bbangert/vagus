defmodule Vagus.Resource.Runtime do
  @moduledoc """
  Runs one controller against the resources of its kind.

  It owns a queue of resource names with at most one step in flight per
  name, the timers and failure counts of those names, and an index of which
  other resources each one refers to. None of it is durable and none needs
  to be: a start lists the kind and looks at everything.

  A step (`Vagus.Resource.Runtime.Step`) runs in a task under the
  controller's own `Task.Supervisor`. A change that arrives while a name's
  step is in flight marks the name dirty and it runs once more afterwards,
  however many changes there were: notifications become set members, never
  queued work. A step that crashes frees its name and is retried with
  back-off.

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
      action, for a harness that interrupts there

  Three options take a mechanism away, to prove that a test suite notices:
  `deliver_events: false` drops change notifications, `ignore_dirty: true`
  forgets a change that arrives during a step, and `skip_collector: true`
  collects nothing.
  """

  use GenServer

  require Logger

  alias Vagus.Host.Shutdown
  alias Vagus.Resource
  alias Vagus.Resource.{Clock, Collector, Controller, Store, Watch}
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
  resting for a shutdown counts as having nothing queued.

  Sent through `Vagus.Resource.Store.relay/3` it arrives behind every
  notification the store has sent, so the answer covers them.
  """
  @spec quiet_probe(pid(), reference()) :: term()
  def quiet_probe(reply_to, ref) when is_pid(reply_to) and is_reference(ref),
    do: {__MODULE__, :quiet?, reply_to, ref}

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
    skip_collector = Keyword.get(opts, :skip_collector, false)

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
      ignore_dirty: Keyword.get(opts, :ignore_dirty, false),
      skip_collector: skip_collector,
      step: %{
        runtime: self(),
        controller: controller,
        kind: kind,
        owner?: owner?,
        instance: instance,
        i: [instance: instance],
        clock: clock,
        shutdown?: shutdown?,
        skip_collector: skip_collector,
        context: Keyword.get(opts, :context, %{}),
        strict:
          Keyword.get_lazy(opts, :strict_verdicts, fn ->
            Application.get_env(:vagus, :strict_verdicts, false)
          end),
        boundary: Keyword.get(opts, :boundary),
        types: Controller.conditions(controller),
        retention: Controller.optional(controller, :retention, [], nil),
        finalize_after: Controller.optional(controller, :finalize_after, [], [])
      },
      queued: %{},
      in_flight: %{},
      refs: %{},
      dirty: MapSet.new(),
      timers: %{},
      failures: %{},
      failed: %{},
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

    :ok =
      if state.owner?,
        do: Store.register_kind(kind, controller, declared),
        else: Store.register_writer(kind, controller, declared)

    :ok = Watch.subscribe({:kind, kind}, i)
    {:noreply, state |> schedule_resync() |> relist() |> dispatch()}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_cast(:resync, state), do: {:noreply, state |> relist() |> settle()}

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
    do: {:noreply, state |> schedule_resync() |> relist() |> settle()}

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

  def handle_info({__MODULE__, :quiet?, reply_to, ref}, state),
    do: {:noreply, answer_probes(%{state | probes: [{reply_to, ref} | state.probes]})}

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
      queued: state.queued |> Map.keys() |> Enum.sort(),
      in_flight: Map.new(state.in_flight, fn {name, task} -> {name, task.pid} end),
      dirty: state.dirty |> MapSet.to_list() |> Enum.sort(),
      timers: state.timers |> Map.keys() |> Enum.sort(),
      failures: state.failures,
      references: state.refs_out,
      steps: state.steps
    }
  end

  defp own(state, :changed, name), do: state |> reindex(name) |> enqueue(name)
  defp own(state, :removed, name), do: forget(state, name)

  defp schedule_resync(%{resync: :infinity} = state), do: state

  defp schedule_resync(state) do
    Process.send_after(self(), :resync, state.resync)
    state
  end

  defp relist(state) do
    names = for resource <- Store.list(state.kind, state.i), do: resource.name
    state = Enum.reduce(names, state, &(&2 |> reindex(&1) |> enqueue(&1)))

    # What a missed removal notice left behind.
    [state.timers, state.failures, state.failed, state.refs_out]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Kernel.--(names)
    |> Enum.reduce(state, &forget(&2, &1))
  end

  defp forget(state, name) do
    state = state |> cancel_timer(name) |> index(name, [])

    %{
      state
      | queued: Map.delete(state.queued, name),
        failures: Map.delete(state.failures, name),
        failed: Map.delete(state.failed, name)
    }
  end

  defp reindex(state, name) do
    case Store.get(state.kind, name, state.i) do
      nil -> index(state, name, [])
      resource -> index(state, name, references(state, resource))
    end
  end

  # An owner or a field's writer is referred to as well: its removal is what
  # the collector acts on.
  defp references(state, resource) do
    declared = declared(state, :references, resource, Map.get(state.refs_out, resource.name, []))

    owed =
      if state.owner? and not state.skip_collector,
        do: Collector.dependencies(resource),
        else: []

    Enum.uniq(declared ++ owed) -- [{state.kind, resource.name}]
  end

  defp index(state, name, keys) do
    old = Map.get(state.refs_out, name, [])

    refs_in =
      Enum.reduce(old -- keys, state.refs_in, fn key, refs_in ->
        case List.delete(Map.fetch!(refs_in, key), name) do
          [] -> Map.delete(refs_in, key)
          names -> Map.put(refs_in, key, names)
        end
      end)

    refs_in =
      Enum.reduce(
        keys -- old,
        refs_in,
        &Map.update(&2, &1, [name], fn names -> [name | names] end)
      )

    refs_out =
      if keys == [],
        do: Map.delete(state.refs_out, name),
        else: Map.put(state.refs_out, name, keys)

    watch(%{state | refs_in: refs_in, refs_out: refs_out}, keys)
  end

  defp watch(state, keys) do
    kinds =
      for {kind, _name} <- keys, not MapSet.member?(state.watched, kind), uniq: true, do: kind

    for kind <- kinds, do: :ok = Watch.subscribe({:kind, kind}, state.i)
    %{state | watched: Enum.into(kinds, state.watched)}
  end

  # `references/1` and `priority/1` are the controller's code run in this
  # process, on every change notice, where a step cannot do it: the index
  # has to know a reference before the change it concerns arrives. What they
  # raise or return wrongly costs the default, not the runtime.
  defp declared(state, callback, resource, default) do
    value = Controller.optional(state.controller, callback, [resource], default)

    valid? =
      case callback do
        :references ->
          Enum.all?(value, &match?({kind, name} when is_atom(kind) and is_binary(name), &1))

        :priority ->
          is_integer(value)
      end

    if valid?, do: value, else: raise(ArgumentError, "returned #{inspect(value)}")
  rescue
    exception ->
      Logger.error(
        "#{inspect(state.controller)}.#{callback}/1 on #{state.kind}/#{resource.name}: " <>
          Exception.message(exception)
      )

      default
  end

  defp priority(state, name) do
    with true <- function_exported?(state.controller, :priority, 1),
         %Resource{} = resource <- Store.get(state.kind, name, state.i) do
      declared(state, :priority, resource, 0)
    else
      _none -> 0
    end
  end

  defp enqueue(state, name) do
    cond do
      not is_map_key(state.in_flight, name) ->
        %{state | queued: Map.put(state.queued, name, priority(state, name))}

      state.ignore_dirty ->
        state

      true ->
        %{state | dirty: MapSet.put(state.dirty, name)}
    end
  end

  defp settle(state), do: state |> dispatch() |> answer_probes()

  defp dispatch(%{queued: queued} = state) when map_size(queued) == 0, do: state

  defp dispatch(state) do
    if state.shutdown?.() do
      # Nothing announces the end of a shutdown that did not happen.
      timer = state.gate_timer || Process.send_after(self(), :gate, state.gate_poll)
      %{state | gate_timer: timer}
    else
      state.queued
      |> Enum.sort_by(fn {name, priority} -> {priority, name} end)
      |> Enum.reduce(%{state | queued: %{}}, &start_step/2)
    end
  end

  defp start_step({name, priority}, state) do
    step =
      Map.merge(state.step, %{
        name: name,
        priority: priority,
        failed_action: Map.get(state.failed, name)
      })

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

    state =
      cancel_timer(
        %{
          state
          | refs: refs,
            in_flight: Map.delete(state.in_flight, name),
            dirty: MapSet.delete(state.dirty, name)
        },
        name
      )

    # The store writes its table before it sends a notice. So a resource
    # missing here is gone, whatever this step or a notice not yet read
    # says, and one created after this read has its own notice still to come.
    if Store.get(state.kind, name, state.i) == nil do
      forget(state, name)
    else
      state = outcome(state, name, result)
      if dirty?, do: enqueue(state, name), else: state
    end
  end

  defp outcome(state, name, {:ok, next}) do
    next(
      %{
        state
        | failures: Map.delete(state.failures, name),
          failed: Map.delete(state.failed, name)
      },
      name,
      next
    )
  end

  # Not a failure: nothing was tried. The failed action of the pass before
  # is kept for the next pass that can observe.
  defp outcome(state, name, {:unavailable, next}) do
    ms =
      case next do
        {:after, ms} -> min(ms, state.unavailable_retry)
        _other -> state.unavailable_retry
      end

    arm(state, name, ms)
  end

  # The controller counts these and paces its own retries, so the next pass
  # is at once, to let its verdict say what happened. Should that pass end
  # the same way, nothing is pacing them, and the back-off does.
  defp outcome(state, name, {:action_failed, failure}) do
    count = Map.get(state.failures, name, 0) + 1

    state = %{
      state
      | failures: Map.put(state.failures, name, count),
        failed: Map.put(state.failed, name, failure)
    }

    if count == 1, do: enqueue(state, name), else: arm(state, name, backoff(state, count - 1))
  end

  defp outcome(state, name, :gated), do: enqueue(state, name)
  defp outcome(state, _name, :gone), do: state

  defp outcome(state, name, crashed) do
    count = Map.get(state.failures, name, 0) + 1
    ms = backoff(state, count)

    Logger.warning(
      "#{inspect(state.controller)}: step for #{state.kind}/#{name} failed (#{count}), " <>
        "again in #{ms} ms: #{inspect(crashed)}"
    )

    arm(%{state | failures: Map.put(state.failures, name, count)}, name, ms)
  end

  defp backoff(%{backoff: {base, max}}, count),
    do: min(base * Integer.pow(2, min(count - 1, 20)), max)

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
    if map_size(state.in_flight) == 0 and (map_size(state.queued) == 0 or state.shutdown?.()) do
      for {reply_to, ref} <- state.probes, do: send(reply_to, {ref, self(), state.steps})
      %{state | probes: []}
    else
      state
    end
  end
end
