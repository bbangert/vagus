defmodule Vagus.App.Orchestrator do
  @moduledoc """
  Brings the apps and Core up at boot and down at shutdown, in upstream's
  stage order. It holds only the sequence in flight; the sequence runs in a
  task, so a shutdown can pre-empt a boot at any step. Every step is
  idempotent, so a restart of this process simply boots again.

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

       an app's boot rule is `Vagus.App.Policy.boot/2`; `once` apps are not
       awaited;
    5. `supervisor_update` with `startup: complete`, which Core takes as the
       Supervisor having finished starting.

  Shutdown stops the `application` stage, then Core, then every earlier
  stage, each group all at once. Native apps keep running and nothing is
  written to State, so the next boot starts the same apps.

  Unlike the boot it replaces, a user's stop of the default broker survives
  a reboot: it starts only on a fresh install or when State says `:started`.
  An app whose boot start fails stays `:started`, as one whose start fails
  its registration already does. `Vagus.Provisioner`'s first-boot Core start
  stays its own, outside these stages.
  """

  use GenServer

  require Logger

  alias Vagus.App.{Policy, Units}

  @stage_of %{
    "initialize" => :initialize,
    "system" => :system,
    "services" => :services,
    "application" => :application,
    "once" => :application
  }

  @plan [gate: :tree, stage: :native, gate: :engine, gate: :network, gate: :api] ++
          for(
            stage <- [:initialize, :system, :services, :core, :application],
            do: {:stage, stage}
          )

  @defaults [
    boot: false,
    default_native_app: nil,
    gate_tries: 60,
    gate_interval: 5_000,
    gate_timeout: 10_000,
    stage_timeout: 120_000,
    app_stop_timeout: 35_000,
    units: %{}
  ]

  @degraded {{0, 0}, {:error, :not_run}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Pre-empts a boot in flight. `{{apps_stopped, apps_running}, core_result}`."
  @spec shutdown(GenServer.server()) :: {{non_neg_integer(), non_neg_integer()}, term()}
  def shutdown(server \\ __MODULE__), do: GenServer.call(server, :shutdown, 300_000)

  @doc "Boots again after a shutdown that did not take the device down."
  @spec resume(GenServer.server()) :: :ok
  def resume(server \\ __MODULE__), do: GenServer.cast(server, :resume)

  @doc "Applies the boot rule to one app once boot is over; ignored before."
  @spec up(String.t(), GenServer.server()) :: :ok
  def up(slug, server \\ __MODULE__), do: GenServer.cast(server, {:up, slug})

  @impl GenServer
  def init(opts) do
    # The sequence task is linked so it dies with this process, and a crash
    # of it must not take this process down.
    Process.flag(:trap_exit, true)

    cfg =
      @defaults
      |> Keyword.merge(Application.get_env(:vagus, __MODULE__, []))
      |> Keyword.merge(opts)

    cfg = cfg |> Map.new() |> Map.update!(:units, &Map.new/1)
    # Here, not in the task, so this tree is not reported started until every
    # app process exists. A `State.list/0` exit crashes it: State is a durable
    # sibling started before this tree, so its absence must be loud.
    list = Map.get(cfg.units, :list, &Vagus.Addon.State.list/0)
    Enum.each(list.(), &Units.ensure(&1.config.slug))
    {:ok, %{phase: :up, task: nil, waiters: [], cfg: cfg}, {:continue, :boot}}
  end

  # The rest of the units are resolved here rather than in init/1: they lead
  # into later siblings (DNS, Ingress, the event pusher), and argus counts a
  # function captured in init/1 as one init/1 calls.
  @impl GenServer
  def handle_continue(:boot, state) do
    state = update_in(state.cfg.units, &Map.merge(Units.all(), &1))
    # Restarted mid-shutdown: booting now would restart what is being stopped.
    if Vagus.Host.Shutdown.in_flight?(),
      do: {:noreply, %{state | phase: :stopping}},
      else: {:noreply, boot(state)}
  end

  @impl GenServer
  def handle_call(:shutdown, from, %{phase: :stopping, task: %Task{}} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:shutdown, from, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    task = Task.async(fn -> run_stop(state.cfg) end)
    {:noreply, %{state | phase: :stopping, task: task, waiters: [from]}}
  end

  @impl GenServer
  def handle_cast(:resume, %{phase: :stopping, task: nil} = state), do: {:noreply, boot(state)}

  def handle_cast({:up, slug}, %{phase: :up, cfg: %{units: units}} = state) do
    with %{} = entry <- Enum.find(units.list.(), &(&1.config.slug == slug)) do
      Task.Supervisor.start_child(Vagus.TaskSupervisor, fn -> boot_start(entry, units) end)
    end

    {:noreply, state}
  end

  def handle_cast(_ignored, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(result, %{state | task: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("App #{state.phase} sequence crashed: #{inspect(reason)}")
    finish(@degraded, %{state | task: nil})
  end

  def handle_info(_exit_or_late_reply, state), do: {:noreply, state}

  defp finish(result, %{phase: :stopping} = state) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | waiters: []}}
  end

  defp finish(_result, state), do: {:noreply, %{state | phase: :up}}

  defp boot(%{cfg: %{boot: false}} = state), do: %{state | phase: :up}

  defp boot(state),
    do: %{state | phase: :booting, task: Task.async(fn -> run_boot(state.cfg) end)}

  defp run_boot(cfg) do
    import_once()
    if slug = cfg.default_native_app, do: install_default(slug, cfg.units)
    Enum.each(@plan, &step(&1, cfg))
    cfg.units.push_complete.()
  end

  # Where apps recorded by an older Vagus are brought into this one.
  defp import_once, do: :ok

  defp install_default(slug, units) do
    case units.install_default.(slug) do
      :installed -> units.want_started.(slug)
      :present -> :ok
      error -> Logger.warning("Boot: default app #{slug} not installed: #{inspect(error)}")
    end
  end

  defp step({:gate, name}, cfg), do: gate(name, Map.fetch!(cfg.units.gates, name), cfg, 1)

  defp step({:stage, :core}, cfg) do
    task = spawn_unit(fn -> ready("Core", cfg.units.core_start.(cfg.stage_timeout)) end)
    await(:core, [{"core", task}], cfg)
  end

  defp step({:stage, stage}, %{units: units} = cfg) do
    {once, awaited} =
      units.list.()
      |> Enum.filter(&in_stage?(&1, stage, units))
      |> Enum.split_with(&(&1.config.startup == "once"))

    Enum.each(once, fn entry -> spawn_unit(fn -> boot_start(entry, units) end) end)

    tasks =
      for entry <- awaited,
          do: {entry.config.slug, spawn_unit(fn -> boot_start(entry, units) end)}

    await(stage, tasks, cfg)
  end

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
        Process.sleep(cfg.gate_interval)
        gate(name, check, cfg, tries + 1)
    end
  end

  defp run_bounded(fun, timeout) do
    task = spawn_unit(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # Linked to the sequence task, so killing it stops these too. A raise is
  # this unit's result, not a crash of the sequence.
  defp spawn_unit(fun) do
    Task.async(fn ->
      try do
        fun.()
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end)
  end

  # A straggler is left to finish: killing a start midway leaves a container
  # half made.
  defp await(stage, tasks, cfg) do
    results = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), cfg.stage_timeout)

    outcomes =
      Enum.zip_with(tasks, results, fn {slug, _}, {_, result} -> {slug, outcome(result)} end)

    cfg.units.report.(stage, outcomes)
  end

  defp outcome({:ok, outcome}) when outcome in [:ready, :failed], do: outcome
  defp outcome(nil), do: :pending
  defp outcome(_crashed), do: :failed

  defp boot_start(entry, units) do
    case Policy.boot(entry, entry.state == :started and units.running?.(entry)) do
      :start -> ready(entry.config.slug, units.start.(entry.config.slug))
      :demote -> ready(entry.config.slug, units.demote.(entry))
      :none -> :ready
    end
  end

  defp ready(_name, :ok), do: :ready

  defp ready(name, failure) do
    Logger.warning("Boot: #{name} did not start: #{inspect(failure)}")
    :failed
  end

  defp run_stop(%{units: units} = cfg) do
    {apps, earlier} =
      units.list.()
      |> Enum.filter(&(&1.state == :started and not units.native?.(&1)))
      |> Enum.split_with(&(Map.get(@stage_of, &1.config.startup) == :application))

    {apps_ok, apps_total} = stop_all(apps, cfg)
    core = units.core_stop.()
    {earlier_ok, earlier_total} = stop_all(earlier, cfg)
    {{apps_ok + earlier_ok, apps_total + earlier_total}, core}
  end

  defp stop_all(entries, cfg) do
    tasks =
      for %{config: %{slug: slug}} <- entries,
          do: {slug, spawn_unit(fn -> cfg.units.stop.(slug) end)}

    opts = [timeout: cfg.app_stop_timeout, on_timeout: :kill_task]
    results = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), opts)

    Enum.zip_with(tasks, results, fn {slug, _}, {_, result} ->
      result == {:ok, :ok} || Logger.warning("Shutdown: #{slug} stop failed: #{inspect(result)}")
    end)
    |> Enum.count(&(&1 == true))
    |> then(&{&1, length(tasks)})
  end
end
