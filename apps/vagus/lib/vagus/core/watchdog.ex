defmodule Vagus.Core.Watchdog do
  @moduledoc """
  The container-event half of the Core watchdog — crash-LOOP detection.
  The API-probe half is the sibling `Vagus.Core.Watchdog.Probe`; like the
  add-on pair, the two are independent code paths with independent
  counters.

  ## Deliberate deviation from upstream (plan "Locked decisions")

  Real Supervisor reacts to every FAILED/UNHEALTHY docker event with a
  restart ladder (`homeassistant/core.py:672-741`) because upstream owns
  every Core restart itself. Vagus keeps the device-proven
  `RestartPolicy: unless-stopped` on the Core container, so the *engine*
  already heals single crashes — this module only steps in when the
  engine's restarts aren't sticking: **≥ 3 crash `die` events for the Core
  container within a 10-minute sliding window** means the container is
  crash-looping right through its restart policy (bad config/image state
  the same process can't fix), and the escalation is one
  `Vagus.Core.Lifecycle.rebuild/1` — the same terminal action upstream's
  FAILED ladder ends in.

  ## Only crashes count

  A `die` with **exit code 0** is a deliberate stop — the engine reports
  `unless-stopped`-managed containers and every Vagus-initiated
  stop/restart/rebuild/update that way — and is never counted. A die with
  a missing/unparseable exit code is ignored too (can't confirm a crash).
  Dies caused by a Vagus lifecycle op in flight are further covered by the
  `{:error, :busy}` skip: if this watchdog does fire while an op owns the
  container, `rebuild/1` returns busy and the attempt evaporates.

  ## Rate limiting

  Watchdog-initiated actions are capped at 10 per 30 minutes (upstream
  `const.py:16-19`), a hand-rolled sliding window of action timestamps in
  the house style (`Vagus.Addon.Watchdog` precedent) — independent of the
  probe half's attempt ladder, like upstream's separate mechanisms. The
  die window is cleared whenever the threshold trips (action dispatched,
  or dropped by the limiter), so each rebuild needs 3 *fresh* crashes.

  ## Event source

  Subscribes to `Vagus.Runtime.Events` (`:events` opt) in `init/1`,
  tolerating an absent/disabled server the same way `Vagus.Addon.Watchdog`
  does — `Events` is gated by `:events_enabled` (not target-only), and the
  probe half must keep working even when the event stream isn't there.
  Also accepts `{:docker_event, event}` sent directly (tests, alternate
  sources) — the message shape is the only contract.

  ## Options (all injectable — tests never touch a real engine/store)

    * `:name` — GenServer name, default `#{inspect(__MODULE__)}`.
    * `:events` — the `Vagus.Runtime.Events` server, default
      `Vagus.Runtime.Events`.
    * `:token_store` — the `Vagus.Core.TokenStore` server, default
      `Vagus.Core.TokenStore` (persisted `watchdog` option gates actions).
    * `:rebuild` — zero-arity `-> :ok | {:error, term()}`, default
      `fn -> Vagus.Core.Lifecycle.rebuild() end`.
    * `:clock` — zero-arity monotonic-ms fun, default
      `System.monotonic_time(:millisecond)`.
    * `:attempt_timeout_ms` — bounds the rebuild call, default `900_000`
      (15 min — above `Lifecycle`'s internal 10-min health gate).
    * `:action_deadline_ms` — GenServer-side failsafe that force-clears a
      wedged rebuild task, default `1_800_000` (30 min).

  Gated (with the sibling probe half, under
  `Vagus.Core.Watchdog.Supervisor`) by `config :vagus, :core_watchdog`
  (`true` only in `config/target.exs`).
  """

  use GenServer

  require Logger

  alias Vagus.Core.{Container, Lifecycle, TokenStore}

  @die_window_ms 10 * 60 * 1_000
  @die_threshold 3
  # Upstream const.py:16-19: 10 watchdog actions / 30 min.
  @throttle_max_actions 10
  @throttle_window_ms 30 * 60 * 1_000
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
    events = Keyword.get(opts, :events, Vagus.Runtime.Events)
    maybe_subscribe(events)

    st = %{
      events: events,
      token_store: Keyword.get(opts, :token_store, TokenStore),
      rebuild: Keyword.get(opts, :rebuild, fn -> Lifecycle.rebuild() end),
      clock: Keyword.get(opts, :clock, &default_clock/0),
      attempt_timeout_ms: Keyword.get(opts, :attempt_timeout_ms, @default_attempt_timeout_ms),
      action_deadline_ms: Keyword.get(opts, :action_deadline_ms, @default_action_deadline_ms),
      # Crash-die timestamps (ms, per :clock) inside the sliding window.
      dies: [],
      # Watchdog-action timestamps for the 10/30min limiter.
      actions: [],
      # nil | %Task{} — at most one rebuild in flight.
      task: nil
    }

    {:ok, st}
  end

  @impl GenServer
  def handle_info({:docker_event, %{action: "die", name: name} = event}, st) do
    if name == Container.name() do
      {:noreply, handle_die(event, st)}
    else
      {:noreply, st}
    end
  end

  def handle_info({:docker_event, _event}, st), do: {:noreply, st}

  # Completed rebuild Task — see the probe half for the identical
  # reply/:DOWN/deadline trio.
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = st) do
    Process.demonitor(ref, [:flush])

    case result do
      {:error, :busy} ->
        Logger.debug(
          "Vagus.Core.Watchdog: rebuild skipped, a Core lifecycle op is already in flight " <>
            "(its stops/dies are expected)"
        )

      other ->
        Logger.warning("Vagus.Core.Watchdog: crash-loop rebuild finished (#{inspect(other)})")
    end

    {:noreply, %{st | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: task} = st) do
    case task do
      %Task{ref: ^ref} ->
        if reason != :normal do
          Logger.warning(
            "Vagus.Core.Watchdog: rebuild task went down unexpectedly (#{inspect(reason)})"
          )
        end

        {:noreply, %{st | task: nil}}

      _other ->
        {:noreply, st}
    end
  end

  def handle_info({:action_deadline, ref}, %{task: task} = st) do
    case task do
      %Task{ref: ^ref} ->
        Logger.error(
          "Vagus.Core.Watchdog: rebuild task exceeded its #{st.action_deadline_ms}ms " <>
            "deadline; force-killing (watchdog wedge recovered)"
        )

        Task.shutdown(task, :brutal_kill)
        {:noreply, %{st | task: nil}}

      _other ->
        {:noreply, st}
    end
  end

  def handle_info(_other, st), do: {:noreply, st}

  ## Crash-loop accounting

  defp handle_die(%{exit_code: exit_code}, st)
       when not is_integer(exit_code) or exit_code == 0 do
    # Zero exit = deliberate stop (engine-reported for unless-stopped
    # containers and every Vagus-initiated op); nil/unparseable = can't
    # confirm a crash. Neither counts toward the loop window.
    st
  end

  defp handle_die(%{exit_code: exit_code}, st) do
    cond do
      st.task != nil ->
        # Our own rebuild is tearing the old container down — its churn is
        # expected, not fresh evidence.
        Logger.debug("Vagus.Core.Watchdog: die during in-flight rebuild ignored")
        st

      not watchdog_on?(st.token_store) ->
        Logger.debug("Vagus.Core.Watchdog: watchdog option off; ignoring Core die event")
        st

      true ->
        count_die(exit_code, st)
    end
  end

  defp count_die(exit_code, st) do
    now = st.clock.()
    dies = [now | prune(st.dies, now, @die_window_ms)]
    count = length(dies)

    if count >= @die_threshold do
      trigger_rebuild(count, st, now)
    else
      Logger.warning(
        "Vagus.Core.Watchdog: Core crashed (exit #{exit_code}) — #{count}/#{@die_threshold} " <>
          "within the #{div(@die_window_ms, 60_000)}min window (engine restart policy is " <>
          "handling it)"
      )

      %{st | dies: dies}
    end
  end

  # Threshold tripped — the engine's unless-stopped restarts aren't
  # sticking. Either way (dispatched or throttled) the die window resets:
  # a future rebuild needs 3 fresh crashes.
  defp trigger_rebuild(count, st, now) do
    actions = prune(st.actions, now, @throttle_window_ms)

    if length(actions) >= @throttle_max_actions do
      Logger.warning(
        "Vagus.Core.Watchdog: crash loop detected (#{count} dies in window) but the " <>
          "#{@throttle_max_actions}/#{div(@throttle_window_ms, 60_000)}min action limit is " <>
          "exhausted; dropping"
      )

      %{st | dies: [], actions: actions}
    else
      Logger.error(
        "Vagus.Core.Watchdog: Core is crash-looping (#{count} crash dies within " <>
          "#{div(@die_window_ms, 60_000)}min despite the engine's restart policy); rebuilding"
      )

      rebuild = st.rebuild
      attempt_timeout_ms = st.attempt_timeout_ms
      task = Task.async(fn -> run_rebuild(rebuild, attempt_timeout_ms) end)
      Process.send_after(self(), {:action_deadline, task.ref}, st.action_deadline_ms)

      %{st | dies: [], actions: [now | actions], task: task}
    end
  end

  defp prune(timestamps, now, window_ms) do
    Enum.filter(timestamps, fn t -> now - t < window_ms end)
  end

  ## Rebuild task body

  # Runs inside the Task — bounded and caught, so a Lifecycle bug can never
  # take the watchdog down with it (same shape as the probe half).
  @doc false
  def run_rebuild(fun, attempt_timeout_ms) do
    inner = Task.async(fun)

    case Task.yield(inner, attempt_timeout_ms) || Task.shutdown(inner, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :attempt_timeout}
    end
  rescue
    e ->
      Logger.error(
        "Vagus.Core.Watchdog: rebuild task crashed " <>
          "(#{Exception.format(:error, e, __STACKTRACE__)})"
      )

      {:error, :crashed}
  catch
    kind, reason ->
      Logger.error("Vagus.Core.Watchdog: rebuild task #{kind}ed (#{inspect(reason)})")
      {:error, :crashed}
  end

  ## Defaults

  defp maybe_subscribe(events) do
    if server_alive?(events) do
      try do
        Vagus.Runtime.Events.subscribe(events)
      catch
        :exit, _reason -> :ok
      end
    else
      Logger.debug(
        "Vagus.Core.Watchdog: events server not running; crash-loop detection idle " <>
          "(the API probe half is unaffected)"
      )
    end

    :ok
  end

  defp server_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp server_alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp server_alive?(_other), do: false

  # The store can be briefly down (mid-restart) when a die event arrives; a
  # crashed watchdog would drop the whole crash window. Fall back to the
  # upstream `true` default instead — same tolerance maybe_subscribe/1 has.
  defp watchdog_on?(token_store) do
    TokenStore.get_watchdog(token_store)
  catch
    :exit, _reason -> true
  end

  defp default_clock, do: System.monotonic_time(:millisecond)
end
