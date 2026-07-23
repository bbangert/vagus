defmodule Vagus.Core.Watchdog.Probe do
  @moduledoc """
  The API-probe half of the Core watchdog — real Supervisor's periodic
  `_watchdog_homeassistant_api()` scheduler task (`misc/tasks.py:164-237`,
  `RUN_WATCHDOG_HOMEASSISTANT_API = 120`). The container-event half is the
  sibling `Vagus.Core.Watchdog`; like the add-on pair
  (`Vagus.Addon.Watchdog` / `.Probe`), the two are independent code paths
  with independent counters — neither ever reads the other's state.

  This is the primary value of the Core watchdog: a Core that is
  running-but-hung (container alive, API dead) produces no docker event at
  all — only a periodic probe notices it.

  ## The ladder (upstream `misc/tasks.py:29-32,201-237`)

  Every `:interval` ms (default 120s), when the persisted watchdog option
  is on and the container is running, probe Core's API once
  (`Vagus.Core.Health.check/1` — the one-shot probe, NOT `await_healthy/1`):

    * 1st consecutive miss — warn only (`HASS_WATCHDOG_MAX_API_ATTEMPTS = 2`
      tolerates one).
    * 2nd consecutive miss — `Vagus.Core.Lifecycle.restart/1`, counting one
      reanimation.
    * After 5 reanimations without a stable healthy stretch in between —
      ONE `Vagus.Core.Lifecycle.rebuild/1` (upstream's last-ditch
      `rebuild(safe_mode=True)`; Vagus has no safe-mode marker convention
      yet, a documented v1 omission).
    * After that rebuild — `:given_up`: one `error` log, then no further
      actions until the watchdog option is toggled (see below) or this
      process restarts.

  A healthy tick resets the miss counter immediately; the reanimation
  counter resets only after `#{5}` consecutive healthy ticks (~10 min at
  the default interval) — the emulator analogue of upstream resetting on a
  Core that made it back to RUNNING, so a Core that keeps hanging shortly
  after each reanimation still escalates to rebuild rather than resetting
  its ladder on every brief recovery.

  ## `{:error, :busy}` = skip, never a counted attempt

  `Vagus.Core.Lifecycle`'s single non-blocking mutex returns
  `{:error, :busy}` when any Core op is already in flight (a user-initiated
  restart/update, or the event-half watchdog acting) — that result is
  logged at `debug` and consumes nothing: no reanimation counted, no
  given-up latch, the next tick re-evaluates fresh. The watchdog never
  queues behind or fights a running op.

  ## Actions run in a bounded Task

  `Lifecycle.restart/1`/`rebuild/1` block until Core is healthy again (an
  internal `await_healthy/1` gate of up to 10 min) — far longer than a
  tick. Actions therefore run in a monitored `Task` (one at a time; ticks
  while an action is in flight skip probing entirely), each call bounded by
  `:attempt_timeout_ms` and backstopped by an `:action_deadline_ms`
  GenServer-side failsafe — the same bounded-call + deadline-failsafe
  skeleton as `Vagus.Addon.Watchdog`. Ladder counting happens when the
  task's result arrives, not at dispatch, so a `:busy` skip is observable
  as exactly nothing.

  ## Toggle revive

  Subscribes to `Vagus.Core.TokenStore` (tolerating an absent server, like
  `Vagus.Addon.Watchdog`'s events subscription) and resets the whole
  ladder — misses, reanimations, the given-up latch — on
  `{:token_store, :watchdog_changed}`. Toggling the watchdog off and back
  on via `POST core/options` is the documented way to revive a given-up
  watchdog without restarting Vagus.

  ## Skips that are not strikes

  A tick with the watchdog option off, the container not running (a stopped
  Core is a user decision — upstream skips too), or an action already in
  flight changes no counter — logged at `debug` only.

  ## Options (all injectable — tests never touch a real engine/HTTP probe)

    * `:name` — GenServer name, default `#{inspect(__MODULE__)}`.
    * `:interval` — tick period in ms, default `120_000`.
    * `:token_store` — the `Vagus.Core.TokenStore` server, default
      `Vagus.Core.TokenStore`.
    * `:check` — zero-arity `-> :healthy | :unhealthy`, default
      `fn -> Vagus.Core.Health.check() end`.
    * `:restart` — zero-arity `-> :ok | {:error, term()}`, default
      `fn -> Vagus.Core.Lifecycle.restart() end`.
    * `:rebuild` — zero-arity `-> :ok | {:error, term()}`, default
      `fn -> Vagus.Core.Lifecycle.rebuild() end`.
    * `:running_check` — zero-arity `-> boolean`, default inspects
      `Vagus.Core.Container.name/0` via
      `Vagus.Runtime.Docker.inspect_container/1` (a paused container still
      reports `Running: true` — exactly the hung-Core case this probe
      exists for); any error counts as not running.
    * `:attempt_timeout_ms` — bounds a single restart/rebuild call,
      default `900_000` (15 min — above `Lifecycle`'s own internal 10-min
      health gate, so a slow-but-legitimate op finishes inside it).
    * `:action_deadline_ms` — GenServer-side failsafe that force-clears a
      wedged action task, default `1_800_000` (30 min) — mirrors
      `Vagus.Addon.Watchdog`'s identical failsafe.

  Gated (with the sibling event half, under
  `Vagus.Core.Watchdog.Supervisor`) by `config :vagus, :core_watchdog`
  (`true` only in `config/target.exs`).
  """

  use GenServer

  require Logger

  alias Vagus.Core.{Container, Health, Lifecycle, TokenStore}
  alias Vagus.Runtime.Docker

  @default_interval 120_000
  # HASS_WATCHDOG_MAX_API_ATTEMPTS: tolerate 1 miss, act on the 2nd.
  @max_api_misses 2
  # HASS_WATCHDOG_REANIMATE_FAILURES: rebuild once after 5 reanimations.
  @max_reanimations 5
  # Consecutive healthy ticks before the reanimation counter resets — the
  # analogue of upstream's reset-on-RUNNING (see moduledoc).
  @stable_streak_ticks 5
  @default_attempt_timeout_ms 900_000
  @default_action_deadline_ms 30 * 60 * 1_000

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    token_store = Keyword.get(opts, :token_store, TokenStore)
    maybe_subscribe(token_store)
    interval = Keyword.get(opts, :interval, @default_interval)

    st = %{
      interval: interval,
      token_store: token_store,
      check: Keyword.get(opts, :check, fn -> Health.check() end),
      restart: Keyword.get(opts, :restart, fn -> Lifecycle.restart() end),
      rebuild: Keyword.get(opts, :rebuild, fn -> Lifecycle.rebuild() end),
      running_check: Keyword.get(opts, :running_check, &default_running_check/0),
      attempt_timeout_ms: Keyword.get(opts, :attempt_timeout_ms, @default_attempt_timeout_ms),
      action_deadline_ms: Keyword.get(opts, :action_deadline_ms, @default_action_deadline_ms),
      misses: 0,
      reanimations: 0,
      healthy_streak: 0,
      given_up: false,
      # nil | %{task: %Task{}, kind: :restart | :rebuild} — at most one
      # action in flight; ticks skip probing while it runs.
      action: nil
    }

    # First probe only after one full interval — right after Vagus boots,
    # Core is very likely still starting; probing it immediately would
    # record spurious misses (same convention as Vagus.Addon.Watchdog.Probe).
    Process.send_after(self(), :tick, interval)
    {:ok, st}
  end

  @impl GenServer
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, st.interval)
    {:noreply, run_tick(st)}
  end

  # The persisted watchdog option flipped (POST core/options) — reset the
  # whole ladder. This is the documented revive path for a given-up
  # watchdog (see moduledoc "Toggle revive").
  def handle_info({:token_store, :watchdog_changed}, st) do
    if st.given_up do
      Logger.info("Vagus.Core.Watchdog.Probe: watchdog option toggled; given-up latch cleared")
    end

    {:noreply, %{st | misses: 0, reanimations: 0, healthy_streak: 0, given_up: false}}
  end

  # A completed action Task's reply — the ladder is advanced here, not at
  # dispatch, so a :busy result consumes nothing (see moduledoc).
  def handle_info({ref, result}, %{action: %{task: %Task{ref: ref}} = action} = st) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_action_result(action.kind, result, %{st | action: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{action: action} = st) do
    case action do
      %{task: %Task{ref: ^ref}} ->
        if reason != :normal do
          Logger.warning(
            "Vagus.Core.Watchdog.Probe: #{action.kind} task went down unexpectedly " <>
              "(#{inspect(reason)})"
          )
        end

        {:noreply, %{st | action: nil}}

      _other ->
        {:noreply, st}
    end
  end

  # Failsafe — force-clears a wedged action task so the probe can never be
  # stuck skipping ticks forever (mirrors Vagus.Addon.Watchdog's identical
  # clause). Ignored if that exact ref already finished normally.
  def handle_info({:action_deadline, ref}, %{action: action} = st) do
    case action do
      %{task: %Task{ref: ^ref} = task, kind: kind} ->
        Logger.error(
          "Vagus.Core.Watchdog.Probe: #{kind} task exceeded its " <>
            "#{st.action_deadline_ms}ms deadline; force-killing (watchdog wedge recovered)"
        )

        Task.shutdown(task, :brutal_kill)
        {:noreply, %{st | action: nil}}

      _other ->
        {:noreply, st}
    end
  end

  def handle_info(_other, st), do: {:noreply, st}

  ## Tick

  defp run_tick(st) do
    cond do
      st.given_up ->
        Logger.debug("Vagus.Core.Watchdog.Probe: given up; skipping tick (toggle to revive)")
        st

      st.action != nil ->
        Logger.debug("Vagus.Core.Watchdog.Probe: #{st.action.kind} in flight; skipping tick")
        st

      not TokenStore.get_watchdog(st.token_store) ->
        Logger.debug("Vagus.Core.Watchdog.Probe: watchdog option off; skipping tick")
        st

      not st.running_check.() ->
        # A stopped Core is a user decision (upstream skips too) — and the
        # event half owns crashed-container recovery.
        Logger.debug("Vagus.Core.Watchdog.Probe: Core container not running; skipping tick")
        st

      true ->
        apply_probe(st.check.(), st)
    end
  end

  defp apply_probe(:healthy, st) do
    streak = st.healthy_streak + 1

    if st.reanimations > 0 and streak >= @stable_streak_ticks do
      Logger.info(
        "Vagus.Core.Watchdog.Probe: Core stable for #{streak} ticks; reanimation counter reset"
      )

      %{st | misses: 0, healthy_streak: streak, reanimations: 0}
    else
      %{st | misses: 0, healthy_streak: streak}
    end
  end

  defp apply_probe(:unhealthy, st) do
    misses = st.misses + 1
    st = %{st | misses: misses, healthy_streak: 0}

    cond do
      misses < @max_api_misses ->
        Logger.warning(
          "Vagus.Core.Watchdog.Probe: Core API probe missed (#{misses}/#{@max_api_misses})"
        )

        st

      st.reanimations >= @max_reanimations ->
        Logger.error(
          "Vagus.Core.Watchdog.Probe: Core failed #{st.reanimations} reanimations; " <>
            "attempting one last-ditch rebuild"
        )

        start_action(:rebuild, st.rebuild, st)

      true ->
        Logger.warning(
          "Vagus.Core.Watchdog.Probe: Core API dead for #{misses} consecutive probes; " <>
            "restarting (reanimation #{st.reanimations + 1}/#{@max_reanimations})"
        )

        start_action(:restart, st.restart, st)
    end
  end

  ## Actions

  defp start_action(kind, fun, st) do
    attempt_timeout_ms = st.attempt_timeout_ms
    task = Task.async(fn -> run_action(kind, fun, attempt_timeout_ms) end)
    Process.send_after(self(), {:action_deadline, task.ref}, st.action_deadline_ms)
    %{st | action: %{task: task, kind: kind}}
  end

  defp handle_action_result(:restart, {:error, :busy}, st) do
    Logger.debug(
      "Vagus.Core.Watchdog.Probe: restart skipped, a Core lifecycle op is already in flight"
    )

    st
  end

  defp handle_action_result(:restart, result, st) do
    case result do
      :ok ->
        Logger.info("Vagus.Core.Watchdog.Probe: Core restarted and healthy again")

      {:error, reason} ->
        Logger.warning("Vagus.Core.Watchdog.Probe: Core restart failed (#{inspect(reason)})")
    end

    # One reanimation consumed either way (upstream counts attempts, not
    # outcomes); a fresh miss window gives the restarted Core its fair shot.
    %{st | reanimations: st.reanimations + 1, misses: 0}
  end

  defp handle_action_result(:rebuild, {:error, :busy}, st) do
    Logger.debug(
      "Vagus.Core.Watchdog.Probe: rebuild skipped, a Core lifecycle op is already in flight"
    )

    st
  end

  defp handle_action_result(:rebuild, result, st) do
    Logger.error(
      "Vagus.Core.Watchdog.Probe: last-ditch rebuild finished (#{inspect(result)}); " <>
        "giving up — no further watchdog actions until the watchdog option is " <>
        "toggled or Vagus restarts"
    )

    %{st | given_up: true, misses: 0}
  end

  # Runs inside the Task — bounds the Lifecycle call and catches anything it
  # raises so a bug in one action can never take the probe down with it.
  @doc false
  def run_action(kind, fun, attempt_timeout_ms) do
    bounded_call(attempt_timeout_ms, fun)
  rescue
    e ->
      Logger.error(
        "Vagus.Core.Watchdog.Probe: #{kind} task crashed " <>
          "(#{Exception.format(:error, e, __STACKTRACE__)})"
      )

      {:error, :crashed}
  catch
    kind_, reason ->
      Logger.error("Vagus.Core.Watchdog.Probe: #{kind} task #{kind_}ed (#{inspect(reason)})")
      {:error, :crashed}
  end

  # Same bounded-call shape as Vagus.Addon.Watchdog.bounded_manager_call/2 —
  # see that function's doc for why brutal-killing the inner Task cannot
  # orphan a :global.trans lock it was still waiting on.
  defp bounded_call(timeout_ms, fun) do
    inner = Task.async(fun)

    case Task.yield(inner, timeout_ms) || Task.shutdown(inner, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :attempt_timeout}
    end
  end

  ## Defaults

  # Same tolerate-absent-server shape as Vagus.Addon.Watchdog's events
  # subscription: the store may not be running in an isolated unit test, and
  # the subscribe call itself may race its startup.
  defp maybe_subscribe(token_store) do
    if server_alive?(token_store) do
      try do
        TokenStore.subscribe(token_store)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp server_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp server_alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp server_alive?(_other), do: false

  defp default_running_check do
    case Docker.inspect_container(Container.name()) do
      {:ok, %{"State" => %{"Running" => true}}} -> true
      _other -> false
    end
  end
end
