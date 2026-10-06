defmodule Vagus.Addon.Backend.Native.Sentinel do
  @moduledoc """
  Keeps `Vagus.Addon.State` honest for `:native` add-ons (M5, MQ-P2-T3).

  A containerized add-on's crash/restart is tracked by `Vagus.Addon.Watchdog`
  via Docker `die` events; a native add-on (a BEAM subtree) never emits one.
  The broker's own supervisor restarts its children without touching `State`,
  which is right for the *stay-alive* concern — but once that supervisor
  exhausts its restart budget the broker is gone for good (it is a
  `:temporary` child of `Native.Supervisor`) while `State` still reads
  `:started`. This sentinel closes that gap: it monitors each started broker
  and, when one dies and nothing has started it again by the recheck, has
  `Vagus.Addon.Manager.demote/2` record it `:stopped` — mirroring
  `Watchdog.give_up/2`. A demotion that fails is repeated on the recheck
  interval, a bounded number of times.

  A manual `stop`/`remove` calls `unwatch/1` first. That cast can lose to the
  `:DOWN`, so what keeps an intentional teardown from being revived is that it
  recorded `:stopped` before the broker went down. `watch/1`/`unwatch/1` no-op
  if the sentinel isn't running (isolated tests, `:host` without the full
  tree), matching the best-effort style of the manager's other side effects.

  ## Revive (native watchdog, MQ-P6 follow-up)

  Demotion alone left a `boot: auto` native add-on (the default MQTT broker)
  dead until reboot — the container watchdog's die-event restart has no
  native analog, and the broker child is deliberately `:temporary` under
  `Native.Supervisor` (blast-radius containment). So after demoting, the
  sentinel REVIVES a `boot: "auto"` add-on: a delayed `Manager.start/1`
  (fresh token, options re-write, service/discovery re-publish, watch
  re-armed via `Native.start`), retried on a fixed interval with no attempt
  cap — same no-backoff philosophy as `Watchdog.Probe` (§B7.4), and safe
  because each attempt is one supervised call, not a supervision-tree crash
  loop. The revive is skipped if, by the time it fires, the add-on was
  uninstalled or manually started (State is re-read first).
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.State

  # Delay after a DOWN before demoting: nothing restarts a broker by itself,
  # but a start already under way gets to bring it back first.
  @recheck_ms 1_000

  # A demotion that still fails after this many repeats is given up on: what
  # keeps failing that long is not a State restart.
  @demote_retries 5

  # Revive pacing: the first attempt waits out any lingering listener-socket
  # release; failures retry on a fixed interval, uncapped (§B7.4 style).
  @revive_delay_ms 5_000
  @revive_retry_ms 30_000

  @doc "Starts the sentinel."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Begin watching native add-on `id`'s broker subtree for permanent death."
  @spec watch(Vagus.Addon.Backend.id(), GenServer.server()) :: :ok
  def watch(id, server \\ __MODULE__) do
    if Process.whereis(server), do: GenServer.cast(server, {:watch, id})
    :ok
  end

  @doc "Stop watching `id` (an intentional stop/remove, not a crash)."
  @spec unwatch(Vagus.Addon.Backend.id(), GenServer.server()) :: :ok
  def unwatch(id, server \\ __MODULE__) do
    if Process.whereis(server), do: GenServer.cast(server, {:unwatch, id})
    :ok
  end

  @impl GenServer
  def init(opts) do
    # Testability: override the State it reads, the demotion, and the recheck
    # delay so a hermetic test doesn't wait a real second.
    state = %{
      by_ref: %{},
      by_id: %{},
      # id => %{failures:, revive?:} for a demotion being repeated.
      pending: %{},
      state_mod: Keyword.get(opts, :state_mod, State),
      recheck_ms: Keyword.get(opts, :recheck_ms, @recheck_ms),
      revive_fun: Keyword.get(opts, :revive_fun, &Vagus.Addon.Manager.start/1),
      demote_fun: Keyword.get(opts, :demote_fun, &Vagus.Addon.Manager.demote/1),
      revive_delay_ms: Keyword.get(opts, :revive_delay_ms, @revive_delay_ms),
      revive_retry_ms: Keyword.get(opts, :revive_retry_ms, @revive_retry_ms)
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl GenServer
  def handle_continue(:reconcile, state) do
    # A Sentinel restart (crash, or app-level cascade) would otherwise start with
    # an empty watch set and silently un-monitor every already-running native
    # broker — disabling demote-on-give-up until the next fresh start/1. Rebuild
    # the watch set from State's source of truth: every `:started` native add-on.
    reconciled =
      state.state_mod.list()
      |> Enum.filter(fn e -> e.state == :started and e.config.backend == :native end)
      |> Enum.reduce(state, fn e, acc -> monitor("addon_" <> e.config.slug, acc) end)

    {:noreply, reconciled}
  end

  @impl GenServer
  def handle_cast({:watch, id}, state), do: {:noreply, monitor(id, forget(state, id))}

  # Forgotten too: a revive decided before a manual stop must not follow it.
  def handle_cast({:unwatch, id}, state), do: {:noreply, demonitor(id, forget(state, id))}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.by_ref, ref) do
      {:ok, id} ->
        Process.send_after(self(), {:recheck, id}, state.recheck_ms)
        {:noreply, drop(ref, id, state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:recheck, id}, state) do
    case Process.whereis(Native.broker_name(id)) do
      # Something has started it since — resume watching, State stays :started.
      pid when is_pid(pid) -> {:noreply, monitor_pid(id, pid, forget(state, id))}
      nil -> {:noreply, demote(id, state)}
    end
  end

  def handle_info({:revive, id}, state) do
    slug = Native.slug_from_id(id)

    case guarded(fn -> state.state_mod.get(slug) end) do
      # Still down, still installed, and STILL boot:auto on the current
      # config (it may have been flipped to manual since the demotion
      # scheduled this — re-checked here and again on every retry) —
      # attempt the restart. Success re-arms the watch through Native.start
      # inside Manager.start/1.
      {:ok, {:ok, %{state: :stopped, config: %{boot: "auto"} = config}}} ->
        case state.revive_fun.(config) do
          {:ok, _} ->
            Logger.info("Vagus.Addon.Backend.Native.Sentinel: revived #{slug}")

          {:error, reason} ->
            Logger.warning(
              "Vagus.Addon.Backend.Native.Sentinel: revive of #{slug} failed " <>
                "(#{inspect(reason)}); retrying in #{state.revive_retry_ms}ms"
            )

            Process.send_after(self(), {:revive, id}, state.revive_retry_ms)
        end

      # `State` is mid-restart: the revive is still owed.
      :failed ->
        Process.send_after(self(), {:revive, id}, state.revive_retry_ms)

      # Uninstalled, or someone started it manually in the meantime — drop.
      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp monitor(id, state) do
    case Process.whereis(Native.broker_name(id)) do
      nil -> demonitor(id, state)
      pid -> monitor_pid(id, pid, state)
    end
  end

  # For a caller acting on one lookup: a pid that has died since still gets
  # its `:DOWN`, where a second lookup would find nothing and watch nothing.
  defp monitor_pid(id, pid, state) do
    state = demonitor(id, state)
    ref = Process.monitor(pid)
    %{state | by_ref: Map.put(state.by_ref, ref, id), by_id: Map.put(state.by_id, id, ref)}
  end

  defp demonitor(id, state) do
    case Map.fetch(state.by_id, id) do
      {:ok, ref} ->
        Process.demonitor(ref, [:flush])
        drop(ref, id, state)

      :error ->
        state
    end
  end

  defp drop(ref, id, state) do
    %{state | by_ref: Map.delete(state.by_ref, ref), by_id: Map.delete(state.by_id, id)}
  end

  defp forget(state, id), do: %{state | pending: Map.delete(state.pending, id)}

  defp demote(id, state) do
    slug = Native.slug_from_id(id)

    case attempt_demotion(id, slug, state) do
      {:demoted, revive?} ->
        Logger.warning(
          "Vagus.Addon.Backend.Native.Sentinel: broker #{slug} is gone; demoted to :stopped"
        )

        if revive?, do: Process.send_after(self(), {:revive, id}, state.revive_delay_ms)
        forget(state, id)

      # `Native.start/1` casts a watch for every broker it brings up; this
      # does not depend on that cast being behind this message. A broker
      # gone again already left nothing to watch, so the recheck is what
      # demotes it.
      :running ->
        case Process.whereis(Native.broker_name(id)) do
          nil ->
            Process.send_after(self(), {:recheck, id}, state.recheck_ms)
            forget(state, id)

          pid ->
            monitor_pid(id, pid, forget(state, id))
        end

      {:failed, revive?} ->
        retry_demotion(id, slug, revive?, state)

      :not_installed ->
        forget(state, id)
    end
  end

  # Both steps are guarded: either can exit while `State` restarts, and a
  # Sentinel that went down with it comes back watching nothing for a
  # `:started` add-on whose broker is gone.
  defp attempt_demotion(id, slug, state) do
    case guarded(fn -> state.state_mod.get(slug) end) do
      {:ok, {:ok, entry}} ->
        revive? = revive?(id, entry, state)

        case guarded(fn -> state.demote_fun.(slug) end) do
          {:ok, :ok} -> {:demoted, revive?}
          {:ok, {:error, :running}} -> :running
          _failed -> {:failed, revive?}
        end

      {:ok, _no_entry} ->
        :not_installed

      :failed ->
        {:failed, get_in(state.pending, [id, :revive?])}
    end
  end

  defp guarded(fun) do
    {:ok, fun.()}
  catch
    kind, _reason when kind in [:error, :exit] -> :failed
  end

  # Decided by the first read after the death and kept across repeats: a
  # failed demotion can have recorded `:stopped` already, and one revive per
  # death is all that may be scheduled.
  #
  # Revive ONLY when State still read :started — the signature of a genuine
  # crash. A manual stop records :stopped BEFORE terminating the broker, and
  # unwatch/2 is an async cast, so a DOWN/recheck racing the stop must not
  # resurrect an add-on the user just stopped.
  defp revive?(id, entry, state) do
    case get_in(state.pending, [id, :revive?]) do
      nil -> Map.get(entry, :state) == :started and auto_boot?(Map.get(entry, :config))
      decided -> decided
    end
  end

  defp retry_demotion(id, slug, revive?, state) do
    failures = get_in(state.pending, [id, :failures]) || 0

    if failures < @demote_retries do
      Logger.error(
        "Vagus.Addon.Backend.Native.Sentinel: demoting #{slug} failed; " <>
          "retrying in #{state.recheck_ms}ms"
      )

      Process.send_after(self(), {:recheck, id}, state.recheck_ms)
      %{state | pending: Map.put(state.pending, id, %{failures: failures + 1, revive?: revive?})}
    else
      Logger.error(
        "Vagus.Addon.Backend.Native.Sentinel: demoting #{slug} failed " <>
          "#{failures + 1} times; giving up, it may stay :started with no broker"
      )

      forget(state, id)
    end
  end

  # Pattern-based (not struct-field access) so test fakes with opaque
  # configs read as non-auto and never schedule a revive.
  defp auto_boot?(%{boot: "auto"}), do: true
  defp auto_boot?(_config), do: false
end
