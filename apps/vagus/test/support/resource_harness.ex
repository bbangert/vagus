defmodule Vagus.Resource.Harness do
  @moduledoc """
  A private resource subtree per test, with controllers running in it, and
  the ways to wait for it that do not sleep.

  A system is a map: `instance` and `i` (the `instance:` option every store
  function takes), `controllers`, `clock` (a `Vagus.Resource.TestClock`),
  `world` and `wait` (the timeout of every wait here, in milliseconds).

  The world stands in for whatever the controllers under test act on: facts
  a toy controller's `observe/2` reads and its `act/3` writes
  (`fact/2`, `put_fact/3`), a journal of the actions performed
  (`record/3`, `journal/1`) and a list for anything else worth asserting on
  (`note/2`, `notes/1`). Controllers get it as `context.world`, and the test
  process as `context.test`.

  By default nothing resyncs, so a test that passes does so on change
  notifications alone; a test about a missed one turns resync on.

  ## Mutations

  With `VAGUS_RESOURCE_MUTATION` set, every runtime is started with one of
  its mechanisms taken away or one of its rules broken, whatever the test
  asked for: `deliver_events`, `resync`, `ignore_dirty`, `skip_collector`,
  `double_step`, `stamp_current_generation` or `repeat_action` (see
  `Vagus.Resource.Runtime`). `mix test.mutations` runs the scenario tests
  once per value and requires them to fail.

  A mutated run should fail on what the runtime did, not on a wait running
  out, and where the mutation makes the runtime do something wrong it does.
  Where it makes the runtime not do something (`deliver_events`, `resync`,
  `ignore_dirty`, `skip_collector`) the failure is a wait that ends, there
  being nothing else to see; every wait is `wait`, shortened for such a run.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1, stop_supervised!: 1]

  alias Vagus.Resource
  alias Vagus.Resource.{Controller, Controllers, Runtime, Store, Tables, TestClock, TestInstance}
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Resource.Verdict

  @mutation_env "VAGUS_RESOURCE_MUTATION"

  @type system :: %{
          instance: atom(),
          i: keyword(),
          controllers: [module()],
          clock: pid(),
          world: pid(),
          gate: :atomics.atomics_ref(),
          faults: pid() | nil,
          wait: pos_integer()
        }

  @doc """
  Starts the whole subtree. Options: `:controllers`; `:kinds`, for kinds no
  controller owns; `:resync` (default `:infinity`); `:runtime`, further
  `Vagus.Resource.Runtime` options; `:context`; `:lanes`; `:path` and
  `:persist` for the store; `:faults`, see `Vagus.Resource.Harness.Faults`.

  Steps that crash are retried after 1 to 8 ms unless `:runtime` sets
  `:backoff`, and verdicts are checked strictly. The system is settled when
  this returns.
  """
  @spec start_system(keyword()) :: system()
  def start_system(opts \\ []) do
    instance = TestInstance.name()
    controllers = Keyword.get(opts, :controllers, [])
    clock = start_supervised!(Supervisor.child_spec(TestClock, id: {instance, :clock}))

    world =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> %{facts: %{}, journal: [], notes: []} end},
          id: {instance, :world}
        )
      )

    faults =
      if mode = opts[:faults],
        do:
          start_supervised!(
            Supervisor.child_spec({Faults, {instance, mode}}, id: {instance, :faults})
          )

    gate = :atomics.new(1, [])

    runtime =
      [
        clock: TestClock.clock(clock),
        shutdown?: fn -> :atomics.get(gate, 1) == 1 end,
        resync: Keyword.get(opts, :resync, :infinity),
        gate_poll: 5,
        unavailable_retry: 5,
        backoff: {1, 8},
        strict_verdicts: true,
        boundary: faults && (&Faults.boundary(faults, &1)),
        context: Map.merge(%{world: world, test: self()}, Keyword.get(opts, :context, %{}))
      ]
      |> Keyword.merge(Keyword.get(opts, :runtime, []))
      |> Keyword.merge(mutation())

    tree =
      [
        instance: instance,
        controllers: controllers,
        runtime: runtime,
        kinds: Keyword.get(opts, :kinds, %{}),
        lanes: Keyword.get(opts, :lanes)
      ] ++ Keyword.take(opts, [:path, :persist])

    start_supervised!(Supervisor.child_spec({Resource.Supervisor, tree}, id: instance))

    sys = %{
      instance: instance,
      i: [instance: instance],
      controllers: controllers,
      clock: clock,
      world: world,
      gate: gate,
      faults: faults,
      wait: if(mutation() == [], do: 5_000, else: 1_000)
    }

    # A runtime lists its kind after it has started. Until it has, a resource
    # the test creates may be found by that listing instead of being
    # announced, and a test about notifications would pass without them.
    settle(sys)
    sys
  end

  @spec stop_system(system()) :: :ok
  def stop_system(sys) do
    stop_supervised!(sys.instance)
    for part <- [:faults, :world, :clock], sys[part], do: stop_supervised!({sys.instance, part})
    :ok
  end

  defp mutation do
    case System.get_env(@mutation_env) do
      nil -> []
      "deliver_events" -> [deliver_events: false]
      "resync" -> [skip_resync: true]
      "ignore_dirty" -> [ignore_dirty: true]
      "skip_collector" -> [skip_collector: true]
      "double_step" -> [double_step: true]
      "stamp_current_generation" -> [stamp_current_generation: true]
      "repeat_action" -> [repeat_action: true]
    end
  end

  @doc "Makes every runtime believe the host is shutting down, or no longer."
  @spec shutdown(system(), boolean()) :: :ok
  def shutdown(sys, in_flight?), do: :atomics.put(sys.gate, 1, if(in_flight?, do: 1, else: 0))

  @doc """
  Returns once the system is at rest: in every runtime nothing is queued and
  nothing in flight, and no change is on its way to any of them. `only:`
  limits it to some controllers, which then says nothing about the others.

  Each runtime is asked through the store (`Vagus.Resource.Store.relay/3`),
  so its answer comes after it has read every notification the store had
  sent. It answers when quiet, with the number of steps it has ever started.
  The system is at rest when two rounds in a row get the same numbers from
  the same processes: when the second round's question left the store, no
  step was running anywhere, since each runtime was quiet before and started
  nothing until after, and every notification sent by then was answered
  without a step. Nothing is left that could cause one.

  Timers are not waited for: a resource that asked to be looked at again
  later is at rest until then, and may no longer be when the test looks.
  `timers: :none` waits them out as well, and returns only when no runtime
  has one pending; a test that goes on to read a runtime's state asks for
  that, or uses timers too long to fire. Nothing the test itself started is
  waited for. A runtime may only be killed through this module while a
  settle runs.
  """
  @spec settle(system(), keyword()) :: :ok
  def settle(sys, opts \\ []) do
    controllers = Keyword.get(opts, :only, sys.controllers)
    deadline = System.monotonic_time(:millisecond) + sys.wait
    settle(sys, {controllers, Keyword.get(opts, :timers, :any)}, nil, deadline)
  end

  defp settle(sys, asked, previous, deadline) do
    case round(sys, asked, deadline) do
      {:ok, ^previous} -> :ok
      {:ok, answers} -> settle(sys, asked, answers, deadline)
      :restarted -> settle(sys, asked, nil, deadline)
    end
  end

  defp round(sys, {controllers, timers}, deadline) do
    # A kill by the fault harness is finished, replacement included, before
    # this returns. One that begins right after it shows below as a name
    # with no process or as a process going down, and the round is taken
    # again.
    if sys.faults, do: Faults.report(sys.faults)
    found = for controller <- controllers, do: {controller, runtime(sys, controller)}

    case Enum.find(found, &(elem(&1, 1) == nil)) do
      nil -> probe(sys, found, timers, deadline)
      {_controller, nil} when sys.faults != nil -> :restarted
      {controller, nil} -> flunk("no runtime for #{inspect(controller)}")
    end
  end

  defp runtime(sys, controller), do: Process.whereis(Runtime.name(sys.instance, controller))

  defp probe(sys, found, timers, deadline) do
    runtimes = for {controller, pid} <- found, do: {controller, pid, Process.monitor(pid)}
    ref = make_ref()
    message = Runtime.quiet_probe(self(), ref, timers: timers)
    :ok = Store.relay(Enum.map(found, &elem(&1, 1)), message, sys.i)
    answers = Enum.map(runtimes, &answer(sys, &1, ref, deadline))
    for {_controller, _pid, monitor} <- runtimes, do: Process.demonitor(monitor, [:flush])

    if :restarted in answers, do: :restarted, else: {:ok, answers}
  end

  defp answer(sys, {controller, pid, monitor}, ref, deadline) do
    receive do
      # With the pid: a replacement that happens to have started as many
      # steps is not the runtime that answered before.
      {^ref, ^pid, steps} ->
        {pid, steps}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        if sys.faults == nil,
          do:
            flunk("the runtime of #{inspect(controller)} died while settling: #{inspect(reason)}")

        :restarted
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("""
        the runtime of #{inspect(controller)} never came to rest:
        #{inspect(Runtime.info(controller, sys.i), pretty: true)}
        """)
    end
  end

  @doc """
  A runtime's `Vagus.Resource.Runtime.info/2`, taken after it has read every
  notification the store had sent it. For looking at a runtime that is not
  at rest; after `settle/2` the plain call says the same.
  """
  @spec info(system(), module()) :: Runtime.info()
  def info(sys, controller) do
    pid = Process.whereis(Runtime.name(sys.instance, controller))
    ref = make_ref()
    :ok = Store.relay([pid], Runtime.info_probe(self(), ref), sys.i)

    receive do
      {^ref, ^pid, info} -> info
    after
      sys.wait -> flunk("the runtime of #{inspect(controller)} did not answer")
    end
  end

  @doc "Has a controller look at everything again; returns once its runtime has started to."
  @spec resync(system(), module()) :: :ok
  def resync(sys, controller) do
    :ok = Runtime.resync(controller, sys.i)
    # From the same process as the cast, so behind it.
    _info = Runtime.info(controller, sys.i)
    :ok
  end

  @doc """
  Waits for something about one resource, and returns the resource. `what`
  is a condition type, which must be true and about the current generation;
  `{type, status}`; `:gone`; or a function of the resource (or `nil`).
  Raises with what the resource last looked like.
  """
  @spec await!(system(), Resource.kind(), Resource.name(), term()) :: Resource.t() | nil
  def await!(sys, kind, name, what) do
    reached? = reached(what)
    halt = fn resource -> if reached?.(resource), do: {:halt, resource}, else: :cont end

    case Store.await(kind, name, halt, [timeout: sys.wait] ++ sys.i) do
      {:ok, resource} ->
        resource

      {:error, {:timeout, last}} ->
        flunk("""
        #{kind}/#{name} never reached #{inspect(what)}. Last seen:
        #{inspect(last, pretty: true)}
        """)
    end
  end

  defp reached(fun) when is_function(fun, 1), do: fun
  defp reached(:gone), do: &is_nil/1
  defp reached(type) when is_atom(type), do: reached({type, true})

  defp reached({type, status}) do
    fn
      nil ->
        false

      %Resource{generation: generation} = resource ->
        match?(
          %{status: ^status, observed_generation: ^generation},
          Resource.get_condition(resource, type)
        )
    end
  end

  @doc """
  Creates a resource, waits for its condition (`:condition`, default
  `:ready`) and for the system to settle, so that what the test does next
  starts from rest; `settle: false` for a system that cannot come to rest.
  Other options are `Vagus.Resource.Store.create/4`'s.
  """
  @spec given_ready(system(), {Resource.kind(), Resource.name(), map()}, keyword()) ::
          Resource.t()
  def given_ready(sys, {kind, name, spec}, opts \\ []) do
    {condition, opts} = Keyword.pop(opts, :condition, :ready)
    {settle?, create} = Keyword.pop(opts, :settle, true)
    {:ok, _resource} = Store.create(kind, name, spec, create ++ sys.i)
    await!(sys, kind, name, condition)
    if settle?, do: settle(sys)
    Store.get(kind, name, sys.i)
  end

  @doc "Kills a controller's runtime and returns its replacement, once it is in place."
  @spec kill_runtime(system(), module()) :: pid()
  def kill_runtime(sys, controller) do
    name = Runtime.name(sys.instance, controller)
    old = Process.whereis(name)
    pair = Process.whereis(Controllers.Supervisor.pair(sys.instance, controller))
    TestInstance.kill_observed(old, pair)
    new = Process.whereis(name)
    true = is_pid(new) and new != old
    new
  end

  @spec restart_store(system()) :: pid()
  def restart_store(sys), do: TestInstance.restart_store(sys.instance)

  @doc "Every resource, in key order."
  @spec snapshot(system()) :: [Resource.t()]
  def snapshot(sys) do
    rows = :ets.select(Tables.resources(sys.instance), [{{{:_, :_}, :"$1"}, [], [:"$1"]}])
    Enum.sort_by(rows, &{&1.kind, &1.name})
  end

  @spec fact(%{world: pid()}, term()) :: term()
  def fact(%{world: world}, key), do: Agent.get(world, & &1.facts[key])

  @spec put_fact(%{world: pid()}, term(), term()) :: :ok
  def put_fact(%{world: world}, key, value),
    do: Agent.update(world, &put_in(&1.facts[key], value))

  @doc """
  Adds an action to the journal, under the resource it was done for: `key`
  is `{controller, name}`, which is how the fault harness knows whose
  actions an interruption may have repeated.
  """
  @spec record(%{world: pid()}, term(), term()) :: :ok
  def record(%{world: world}, key, action),
    do: Agent.update(world, &%{&1 | journal: [{key, action} | &1.journal]})

  @doc "The actions, oldest first, as `{key, action}`."
  @spec journal(%{world: pid()}) :: [{term(), term()}]
  def journal(%{world: world}), do: Agent.get(world, &Enum.reverse(&1.journal))

  @spec note(%{world: pid()}, term()) :: :ok
  def note(%{world: world}, term), do: Agent.update(world, &%{&1 | notes: [term | &1.notes]})

  @doc "The notes, oldest first, and forgets them."
  @spec notes(%{world: pid()}) :: [term()]
  def notes(%{world: world}),
    do: Agent.get_and_update(world, &{Enum.reverse(&1.notes), %{&1 | notes: []}})

  @doc "A resource to hand to `reconcile/2` in a table. `fields` are struct fields."
  @spec resource(Resource.kind(), Resource.name(), map(), keyword()) :: Resource.t()
  def resource(kind, name, spec, fields \\ []) do
    struct!(%Resource{kind: kind, name: name, uid: 1, spec: spec}, fields)
  end

  @doc """
  The contract every controller's `reconcile/2` is held to, over a table of
  `{resource, observation}` rows: it returns a verdict whose condition types
  are exactly the ones the controller declared, in a shape the runtime
  accepts, and effects the runtime can apply. A row for a pass with nothing
  to report is `{resource, observation, :no_verdict}`.
  """
  @spec assert_verdict_contract(module(), [tuple()]) :: :ok
  def assert_verdict_contract(controller, rows) do
    types = Enum.sort(Controller.conditions(controller))

    for row <- rows do
      {resource, observation} = {elem(row, 0), elem(row, 1)}
      {verdict, effects} = controller.reconcile(resource, observation)
      where = "#{inspect(controller)}.reconcile(#{inspect(resource)}, #{inspect(observation)})"

      case row do
        {_resource, _observation, :no_verdict} ->
          assert verdict == :no_verdict, "#{where} returned a verdict"

        {_resource, _observation} ->
          assert %Verdict{} = verdict, "#{where} returned no verdict"

          assert Enum.sort(Map.keys(verdict.conditions)) == types,
                 "#{where} must report #{inspect(types)}"

          assert Verdict.problems(verdict, types, Controller.owner?(controller)) == []
      end

      assert effects |> Enum.reject(&Controller.effect?/1) == [], "#{where} returned a non-effect"
    end

    :ok
  end
end

defmodule Vagus.Resource.Harness.Faults do
  @moduledoc """
  Kills a runtime at a chosen point of a scenario, to show that the scenario
  ends the same wherever it is interrupted.

  A step has a boundary after each action and after each commit that
  changed something: the places a crash can fall, since a commit is all or
  none. A commit that changed nothing, as the store reports it, is not one:
  the store is as it was before the pass, so a kill there is a kill before
  the pass, which is the boundary before. Leaving those out is also what makes a scenario cross the
  same boundaries each time, since how many passes find nothing to write
  depends on how the notifications happened to fall. A boundary is named by
  the controller, the resource and which of the two it follows, and by how
  many of that name came before it. `each_boundary/1` runs the scenario once
  undisturbed, keeping the boundaries crossed, the final store and the
  journal. Then, for each of those boundaries, it runs the scenario in a
  fresh system in which the runtime whose step crosses that boundary is
  killed there, with the step; its supervisor replaces it, and the run must
  end with the same store and an equivalent journal.

  Every one of those kills must happen. A run that never reaches its
  boundary fails, so a scenario has to cross the same boundaries each time:
  it settles between the things it does.

  ## Equivalent journals

  Actions are idempotent against observation, so an interrupted pass may do
  again what it had already done, and nothing else. Per resource, an
  interrupted journal is equivalent to the undisturbed one when it is that
  journal with one replay in it (`replay?/2`): it follows the reference up
  to some point, goes back to an earlier point, and follows it from there to
  the end. `a b b c` and `a b a b c` are replays of `a b c`. A missing
  action, an action the reference does not have, another order, or a repeat
  that is not a re-run from an earlier point is a difference, as is any
  repeat in a resource of a controller that was not killed, since its replay
  is then empty. The reference is taken as it is: what it repeats, the
  interrupted run must repeat.

  A replay is allowed only in the resources of the controller that was
  killed. Every other controller's actions must be exactly the reference's:
  its runtime lost nothing, and what it acts on is what it observes, which a
  replayed action, being idempotent, does not change. If such a controller
  repeats or adds an action after another was interrupted, it is acting on
  something that the interruption made visible for longer or that a replay
  disturbed, and either is a defect in one of the two, not a tolerance to
  grant.

  Only the order within one resource is compared: independent runtimes
  interleave differently on every run, interrupted or not. And a boundary is
  never inside `act/3`: an action that is itself several steps, and breaks
  when cut between them, is not found here.

  This process records the boundaries and does the killing, so that both
  happen one at a time: a step that reports a boundary waits in the call
  while it is recorded, and is still waiting when it is killed.
  """

  use GenServer

  import ExUnit.Assertions

  alias Vagus.Resource.{Controllers, Harness, TestInstance}

  @typedoc "`{controller, resource name, :commit | :action}`"
  @type label :: {module(), String.t(), :commit | :action}
  @type mode :: :count | {:kill_at, {label(), pos_integer()}}

  @doc """
  Options: `:scenario`, a function of the system that drives it and waits
  for what it needs; `:system`, `Vagus.Resource.Harness.start_system/1`
  options; `:normalize`, applied to each final store before comparing;
  `:equivalent`, a function of one resource's reference and interrupted
  actions in place of `replay?/2`, for the killed controller's resources.

  Returns the undisturbed run: `store`, `journal` (actions per resource) and
  `boundaries` (labels in the order crossed).
  """
  @spec each_boundary(keyword()) :: %{store: term(), journal: map(), boundaries: [label()]}
  def each_boundary(opts) do
    scenario = Keyword.fetch!(opts, :scenario)
    system = Keyword.get(opts, :system, [])
    normalize = Keyword.get(opts, :normalize, & &1)
    equivalent = Keyword.get(opts, :equivalent, &replay?/2)
    reference = run(system, :count, scenario, normalize)

    if reference.boundaries == [],
      do: flunk("the scenario crosses no boundary, so there is nowhere to interrupt it")

    targets =
      for {label, crossed} <- Enum.frequencies(reference.boundaries),
          nth <- 1..crossed,
          do: {label, nth}

    for {{killed, _name, kind} = label, nth} = target <- Enum.sort(targets) do
      interrupted = run(system, {:kill_at, target}, scenario, normalize)
      where = "killed after #{inspect(label)} ##{nth}"

      case interrupted.kill do
        :done -> :ok
        nil -> flunk("#{where}: the run never crossed that boundary")
        {:error, reason} -> flunk("#{where}: the kill did not happen: #{reason}")
      end

      assert interrupted.store == reference.store, "#{where}: the store ends differently"

      for key <- Enum.uniq(Map.keys(reference.journal) ++ Map.keys(interrupted.journal)) do
        {expected, found} = {reference.journal[key] || [], interrupted.journal[key] || []}

        same? =
          if match?({^killed, _name}, key),
            do: equivalent.(expected, found),
            else: expected == found

        assert same?, """
        #{where}: the actions for #{inspect(key)} differ.
        undisturbed: #{inspect(expected)}
        interrupted: #{inspect(found)}
        """
      end

      kind
    end
    |> Enum.uniq()
    |> Enum.sort()
    |> then(fn killed ->
      crossed = reference.boundaries |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()

      assert killed == crossed,
             "boundaries of kind #{inspect(crossed -- killed)} were never killed"
    end)

    reference
  end

  defp run(system, mode, scenario, normalize) do
    sys = Harness.start_system([faults: mode] ++ system)
    scenario.(sys)
    Harness.settle(sys)
    journal = sys |> Harness.journal() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    report = report(sys.faults)
    store = normalize.(Harness.snapshot(sys))
    Harness.stop_system(sys)
    %{store: store, journal: journal, boundaries: report.crossed, kill: report.kill}
  end

  @doc """
  Whether `interrupted` is `reference` with one replay: for some `j <= i`,
  the first `i` of the reference followed by the reference from `j` on.
  """
  @spec replay?(list(), list()) :: boolean()
  def replay?(reference, interrupted) do
    size = length(reference)

    Enum.any?(0..size, fn i ->
      Enum.any?(0..i, fn j ->
        interrupted == Enum.take(reference, i) ++ Enum.drop(reference, j)
      end)
    end)
  end

  @spec start_link({atom(), mode()}) :: GenServer.on_start()
  def start_link({instance, mode}), do: GenServer.start_link(__MODULE__, {instance, mode})

  @doc "The runtime's `:boundary` option."
  @spec boundary(pid(), map()) :: :ok
  def boundary(faults, info), do: GenServer.call(faults, {:boundary, info}, :infinity)

  @doc """
  The boundaries crossed so far, and what became of the kill: `nil` while it
  has not been reached, `:done`, or `{:error, reason}`. Returns after a kill
  in progress has been replaced.
  """
  @spec report(pid()) :: %{crossed: [label()], kill: nil | :done | {:error, String.t()}}
  def report(faults), do: GenServer.call(faults, :report, 30_000)

  @impl true
  def init({instance, mode}), do: {:ok, %{instance: instance, mode: mode, crossed: [], kill: nil}}

  @impl true
  def handle_call({:boundary, %{after: :idle_commit}}, _from, state), do: {:reply, :ok, state}

  def handle_call({:boundary, info}, _from, state) do
    label = {info.controller, info.name, info.after}
    state = %{state | crossed: [label | state.crossed]}

    if state.mode == {:kill_at, {label, Enum.count(state.crossed, &(&1 == label))}} do
      case kill(state.instance, info) do
        # No reply: the step that asked died with its runtime.
        :done -> {:noreply, %{state | kill: :done}}
        # The step goes on, and the run is failed by its report.
        error -> {:reply, :ok, %{state | kill: error}}
      end
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:report, _from, state),
    do: {:reply, %{crossed: Enum.reverse(state.crossed), kill: state.kill}, state}

  # The check only names the commonest way for the kill to fail. One that
  # fails later, the runtime dying of something else in between, raises in
  # `kill_observed/2` and is reported the same way.
  defp kill(instance, %{runtime: runtime, controller: controller}) do
    if Process.alive?(runtime) do
      pair = Process.whereis(Controllers.Supervisor.pair(instance, controller))
      TestInstance.kill_observed(runtime, pair)
      :done
    else
      {:error, "the runtime of #{inspect(controller)} was already dead"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
