defmodule Vagus.Addon.Watchdog do
  @moduledoc """
  The container-event half of the add-on watchdog
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B6) — real Supervisor's
  `watchdog_container` + `_restart_after_problem` (`apps/app.py:1844-1858`
  and the throttled `@Job` beneath it). The application-probe half (§B7,
  the periodic `watchdog:` URL poll) is a separate, not-yet-built module —
  §B6.5 is explicit the two are independent code paths with independent
  state; don't conflate them here.

  ## Event source

  Subscribes to `Vagus.Runtime.Events` (`:events` opt, default
  `Vagus.Runtime.Events`) in `init/1` and reacts to the
  `{:docker_event, %{action, name, exit_code, ...}}` messages it fans out
  (§B6.1). The events server may not be running yet (or ever, in isolated
  unit tests) — `init/1` only subscribes if `Process.whereis/1` finds it,
  and tolerates the subscribe call itself failing (a race between the
  `whereis` check and the actual call). Either way, this GenServer also
  accepts `{:docker_event, event}` sent to it directly (from a test, or a
  future alternate event source) — the message shape is the only contract
  that matters, not who sent it.

  ## Triggering events (§B6.3)

  Only container names of the form `"addon_" <> slug` are considered.
  Docker's `die` action (any exit code — both the real Supervisor's FAILED
  and STOPPED `ContainerState`s map to the same `die` action and the same
  restart call here, see below) and `"health_status: unhealthy"` are the
  two triggers; anything else is ignored.

  A triggering event is acted on only if `Vagus.Addon.State.get/2` (`:state`
  opt) says the slug is tracked, `state: :started`, **and** `watchdog:
  true` — the emulator's analogue of real Supervisor's two kill-switches
  (`self.watchdog` and `self._manual_stop`, §B6.3). There is no separate
  `_manual_stop` flag here: `Vagus.Addon.Manager.stop/2` (and, via it,
  `restart/2` and `uninstall/2`) now records `:stopped` in `State`
  **before** touching the container (W6 — see that module's moduledoc), so
  a `die`/`unhealthy` event caused by a manual stop/restart/uninstall
  always finds `state: :stopped` here and is ignored, exactly like real
  Supervisor's `_manual_stop` flag would suppress it. Host-reboot
  suppression falls out the same way, for free: `Vagus.Addon.BootStarter`
  demotes any `:started` entry that isn't a `boot: auto` add-on (and any
  `boot: auto` entry that fails to actually restart) to `:stopped` at boot,
  so a stale `:started` record left over from before a reboot is corrected
  before this watchdog ever sees a live event for it.

  A third suppression covers the window the other two can't: a host
  shutdown *actually in progress* (`Vagus.Host.Shutdown`, issue #39's
  graceful-shutdown facade). That module's own add-on stop stage runs
  ordinary `docker stop` calls against every started add-on, but
  deliberately does **not** record `:stopped` in `State` — its whole point
  is that `Vagus.Addon.BootStarter` sees `:started` and restarts these
  add-ons on the next boot, so the W6 mechanism above cannot apply here
  (there is no `:stopped` for `eligible?/2` to find). Left unhandled, every
  one of those stops would look to this watchdog exactly like an
  unexpected crash and trigger a restart sequence *during* the shutdown
  window — racing the reboot/poweroff that follows and getting the
  freshly-restarted container SIGKILLed by erlinit, the exact corruption
  `Vagus.Host.Shutdown` exists to prevent. `maybe_start_sequence/3`
  therefore checks `:shutdown_check` (default
  `Vagus.Host.Shutdown.in_flight?/0`) ahead of `eligible?/2` and stands down
  for the rest of the shutdown once it flips true — see that module's
  moduledoc "Watchdog stand-down" section for why the flag lives in
  `:persistent_term` rather than here.

  A duplicate event for a slug whose restart sequence is already in flight
  is ignored outright — the sequence itself re-checks liveness (and
  `State`) before every attempt, so there's nothing a second event would
  usefully add.

  ## Restart sequence

  Runs in its own `Task`, tracked in this GenServer's state by slug (so
  concurrent sequences for different slugs never block each other, and
  never block this GenServer's own event loop) — up to 5 attempts
  (`manager.start_slug/2` for a `die` event, since starting removes any
  stale container first the same way a fresh install does;
  `manager.restart/2` for `unhealthy`, since the container is still
  running and needs an explicit stop+start), with exponential backoff
  **between** failed attempts: `backoff_base_ms * 2^(attempt-1)` — 10s,
  20s, 40s, 80s, 160s at the default 10s base (§B6.4). Before every
  attempt (including the first), the sequence re-checks both
  `:running_check` (maybe a user, or a concurrent path, already fixed it)
  and `State` (a manual stop mid-sequence must abort it, same rule as
  above) — either one failing ends the sequence quietly, no further log.
  Five failed attempts give up: logged, and the entry is demoted to
  `:stopped` (`Vagus.Addon.State.put/3`) — an honest record for an add-on
  the watchdog could not bring back up, mirroring `BootStarter`'s same
  demote-on-failure move.

  A task that raises/exits is caught inside the task itself (never
  propagated through the `Task.async/1` link back to this GenServer — a
  bug restarting one add-on must not take down the watchdog for every
  other add-on) and treated the same as a failed final attempt: logged and
  demoted.

  ## Global throttle — deliberately stricter than upstream

  Real Supervisor's `_restart_after_problem` is throttled **per app** (10
  starts / 30 min each, §B6.4). This plan deliberately makes the limit
  **global across every add-on** instead: a device flooded with
  simultaneously-crash-looping add-ons (e.g. a bad image pushed for
  several add-ons at once, or a resource-starvation cascade) is a bigger
  operational risk on a 1GB Pi than on a datacenter HAOS install, and a
  single shared budget bounds the total restart-attempt traffic this
  process will ever generate regardless of how many add-ons are
  misbehaving at once. Tracked as a sliding window of sequence-start
  timestamps (via the injected `:clock`, default
  `System.monotonic_time(:millisecond)`) — at most 10 sequence **starts**
  per 30 minutes; the 11th (and any further) triggering event inside the
  window is logged at `warning` and otherwise ignored (not queued, not
  retried later for that specific event — the next real event will
  re-evaluate against the then-current window).

  ## No persisted state

  Every counter here (in-flight tasks, throttle timestamps) is
  process-memory only, exactly like real Supervisor's per-app Job
  throttle bucket — a Vagus restart clears the slate, which is fine: the
  watchdog's job is to react to *future* events, not replay history.

  ## Options (all injectable — tests never touch the real engine/state)

    * `:name` — GenServer name, default `#{inspect(__MODULE__)}`.
    * `:events` — the `Vagus.Runtime.Events` server to subscribe to,
      default `Vagus.Runtime.Events`.
    * `:state` — the `Vagus.Addon.State` server, default
      `Vagus.Addon.State`.
    * `:manager` — a module implementing `start_slug/2` + `restart/2`,
      default `Vagus.Addon.Manager`.
    * `:running_check` — arity-1 `slug -> boolean`, default inspects the
      live container via `Vagus.Runtime.Docker.inspect_container/1`
      (`"addon_" <> slug`); any error (including a 404-shaped "not found"
      response) counts as not-running.
    * `:backoff_base_ms` — default `10_000`.
    * `:clock` — zero-arity monotonic-ms fun, default
      `System.monotonic_time(:millisecond)`.
    * `:attempt_timeout_ms` — bounds each individual `manager.start_slug/2`/
      `manager.restart/2` call inside the sequence (review W1), default
      `120_000` — generous next to `docker stop`'s own ~10s budget, since a
      slow-but-legitimate stop/start still needs to finish inside it.
    * `:sequence_deadline_ms` — GenServer-side failsafe: force-clears a
      wedged sequence's `state.tasks` entry after this many ms regardless of
      what's hanging inside it (review W1), default `1_800_000` (30 min) —
      comfortably above the worst-case legitimate sequence (5 bounded
      attempts + the 10/20/40/80s backoff gaps between them).
    * `:shutdown_check` — zero-arity `-> boolean`, default
      `Vagus.Host.Shutdown.in_flight?/0`. Checked ahead of `eligible?/2` in
      `maybe_start_sequence/3`; `true` stands the watchdog down for the
      triggering event (see the moduledoc "Triggering events" section's
      third suppression, above).

  Gated in `Vagus.Application` by `config :vagus, :watchdog_enabled`
  (default `true`, `false` in `config/test.exs`) — same pattern as
  `Vagus.Runtime.Events`'s `:events_enabled` (`events_children/0`).
  """

  use GenServer

  require Logger

  alias Vagus.Addon.State
  alias Vagus.Runtime.Docker

  @default_backoff_base_ms 10_000
  @max_attempts 5
  @throttle_max_starts 10
  @throttle_window_ms 30 * 60 * 1_000
  # review W1: per-attempt manager-call bound, and the GenServer-side
  # sequence-deadline failsafe — see moduledoc Options for the rationale
  # behind each default.
  @default_attempt_timeout_ms 120_000
  @default_sequence_deadline_ms 30 * 60 * 1_000

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    events = Keyword.get(opts, :events, Vagus.Runtime.Events)
    maybe_subscribe(events)

    state = %{
      events: events,
      state_server: Keyword.get(opts, :state, State),
      manager: Keyword.get(opts, :manager, Vagus.Addon.Manager),
      running_check: Keyword.get(opts, :running_check, &default_running_check/1),
      backoff_base_ms: Keyword.get(opts, :backoff_base_ms, @default_backoff_base_ms),
      clock: Keyword.get(opts, :clock, &default_clock/0),
      # 1-arity `(ms -> any)` that pauses between failed attempts. Default
      # `Process.sleep/1`; tests inject a recorder so backoff *growth* is asserted
      # against the computed schedule, not perturbable wall-clock.
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      attempt_timeout_ms: Keyword.get(opts, :attempt_timeout_ms, @default_attempt_timeout_ms),
      sequence_deadline_ms:
        Keyword.get(opts, :sequence_deadline_ms, @default_sequence_deadline_ms),
      shutdown_check: Keyword.get(opts, :shutdown_check, &Vagus.Host.Shutdown.in_flight?/0),
      # slug -> %Task{}, one in-flight restart sequence per slug (the whole
      # struct, not just its ref, so the review-W1 sequence-deadline failsafe
      # below can `Task.shutdown/2` it directly).
      tasks: %{},
      # sliding window of sequence-start timestamps (ms, per :clock), global
      # across every slug.
      starts: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:docker_event, %{action: action} = event}, state) do
    case slug_from_event(event) do
      nil -> {:noreply, state}
      slug -> handle_event(slug, action, Map.get(event, :exit_code), state)
    end
  end

  # A completed Task.async/1 reply: `ref` matches the value stored in
  # `state.tasks` for whichever slug it belongs to. The sequence itself
  # already did all its logging/demoting before returning; this just
  # clears the in-flight marker so a future event for the same slug can
  # start a new sequence.
  def handle_info({ref, _result}, %{tasks: tasks} = state) when is_reference(ref) do
    case slug_for_ref(tasks, ref) do
      nil ->
        {:noreply, state}

      slug ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | tasks: Map.delete(tasks, slug)}}
    end
  end

  # The monitor half of Task.async/1's reply — arrives right after the
  # `{ref, result}` clause above for a normal return (already cleared,
  # so this is a no-op lookup miss), or on its own if the task died some
  # other way despite the internal rescue/catch (e.g. killed).
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state) do
    case slug_for_ref(tasks, ref) do
      nil ->
        {:noreply, state}

      slug ->
        if reason != :normal do
          Logger.warning(
            "Vagus.Addon.Watchdog: restart task for #{slug} went down unexpectedly " <>
              "(#{inspect(reason)})"
          )
        end

        {:noreply, %{state | tasks: Map.delete(tasks, slug)}}
    end
  end

  # review W1 failsafe: force-clears a wedged sequence Task's `state.tasks`
  # entry so `maybe_start_sequence/3`'s dedup check can never stay stuck for
  # a slug forever — belt-and-suspenders on top of `bounded_manager_call/2`'s
  # per-attempt timeout, covering anything else in the sequence that could
  # theoretically hang (e.g. `State.get/2` itself blocking). Ignored if this
  # exact ref is no longer the one tracked for `slug` (the sequence already
  # finished normally before the deadline fired).
  def handle_info({:sequence_deadline, slug, ref}, %{tasks: tasks} = state) do
    case Map.get(tasks, slug) do
      %Task{ref: ^ref} = task ->
        Logger.error(
          "Vagus.Addon.Watchdog: restart sequence for #{slug} exceeded its " <>
            "#{state.sequence_deadline_ms}ms deadline; force-killing (watchdog wedge recovered)"
        )

        Task.shutdown(task, :brutal_kill)
        {:noreply, %{state | tasks: Map.delete(tasks, slug)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Event handling

  defp slug_from_event(%{name: "addon_" <> slug}), do: slug
  defp slug_from_event(_event), do: nil

  defp handle_event(slug, action, exit_code, state) do
    case classify_action(action, exit_code) do
      nil -> {:noreply, state}
      action_type -> maybe_start_sequence(slug, action_type, state)
    end
  end

  # Both real Supervisor's FAILED (exitCode != 0) and STOPPED (exitCode ==
  # 0) `ContainerState`s come from the same docker `die` action and take
  # the same restart call here (`start_slug/2` — see moduledoc); the exit
  # code isn't otherwise consulted.
  defp classify_action("die", _exit_code), do: :die
  defp classify_action("health_status: unhealthy", _exit_code), do: :unhealthy
  defp classify_action(_action, _exit_code), do: nil

  defp maybe_start_sequence(slug, action_type, state) do
    cond do
      Map.has_key?(state.tasks, slug) ->
        {:noreply, state}

      state.shutdown_check.() ->
        Logger.info(
          "Vagus.Addon.Watchdog: host shutdown in flight; ignoring #{action_type} event for #{slug}"
        )

        {:noreply, state}

      not eligible?(slug, state) ->
        {:noreply, state}

      throttled?(state) ->
        Logger.warning(
          "Vagus.Addon.Watchdog: global restart throttle hit (#{@throttle_max_starts}/" <>
            "#{@throttle_window_ms}ms); ignoring #{action_type} event for #{slug}"
        )

        {:noreply, state}

      true ->
        {:noreply, start_sequence(slug, action_type, state)}
    end
  end

  defp eligible?(slug, state) do
    case State.get(slug, state.state_server) do
      {:ok, %{state: :started, watchdog: true}} -> true
      _other -> false
    end
  end

  defp throttled?(state) do
    now = state.clock.()
    length(prune_starts(state.starts, now)) >= @throttle_max_starts
  end

  defp prune_starts(starts, now) do
    Enum.filter(starts, fn t -> now - t < @throttle_window_ms end)
  end

  defp start_sequence(slug, action_type, state) do
    now = state.clock.()
    starts = [now | prune_starts(state.starts, now)]

    cfg = %{
      manager: state.manager,
      running_check: state.running_check,
      backoff_base_ms: state.backoff_base_ms,
      sleep: state.sleep,
      state_server: state.state_server,
      attempt_timeout_ms: state.attempt_timeout_ms
    }

    task = Task.async(fn -> run_sequence(slug, action_type, cfg) end)

    # review W1 failsafe — see the `{:sequence_deadline, ...}` handle_info
    # clause above.
    Process.send_after(
      self(),
      {:sequence_deadline, slug, task.ref},
      state.sequence_deadline_ms
    )

    %{state | tasks: Map.put(state.tasks, slug, task), starts: starts}
  end

  defp slug_for_ref(tasks, ref) do
    Enum.find_value(tasks, fn {slug, task} -> if task.ref == ref, do: slug end)
  end

  ## Restart sequence (runs inside the Task, never touches GenServer state)

  @doc false
  def run_sequence(slug, action_type, cfg) do
    try_attempt(slug, action_type, 1, cfg)
  rescue
    e ->
      Logger.error(
        "Vagus.Addon.Watchdog: restart sequence for #{slug} crashed (#{Exception.format(:error, e, __STACKTRACE__)}); giving up"
      )

      give_up(slug, cfg)
  catch
    kind, reason ->
      Logger.error(
        "Vagus.Addon.Watchdog: restart sequence for #{slug} #{kind}ed (#{inspect(reason)}); giving up"
      )

      give_up(slug, cfg)
  end

  defp try_attempt(slug, action_type, attempt, cfg) do
    cond do
      cfg.running_check.(slug) ->
        :ok

      not still_eligible?(slug, cfg) ->
        :ok

      true ->
        case perform_attempt(action_type, slug, cfg) do
          {:ok, _result} ->
            Logger.info(
              "Vagus.Addon.Watchdog: #{slug} restarted successfully on attempt #{attempt}/#{@max_attempts}"
            )

            :ok

          _error when attempt >= @max_attempts ->
            give_up(slug, cfg)

          _error ->
            cfg.sleep.(backoff_ms(attempt, cfg))
            try_attempt(slug, action_type, attempt + 1, cfg)
        end
    end
  end

  defp still_eligible?(slug, cfg) do
    case State.get(slug, cfg.state_server) do
      {:ok, %{state: :started, watchdog: true}} -> true
      _other -> false
    end
  end

  defp perform_attempt(:die, slug, cfg),
    do: bounded_manager_call(cfg, fn -> cfg.manager.start_slug(slug, []) end)

  defp perform_attempt(:unhealthy, slug, cfg),
    do: bounded_manager_call(cfg, fn -> cfg.manager.restart(slug, []) end)

  # review W1: bounds a single manager call so a hung call (e.g. blocked on
  # the per-slug `:global.trans/3` lock inside `Vagus.Addon.Manager`, or a
  # manager that simply never returns) cannot wedge this attempt — and
  # therefore this whole sequence Task — forever. A timeout here is folded
  # into the same `_error` clause `try_attempt/4` already uses for any other
  # failure: it counts as a failed attempt and continues the backoff/attempt
  # loop exactly like an `{:error, _}` return would.
  #
  # Killing the inner Task with `:brutal_kill` does NOT release any
  # `:global.trans/3` lock the killed process might have been *waiting* to
  # acquire: `:global` only ever grants (and later releases-on-death) a lock
  # to a process that has actually entered the critical section. A process
  # still queued waiting for the lock holds nothing to release — killing it
  # is exactly as safe as it dying any other way while still waiting.
  defp bounded_manager_call(cfg, fun) do
    inner = Task.async(fun)

    case Task.yield(inner, cfg.attempt_timeout_ms) || Task.shutdown(inner, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :attempt_timeout}
    end
  end

  defp backoff_ms(attempt, cfg), do: cfg.backoff_base_ms * round(:math.pow(2, attempt - 1))

  defp give_up(slug, cfg) do
    Logger.error(
      "Vagus.Addon.Watchdog: #{slug} failed to restart after #{@max_attempts} attempts; " <>
        "giving up and demoting to :stopped"
    )

    case State.get(slug, cfg.state_server) do
      {:ok, %{config: config}} -> State.put(config, :stopped, server: cfg.state_server)
      :error -> :ok
    end

    :ok
  end

  ## Defaults

  defp maybe_subscribe(events) do
    if event_server_alive?(events) do
      try do
        Vagus.Runtime.Events.subscribe(events)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp event_server_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp event_server_alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp event_server_alive?(_other), do: false

  # Liveness for the restart sequence. A native "virtual add-on" has no container
  # to inspect (MQ-P3-T4) — a live broker subtree registered under `broker_name`
  # IS the liveness signal. A running native broker short-circuits to `true`;
  # everything else (a stopped native, or any container) falls through to the
  # Docker inspect (a stopped native 404s → false, which is correct).
  defp default_running_check(slug) do
    id = "addon_" <> slug

    if is_pid(Process.whereis(Vagus.Addon.Backend.Native.broker_name(id))) do
      true
    else
      case Docker.inspect_container(id) do
        {:ok, %{"State" => %{"Running" => true}}} -> true
        _other -> false
      end
    end
  end

  defp default_clock, do: System.monotonic_time(:millisecond)
end
