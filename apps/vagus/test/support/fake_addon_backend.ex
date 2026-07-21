defmodule Vagus.Addon.Backend.Fake do
  @moduledoc """
  A no-daemon `Vagus.Addon.Backend` for router-level lifecycle tests
  (`test/vagus/api/addon_lifecycle_router_test.exs`) — install/start/stop/
  restart/uninstall all need a backend that succeeds without a real Docker
  daemon. Injected via `config :vagus, :addon_backend` (see
  `Vagus.Addon.Manager`'s moduledoc) rather than an explicit `:backend` opt,
  since the router calls `Manager` with no opts at all.

  M4-P6-T2 adds an opt-in call recorder (`reset_calls/0` + `calls/0`) so
  backup-lifecycle tests (e.g. a cold-mode add-on's `stop`/`start` around a
  snapshot) can observe *which* backend calls happened, not just the
  resulting `Vagus.Addon.State`. Backed by a bare ETS table (no process to
  supervise — it's owned by whichever test process last called
  `reset_calls/0`, and is torn down for free when that test process exits),
  not a GenServer/Agent; only created on the first `reset_calls/0`, so
  callers that never touch it (the plain lifecycle tests) pay nothing and
  see no behavior change.
  """

  @behaviour Vagus.Addon.Backend

  @table __MODULE__.Calls

  @doc "Creates (if needed) and clears the call recorder."
  @spec reset_calls() :: :ok
  def reset_calls do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, :ordered_set]),
      else: :ets.delete_all_objects(@table)

    :ok
  end

  @doc "Recorded calls since the last `reset_calls/0`, oldest first. `[]` if never reset."
  @spec calls() :: [term()]
  def calls do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table |> :ets.tab2list() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    end
  end

  # Ordered by a monotonic integer key (not insertion order into a list) so
  # this stays a plain ETS insert with no read-modify-write race.
  defp record(msg) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {System.unique_integer([:monotonic]), msg})

    :ok
  end

  @impl true
  def pull(_spec) do
    record(:pull)
    :ok
  end

  @impl true
  def create(_spec) do
    record(:create)
    {:ok, "fake-id"}
  end

  @impl true
  def start(id) do
    record({:start, id})
    :ok
  end

  @impl true
  def stop(id, _opts \\ []) do
    record({:stop, id})
    :ok
  end

  @impl true
  def remove(id, _opts \\ []) do
    record({:remove, id})
    :ok
  end

  @impl true
  def state(_id), do: {:ok, :running}
end
