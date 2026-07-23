defmodule Vagus.Addon.Backend.Native.Sentinel do
  @moduledoc """
  Keeps `Vagus.Addon.State` honest for `:native` add-ons (M5, MQ-P2-T3).

  A containerized add-on's crash/restart is tracked by `Vagus.Addon.Watchdog`
  via Docker `die` events; a native add-on (a BEAM subtree) never emits one, and
  OTP supervision restarts it in-process without touching `State`. That's the
  right behaviour for the *stay-alive* concern — but if the subtree's restart
  budget is exhausted and the `DynamicSupervisor` gives up, the process is gone
  while `State` still reads `:started`. This sentinel closes that gap: it
  monitors each started broker and, when one dies **without** OTP bringing it
  back, demotes its `State` entry to `:stopped` — mirroring `Watchdog.give_up/2`.

  A manual `stop`/`remove` calls `unwatch/1` first, so an intentional teardown is
  never mistaken for a crash. `watch/1`/`unwatch/1` no-op if the sentinel isn't
  running (isolated tests, `:host` without the full tree), matching the
  best-effort style of the manager's other side effects.

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

  # Grace period after a DOWN before deciding a restart didn't happen — the
  # DynamicSupervisor restarts near-instantly, so a live re-check this soon
  # after distinguishes "restarted" from "gave up".
  @recheck_ms 1_000

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
    # Testability: override the demotion sink (default Vagus.Addon.State) and the
    # recheck delay so a hermetic test doesn't wait a real second.
    state = %{
      by_ref: %{},
      by_id: %{},
      state_mod: Keyword.get(opts, :state_mod, State),
      recheck_ms: Keyword.get(opts, :recheck_ms, @recheck_ms),
      revive_fun: Keyword.get(opts, :revive_fun, &Vagus.Addon.Manager.start/1),
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
  def handle_cast({:watch, id}, state), do: {:noreply, monitor(id, state)}
  def handle_cast({:unwatch, id}, state), do: {:noreply, demonitor(id, state)}

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
    if is_pid(Process.whereis(Native.broker_name(id))) do
      # OTP restarted it — resume watching, State stays :started.
      {:noreply, monitor(id, state)}
    else
      demote(id, state)
      {:noreply, state}
    end
  end

  def handle_info({:revive, id}, state) do
    slug = Native.slug_from_id(id)

    case state.state_mod.get(slug) do
      # Still down, still installed, and STILL boot:auto on the current
      # config (it may have been flipped to manual since the demotion
      # scheduled this — re-checked here and again on every retry;
      # Copilot review, PR #7) — attempt the restart. Success re-arms the
      # watch through Native.start inside Manager.start/1.
      {:ok, %{state: :stopped, config: %{boot: "auto"} = config}} ->
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

      # Uninstalled, or someone started it manually in the meantime — drop.
      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp monitor(id, state) do
    state = demonitor(id, state)

    case Process.whereis(Native.broker_name(id)) do
      nil ->
        state

      pid ->
        ref = Process.monitor(pid)
        %{state | by_ref: Map.put(state.by_ref, ref, id), by_id: Map.put(state.by_id, id, ref)}
    end
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

  defp demote(id, state) do
    slug = Native.slug_from_id(id)

    case state.state_mod.get(slug) do
      {:ok, %{config: config}} ->
        Logger.warning(
          "Vagus.Addon.Backend.Native.Sentinel: broker #{slug} did not restart — demoting to :stopped"
        )

        state.state_mod.put(config, :stopped)

        if auto_boot?(config) do
          Process.send_after(self(), {:revive, id}, state.revive_delay_ms)
        end

      _ ->
        :ok
    end
  end

  # Pattern-based (not struct-field access) so test fakes with opaque
  # configs read as non-auto and never schedule a revive.
  defp auto_boot?(%{boot: "auto"}), do: true
  defp auto_boot?(_config), do: false
end
