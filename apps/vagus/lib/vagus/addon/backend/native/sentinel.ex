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
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.State

  # Grace period after a DOWN before deciding a restart didn't happen — the
  # DynamicSupervisor restarts near-instantly, so a live re-check this soon
  # after distinguishes "restarted" from "gave up".
  @recheck_ms 1_000

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
      recheck_ms: Keyword.get(opts, :recheck_ms, @recheck_ms)
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
      demote(id, state.state_mod)
      {:noreply, state}
    end
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

  defp demote(id, state_mod) do
    slug = Native.slug_from_id(id)

    case state_mod.get(slug) do
      {:ok, %{config: config}} ->
        Logger.warning(
          "Vagus.Addon.Backend.Native.Sentinel: broker #{slug} did not restart — demoting to :stopped"
        )

        state_mod.put(config, :stopped)

      _ ->
        :ok
    end
  end
end
