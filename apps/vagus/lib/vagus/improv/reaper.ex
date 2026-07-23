defmodule Vagus.Improv.Reaper do
  @moduledoc """
  Frees the Improv provisioning group once it can never be needed again
  this boot (Ben's phase-2 rule: after wifi is up, drop Improv and leave
  only the BlueZ daemons — memory back on a 1 GB Pi).

  Improv arms at most once per boot (offline at boot + 20s grace) and
  self-disarms after a successful provision, so once the aggregate
  connection reaches `:internet` while the manager sits `:disarmed`, the
  whole `:one_for_all` group is dead weight. This GenServer waits for
  exactly that state, then `Supervisor.terminate_child/2` +
  `Supervisor.delete_child/2` the `Improv.Supervisor` child out of
  `Vagus.Bluetooth` and stops itself (`:normal`, `restart: :transient`).

  Supervision notes:

    * An explicit `terminate_child` does NOT trigger the parent's
      `:rest_for_one` cascade (that's crash-restart behavior only), and
      `delete_child` removes the spec, so a later `bluetoothd` restart
      cannot resurrect the group.
    * Positioned last in `Vagus.Bluetooth`'s tree — after the Improv group
      it reaps — so terminating an EARLIER sibling is safe, and its own
      normal exit disturbs nothing.
    * The disarmed-check answers `:disarmed` when the Improv manager isn't
      running at all (already reaped / never mounted), so a revived reaper
      re-reaps idempotently (`terminate_child` on a deleted id returns
      `{:error, :not_found}`, treated as done).

  Waiting is event-driven (vintage_net `["connection"]` subscription) with
  a paced re-check: the first check runs `@check_delay_ms` after
  `:internet` appears (comfortably past improv's ~10s provisioned-hold so
  the client sees its PROVISIONED read), and while Improv is mid-session
  (`:advertising`/`:connected`/...) the reap is re-tried every
  `@recheck_ms` rather than interrupting a user.

  Collaborators are injectable for host tests: `:subscribe`, `:connection`,
  `:improv_state`, `:reap` (0-arity funs) plus `:check_delay_ms`,
  `:recheck_ms`, `:name`.
  """

  use GenServer, restart: :transient

  require Logger

  @check_delay_ms 15_000
  @recheck_ms 30_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      connection: Keyword.get(opts, :connection, &default_connection/0),
      improv_state: Keyword.get(opts, :improv_state, &default_improv_state/0),
      reap: Keyword.get(opts, :reap, &default_reap/0),
      check_delay_ms: Keyword.get(opts, :check_delay_ms, @check_delay_ms),
      recheck_ms: Keyword.get(opts, :recheck_ms, @recheck_ms),
      check_scheduled?: false
    }

    Keyword.get(opts, :subscribe, &default_subscribe/0).()

    # Already online at init (normal wired boot): improv never armed and
    # never will this boot — schedule the reap without waiting for an event.
    state =
      if state.connection.() == :internet do
        schedule_check(state)
      else
        state
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_info({VintageNet, ["connection"], _old, :internet, _meta}, state) do
    {:noreply, schedule_check(state)}
  end

  def handle_info({VintageNet, _property, _old, _new, _meta}, state), do: {:noreply, state}

  def handle_info(:maybe_reap, state) do
    state = %{state | check_scheduled?: false}

    cond do
      state.connection.() != :internet ->
        # Connectivity blipped away again — wait for the next :internet event.
        {:noreply, state}

      state.improv_state.() != :disarmed ->
        # A provisioning session is live (or the post-provision hold hasn't
        # elapsed) — don't yank the GATT service out from under a client.
        {:noreply, schedule_check(%{state | check_scheduled?: true}, state.recheck_ms)}

      true ->
        Logger.info("Vagus.Improv.Reaper: network up + Improv disarmed — reaping Improv group")
        state.reap.()
        {:stop, :normal, state}
    end
  end

  defp schedule_check(%{check_scheduled?: true} = state), do: state

  defp schedule_check(state) do
    schedule_check(%{state | check_scheduled?: true}, state.check_delay_ms)
  end

  defp schedule_check(state, delay_ms) do
    Process.send_after(self(), :maybe_reap, delay_ms)
    state
  end

  # Belt-and-braces: improv 0.1.1's `status/1` already catches the
  # not-running exit internally and answers `%{state: :disarmed, ...}`, so
  # this outer catch is redundant today — kept because the reaper's
  # idempotency must not silently depend on that library implementation
  # detail surviving an upgrade.
  defp default_improv_state do
    Improv.status().state
  catch
    :exit, _ -> :disarmed
  end

  # terminate_child + delete_child are two separate synchronous calls, not
  # an atomic pair: a bluetoothd crash landing exactly between them can
  # resurrect the group via the :rest_for_one cascade before the spec is
  # deleted. That race self-heals — the same cascade also restarts THIS
  # reaper (a :transient child's spec survives its :normal stop), and the
  # fresh reaper re-checks and re-reaps — so it costs one extra cycle, not
  # correctness.
  defp default_reap do
    case Supervisor.terminate_child(Vagus.Bluetooth, Improv.Supervisor) do
      :ok -> :ok = Supervisor.delete_child(Vagus.Bluetooth, Improv.Supervisor)
      {:error, :not_found} -> :ok
    end
  end

  # vintage_net is target-only (see Vagus.Improv for the pattern); the
  # reaper itself is only mounted on target, host tests inject.
  if Mix.target() == :host do
    defp default_subscribe, do: :ok
    defp default_connection, do: :disconnected
  else
    defp default_subscribe do
      VintageNet.subscribe(["connection"])
    end

    defp default_connection do
      VintageNet.get(["connection"], :disconnected)
    end
  end
end
