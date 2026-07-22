defmodule Vagus.Mqtt.Broker.AuthCache do
  @moduledoc """
  A short-TTL negative (failure) cache for broker CONNECT auth (M5, review
  hardening). Owns a per-broker public ETS table that `Vagus.Mqtt.Broker.Auth`
  reads/writes directly from the connection processes.

  Rationale: `Vagus.Auth`'s cache is positive-only *by deliberate design* (a
  Core 401 is NOT cached, so a user who fixes their password isn't locked out —
  see `test/vagus/auth_test.exs` "Core 401 → false, not cached"). That's correct
  for the interactive `/auth` path but leaves the MQTT broker open to reconnect
  storms: a client hammering the SAME bad credentials would drive a synchronous
  Core `api/hassio_auth` round-trip on every CONNECT. This cache short-circuits
  that, scoped to the MQTT surface only so the `/auth` decision is untouched.

  Entries are keyed by a `sha256(term_to_binary({username, password}))` digest —
  never plaintext, and unambiguous across the user/pass boundary (matching
  `Vagus.Auth`'s keying). Because the key is the *exact* `{username, password}`
  pair, caching a failure never blocks a subsequent correct password (a different
  key) — it only collapses repeated *identical* bad attempts. The TTL is short so
  a genuinely-changed Core password re-checks quickly.

  Started first in the `Vagus.Mqtt.Broker` subtree (before the listener) under
  `:rest_for_one`, so the table always exists whenever the listener is accepting
  connections. Lookups fail open — a missing table means "not blocked", never a
  crash — for the brief window during a supervised restart.
  """

  use GenServer

  @default_ttl_ms 5_000
  @sweep_ms 30_000

  @doc "Starts the cache. `:name` (required) is both the process and the ETS table name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The digest key for a credential pair (never store plaintext)."
  @spec key(String.t(), String.t()) :: binary()
  def key(username, password) do
    :crypto.hash(:sha256, :erlang.term_to_binary({username, password}))
  end

  @doc "True if `key` has a live failure entry. Fails open (false) if the table is absent."
  @spec blocked?(atom(), binary()) :: boolean()
  def blocked?(table, key) do
    case safe_lookup(table, key) do
      [{^key, expiry}] -> System.monotonic_time(:millisecond) < expiry
      _ -> false
    end
  end

  @doc "Records a failed attempt for `key`, blocking repeats for `ttl_ms`. No-op if the table is absent."
  @spec record_failure(atom(), binary(), pos_integer()) :: :ok
  def record_failure(table, key, ttl_ms \\ @default_ttl_ms) do
    if :ets.whereis(table) != :undefined do
      :ets.insert(table, {key, System.monotonic_time(:millisecond) + ttl_ms})
    end

    :ok
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.fetch!(opts, :name)

    :ets.new(table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table} = state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp safe_lookup(table, key) do
    if :ets.whereis(table) != :undefined, do: :ets.lookup(table, key), else: []
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
