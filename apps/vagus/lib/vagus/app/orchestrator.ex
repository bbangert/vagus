defmodule Vagus.App.Orchestrator do
  @moduledoc """
  Brings the apps and Core up at boot and down at shutdown, in upstream's
  stage order. It holds only the sequence in flight; the sequence runs in a
  task. Every step is idempotent, so a boot task that crashes stops this
  process, and its supervisor's restart simply boots again.

  Its start sweeps the staging an interrupted backup or restore left
  (`Vagus.App.Units.sweep/0`, once per VM and only when it boots), imports
  the apps an older Vagus recorded (`Vagus.App.File`) and ensures a process
  per saved app, whether or not it then boots.

  Boot:

    1. the default native app is installed if missing, and on that fresh
       install recorded as wanted started;
    2. the `tree` gate, then native apps get their boot rule: they need no
       engine, so an offline boot still brings the broker up;
    3. the `engine`, `network` and `api` gates (`Vagus.App.Gates`), each
       retried until it passes or its tries run out, then carried past;
    4. the stages, each awaited up to its budget, then carried past:

       | config `startup`      | stage         |
       | --------------------- | ------------- |
       | `initialize`          | `initialize`  |
       | `system`              | `system`      |
       | `services`            | `services`    |
       | (Home Assistant Core) | `core`        |
       | `application`, `once` | `application` |

       each app is sent `boot_start` with whether its container runs, from
       one listing taken after the `engine` gate (`:unknown` if it fails),
       and applies its own boot rule (`Vagus.App.Policy.boot/2`); `once`
       apps are not awaited;
    5. `supervisor_update` with `startup: complete`, which Core takes as the
       Supervisor having finished starting.

  A shutdown pre-empts a boot only at a step boundary: before a gate or a
  stage, or while a gate waits out its interval. A unit in flight is never
  killed: Core's start may be midway through stop, remove, create and start,
  and a killed one leaves Core absent, which the next boot cannot repair
  since boot never creates Core. Units are bounded on their own (a gate
  check by `gate_timeout`, a stage by `stage_timeout`), so that is the
  longest a shutdown waits; a unit still running past its stage budget is
  left to finish beside the stop.

  Shutdown sends `halt` to the `application` stage, then stops Core, then
  halts every earlier stage, each group all at once. A halted app stops its
  container by name and keeps what it wants, so the next boot starts the
  same apps; it refuses commands until `resume`. Core stops by a deadline
  that leaves the earlier group its own bound within the caller's budget.
  Native apps keep running. The stop runs outside this process, so a crash
  here does not cut it short; a restart while `Vagus.Host.Shutdown` is in
  flight does not boot, and answers `shutdown/2` and `resume/1` as after any
  stop. A boot after a stop that did not take the device down resumes each
  halted app in its stage.

  A user's stop of the default broker survives a reboot: it starts only on a
  fresh install or when it is wanted started. With `boot: false` nothing is
  ever given its boot rule. `Vagus.Provisioner`'s first-boot Core start stays
  its own, outside these stages.
  """

  use GenServer

  require Logger

  alias Vagus.App.Units

  @stage_of %{
    "initialize" => :initialize,
    "system" => :system,
    "services" => :services,
    "application" => :application,
    "once" => :application
  }

  @plan [gate: :tree, stage: :native, gate: :engine, gate: :network, gate: :api] ++
          Enum.map([:initialize, :system, :services, :core, :application], &{:stage, &1})

  @defaults [
    boot: false,
    default_native_app: nil,
    gate_tries: 60,
    gate_interval: 5_000,
    tree_interval: 250,
    gate_timeout: 10_000,
    stage_timeout: 120_000,
    app_stop_timeout: 35_000,
    stop_margin: 5_000,
    units: %{}
  ]

  @degraded {{0, 0}, {:error, :not_run}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Pre-empts a boot in flight, then stops within `budget_ms`.
  `{{apps_stopped, apps_running}, core_result}`. No call timeout: the
  caller's budget is the deadline.
  """
  @spec shutdown(GenServer.server(), timeout()) ::
          {{non_neg_integer(), non_neg_integer()}, term()}
  def shutdown(server \\ __MODULE__, budget_ms \\ :infinity),
    do: GenServer.call(server, {:shutdown, budget_ms}, :infinity)

  @doc "Boots again after a shutdown that did not take the device down."
  @spec resume(GenServer.server()) :: :ok
  def resume(server \\ __MODULE__), do: GenServer.cast(server, :resume)

  @doc """
  Called by an app process as it starts: applies the boot rule to its app,
  once boot is over. Mid-boot, one that announced before its stage began is
  left to that stage, and any other is given the rule when boot ends. Its
  container is inspected first, so a wanted one still running is started
  again under a token the new process holds.
  """
  @spec up(String.t(), GenServer.server()) :: :ok
  def up(slug, server \\ __MODULE__),
    do: GenServer.cast(server, {:up, slug, System.unique_integer([:monotonic])})

  @impl GenServer
  def init(opts) do
    # A crash of the linked boot task arrives as a message, so it can stop
    # this process with a reason of its own.
    Process.flag(:trap_exit, true)

    cfg =
      @defaults
      |> Keyword.merge(Application.get_env(:vagus, __MODULE__, []))
      |> Keyword.merge(opts)

    cfg = cfg |> Map.new() |> Map.update!(:units, &Map.new/1)
    # Before any app process exists and before the API tree (a later sibling
    # of this one) can admit a backup or restore whose staging it would wipe.
    if cfg.boot, do: Map.get(cfg.units, :sweep, &Units.sweep/0).()
    # Here, not in the task, so this tree is not reported started until every
    # app process exists.
    Map.get(cfg.units, :import, &Units.import/0).()
    ensure = Map.get(cfg.units, :ensure, &Units.ensure/1)
    Enum.each(Map.get(cfg.units, :slugs, &Vagus.App.slugs/0).(), ensure)

    state = %{phase: :up, task: nil, waiters: [], resume: false, deadline: :infinity, cfg: cfg}
    {:ok, Map.put(state, :ups, %{}), {:continue, :boot}}
  end

  # The rest of the units are resolved here rather than in init/1: they lead
  # into later siblings (DNS, Ingress, the event pusher), and argus counts a
  # function captured in init/1 as one init/1 calls.
  @impl GenServer
  def handle_continue(:boot, %{cfg: %{units: overrides}} = state) do
    units = Units.all()
    gates = Map.merge(units.gates, Map.get(overrides, :gates, %{}))
    state = put_in(state.cfg.units, %{Map.merge(units, overrides) | gates: gates})
    # Restarted mid-shutdown: booting now would restart what is being stopped.
    if state.cfg.units.in_flight?.(),
      do: {:noreply, %{state | phase: :stopping}},
      else: {:noreply, boot(state)}
  end

  @impl GenServer
  def handle_call({:shutdown, _budget}, from, %{phase: phase, task: %Task{}} = state)
      when phase in [:stopping, :cancelling],
      do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call({:shutdown, budget}, from, state),
    do: {:noreply, preempt(%{state | waiters: [from], deadline: deadline(budget)})}

  @impl GenServer
  def handle_cast(:resume, %{phase: :stopping, task: nil} = state), do: {:noreply, boot(state)}

  def handle_cast(:resume, %{phase: phase} = state) when phase in [:stopping, :cancelling],
    do: {:noreply, %{state | resume: true}}

  def handle_cast({:up, slug, _at}, %{phase: :up, cfg: %{boot: true, units: units}} = state) do
    Task.Supervisor.start_child(Vagus.TaskSupervisor, fn ->
      boot_start(slug, units.inspect.(slug), units)
    end)

    {:noreply, state}
  end

  # Its stage may already be behind it, and nothing later in the boot revisits
  # it, so it is remembered for a replay at boot's end (`finish/2`).
  def handle_cast({:up, slug, at}, %{phase: :booting} = state),
    do: {:noreply, %{state | ups: Map.update(state.ups, slug, at, &max(&1, at))}}

  def handle_cast(_ignored, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(result, %{state | task: nil})
  end

  def handle_info({:DOWN, ref, _, _, reason}, %{phase: :booting, task: %Task{ref: ref}} = state),
    do: {:stop, {:boot_crashed, reason}, state}

  def handle_info({:DOWN, ref, _, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("App #{state.phase} sequence crashed: #{inspect(reason)}")
    finish(@degraded, %{state | task: nil})
  end

  def handle_info(_exit_or_late_reply, state), do: {:noreply, state}

  defp finish(_result, %{phase: :cancelling} = state), do: {:noreply, begin_stop(state)}

  defp finish(result, %{phase: :stopping} = state) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    state = %{state | waiters: []}
    if state.resume, do: {:noreply, boot(%{state | resume: false})}, else: {:noreply, state}
  end

  # Replayed only when made after its app's stage began, or when no stage
  # reached that app. One made earlier, including every process init/1
  # started, got that stage's `boot_start`: a replay would start a `once` app
  # that already exited a second time, or retry a failed start outside its
  # restart ladder.
  defp finish(staged, state) do
    for {slug, at} <- state.ups, at > Map.get(staged, slug, at - 1), do: up(slug, self())

    {:noreply, %{state | phase: :up, ups: %{}}}
  end

  defp preempt(%{phase: :booting} = state) do
    send(state.task.pid, :cancel)
    %{state | phase: :cancelling}
  end

  defp preempt(state), do: begin_stop(state)

  defp deadline(:infinity), do: :infinity
  defp deadline(budget_ms), do: System.monotonic_time(:millisecond) + budget_ms

  defp boot(%{cfg: %{boot: false}} = state), do: %{state | phase: :up}

  defp boot(state),
    do: %{state | phase: :booting, task: Task.async(fn -> run_boot(state.cfg) end)}

  # Runs outside this process, so a crash here does not cut the stop short.
  # A stop halts every app and a resume boots them all, so no replay is owed.
  defp begin_stop(%{cfg: cfg, deadline: deadline} = state) do
    task = Task.Supervisor.async_nolink(Vagus.TaskSupervisor, fn -> run_stop(cfg, deadline) end)
    %{state | phase: :stopping, task: task, ups: %{}}
  end

  defp run_boot(cfg) do
    if slug = cfg.default_native_app, do: install_default(slug, cfg.units)

    {_running, staged} =
      Enum.reduce(@plan, {:unknown, %{}}, fn step, acc ->
        checkpoint(0)
        step(step, acc, cfg)
      end)

    cfg.units.push_complete.()
    staged
  catch
    :cancelled -> :cancelled
  end

  # A step boundary: where a shutdown's `:cancel` ends the boot.
  defp checkpoint(wait_ms) do
    receive do
      :cancel -> throw(:cancelled)
    after
      wait_ms -> :ok
    end
  end

  defp install_default(slug, units) do
    case units.install_default.(slug) do
      result when result in [:installed, :present] -> :ok
      error -> Logger.warning("Boot: default app #{slug} not installed: #{inspect(error)}")
    end
  end

  # `running` is the engine's one listing of app containers, taken once the
  # engine gate is behind and carried through the stages. `staged` maps each
  # app a stage gave `boot_start` to when that stage began.
  defp step({:gate, name}, {running, staged}, cfg) do
    gate(name, Map.fetch!(cfg.units.gates, name), cfg, 1)
    {if(name == :engine, do: listing(cfg), else: running), staged}
  end

  defp step({:stage, :core}, acc, cfg) do
    task = spawn_unit(fn -> ready("Core", cfg.units.core_start.(cfg.stage_timeout)) end)
    await(:core, [{"core", task}], cfg)
    acc
  end

  defp step({:stage, stage}, {running, staged}, %{units: units} = cfg) do
    {once, awaited} =
      units.list.()
      |> Enum.filter(&in_stage?(&1, stage, units))
      |> Enum.split_with(&(&1.config.startup == "once"))

    at = System.unique_integer([:monotonic])
    start = fn slug -> spawn_unit(fn -> boot_start(slug, running?(running, slug), units) end) end
    Enum.each(once, &start.(&1.config.slug))
    tasks = for %{config: %{slug: slug}} <- awaited, do: {slug, start.(slug)}
    await(stage, tasks, cfg)
    {running, Enum.reduce(once ++ awaited, staged, &Map.put(&2, &1.config.slug, at))}
  end

  defp listing(cfg) do
    case run_bounded(cfg.units.running, cfg.gate_timeout) do
      {:ok, %MapSet{} = running} ->
        running

      failure ->
        Logger.warning("Boot: app containers not listed (#{inspect(failure)}); none demoted")
        :unknown
    end
  end

  defp running?(:unknown, _slug), do: :unknown
  defp running?(running, slug), do: MapSet.member?(running, slug)

  defp in_stage?(entry, :native, units), do: units.native?.(entry)
  defp in_stage?(entry, stage, _units), do: Map.get(@stage_of, entry.config.startup) == stage

  defp gate(name, check, cfg, tries) do
    case run_bounded(check, cfg.gate_timeout) do
      :ok ->
        Logger.info("Boot: gate #{name} passed")

      failure when tries >= cfg.gate_tries ->
        Logger.warning(
          "Boot: gate #{name} failing after #{tries} tries (#{inspect(failure)}); carrying on"
        )

      failure ->
        if tries == 1, do: Logger.info("Boot: waiting on gate #{name} (#{inspect(failure)})")
        checkpoint(if name == :tree, do: cfg.tree_interval, else: cfg.gate_interval)
        gate(name, check, cfg, tries + 1)
    end
  end

  # A gate check only reads, so one past its timeout is killed.
  defp run_bounded(fun, timeout) do
    task = spawn_unit(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Unlinked, so nothing that ends the sequence kills a unit midway. A raise
  # is this unit's result, not a crash of the sequence.
  defp spawn_unit(fun) do
    Task.Supervisor.async_nolink(Vagus.TaskSupervisor, fn ->
      try do
        fun.()
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end)
  end

  defp await(stage, tasks, cfg) do
    results = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), cfg.stage_timeout)

    outcomes =
      Enum.zip_with(tasks, results, fn {slug, _}, {_, result} -> {slug, outcome(result)} end)

    cfg.units.report.(stage, outcomes)
  end

  defp outcome({:ok, outcome}) when outcome in [:ready, :failed], do: outcome
  defp outcome(nil), do: :pending
  defp outcome(_crashed), do: :failed

  defp boot_start(slug, running?, units), do: ready(slug, units.boot_start.(slug, running?))

  defp ready(_name, :ok), do: :ready

  defp ready(name, failure) do
    Logger.warning("Boot: #{name} did not start: #{inspect(failure)}")
    :failed
  end

  defp run_stop(%{units: units} = cfg, deadline) do
    {apps, earlier} =
      units
      |> stoppable()
      |> Enum.split_with(&(Map.get(@stage_of, &1.config.startup) == :application))

    {apps_ok, apps_total} = stop_all(apps, cfg)
    core = stop_core(units, core_budget(deadline, cfg))
    {earlier_ok, earlier_total} = stop_all(earlier, cfg)
    {{apps_ok + earlier_ok, apps_total + earlier_total}, core}
  end

  # A listing that fails must still let Core stop.
  defp stoppable(units) do
    Enum.reject(units.list.(), units.native?)
  rescue
    exception -> unlisted(exception)
  catch
    kind, reason -> unlisted({kind, reason})
  end

  defp unlisted(reason) do
    Logger.warning("Shutdown: could not list apps, stopping Core only: #{inspect(reason)}")
    []
  end

  # What is left of the budget once the earlier group's bound is set aside.
  defp core_budget(:infinity, _cfg), do: :infinity

  defp core_budget(deadline, cfg) do
    left = deadline - System.monotonic_time(:millisecond)
    max(left - cfg.app_stop_timeout - cfg.stop_margin, 0)
  end

  # Past its deadline Core is left stopping: the earlier group must still
  # get its stop before the caller's budget runs out.
  defp stop_core(units, budget_ms) do
    task = spawn_unit(fn -> units.core_stop.(budget_ms) end)

    case Task.yield(task, budget_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:exit, reason}}

      nil ->
        Logger.warning("Shutdown: Core still stopping at its deadline; stopping the earlier apps")
        {:error, :timeout}
    end
  end

  defp stop_all(entries, cfg) do
    tasks =
      for %{config: %{slug: slug}} <- entries,
          do: {slug, spawn_unit(fn -> cfg.units.halt.(slug) end)}

    opts = [timeout: cfg.app_stop_timeout, on_timeout: :kill_task]
    results = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), opts)

    Enum.zip_with(tasks, results, fn {slug, _}, {_, result} ->
      result == {:ok, :ok} || Logger.warning("Shutdown: #{slug} halt failed: #{inspect(result)}")
    end)
    |> Enum.count(&(&1 == true))
    |> then(&{&1, length(tasks)})
  end
end
