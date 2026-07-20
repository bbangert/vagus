defmodule Vagus.Core.EventPusher do
  @moduledoc """
  Persistent WS client manager for `supervisor/event` pushes to Core
  (`docs/contract-2026.7.md` §4), built on the vendored `fresh`.

  This module is the manager half of a monitor+backoff pair — mirroring
  `Vagus.Engine.Manager`'s house pattern for supervising an external
  resource without ever letting its restart intensity threaten the parent
  supervisor's budget. `Vagus.Core.EventPusher.Connection` (the `Fresh`
  behaviour module) is started unlinked via `Fresh.start/4` and monitored
  (`Process.monitor/1`), never added as a supervised child directly: an
  ordinary reconnect (network blip) is absorbed entirely inside `Fresh`
  itself (see `Connection`'s moduledoc), and only an outright crash of
  that process reaches this manager as a `:DOWN` message, at which point
  this GenServer's own capped-exponential backoff (5s -> 60s, doubling)
  schedules a fresh connection attempt — exactly like `Engine.Manager`'s
  `@retry_ms`/`:retry_daemon_start` dance, just with backoff instead of a
  fixed interval.

  Lazy by design: no connection is attempted until
  `Vagus.Core.TokenStore` has a refresh token (subscribed at `init/1`,
  also checked directly in case one is already present — e.g. this
  process restarted after the token had already landed). `push/2` before
  that point (or during any later disconnect) buffers into a bounded
  queue (`@max_queue_size`, drop-oldest) since a lost event only means a
  future poll will be a little late — never a hard requirement to
  redeliver.

  Per-connection id sequencing: Core's WS API requires strictly increasing
  `id`s within one connection, but no relationship between connections —
  so the id counter resets to `1` every time `Connection` reports a fresh
  `handle_connect/3` (`{:event_pusher_connection, :connected, pid}`), and
  the queue is flushed (assigning ids in send order) only once `auth_ok`
  is reported (`{:event_pusher_connection, :ready, pid}`).
  """

  use GenServer

  require Logger

  alias Vagus.Core.EventPusher.Connection
  alias Vagus.Core.TokenStore

  @max_queue_size 50
  @backoff_initial 5_000
  @backoff_max 60_000

  @doc """
  Starts the manager.

  Options:

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:ws_url` - overrides the computed Core WS URL (for tests).
    * `:token_store` - the `Vagus.Core.TokenStore` server, defaults to
      `Vagus.Core.TokenStore`.
    * `:client` - the `Vagus.Core.Client` server the WS connection uses
      for access tokens, defaults to `Vagus.Core.Client`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Casts an event's `data` map for delivery as a `supervisor/event` WS push
  (`%{"id" => n, "type" => "supervisor/event", "data" => event_data}`).
  Buffered (bounded, drop-oldest) if not currently connected+authed.
  """
  @spec push(map(), GenServer.server()) :: :ok
  def push(event_data, server \\ __MODULE__) when is_map(event_data) do
    GenServer.cast(server, {:push, event_data})
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    token_store = Keyword.get(opts, :token_store, Vagus.Core.TokenStore)
    TokenStore.subscribe(token_store)

    state = %{
      ws_url: Keyword.get(opts, :ws_url, ws_url()),
      token_store: token_store,
      client: Keyword.get(opts, :client, Vagus.Core.Client),
      connection_pid: nil,
      monitor_ref: nil,
      ready: false,
      next_id: 1,
      queue: :queue.new(),
      queue_size: 0,
      backoff_ms: @backoff_initial
    }

    state =
      if TokenStore.get_refresh_token(token_store) do
        connect(state)
      else
        state
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:push, event_data}, state) do
    if state.ready and state.connection_pid do
      {:noreply, send_now(event_data, state)}
    else
      {:noreply, enqueue(state, event_data)}
    end
  end

  @impl GenServer
  def handle_info({:token_store, :refresh_token_available}, %{connection_pid: nil} = state) do
    {:noreply, connect(state)}
  end

  def handle_info({:token_store, :refresh_token_available}, state), do: {:noreply, state}

  def handle_info({:event_pusher_connection, :connected, pid}, %{connection_pid: pid} = state) do
    {:noreply, %{state | ready: false, next_id: 1, backoff_ms: @backoff_initial}}
  end

  def handle_info({:event_pusher_connection, :ready, pid}, %{connection_pid: pid} = state) do
    {:noreply, flush(%{state | ready: true})}
  end

  # Stale message from a connection pid that's no longer current - ignore.
  def handle_info({:event_pusher_connection, _event, _pid}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    Logger.warning(
      "Vagus.Core.EventPusher: WS connection is down (#{inspect(reason)}), " <>
        "retrying in #{state.backoff_ms}ms"
    )

    Process.send_after(self(), :retry_connect, state.backoff_ms)

    {:noreply,
     %{
       state
       | connection_pid: nil,
         monitor_ref: nil,
         ready: false,
         backoff_ms: next_backoff(state.backoff_ms)
     }}
  end

  def handle_info(:retry_connect, %{connection_pid: nil} = state) do
    {:noreply, connect(state)}
  end

  # Already reconnected by some other path (or a stale timer) - no-op.
  def handle_info(:retry_connect, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp connect(state) do
    case TokenStore.get_refresh_token(state.token_store) do
      nil -> state
      _token -> start_connection(state)
    end
  end

  defp start_connection(state) do
    # Two independent backoffs, not one reused value: `conn_opts` here are
    # `Fresh`'s own internal reconnect options (real options it understands -
    # see `vendor/fresh/lib/fresh/option.ex`), which absorb ordinary
    # network-level reconnects entirely inside the `Connection` process.
    # This module's own `@backoff_initial`/`next_backoff/1` (used in the
    # `:DOWN` handler below) is unrelated - it only ever governs scheduling
    # a fresh `start_connection/1` after the `Connection` process itself has
    # died outright.
    conn_opts = [backoff_initial: @backoff_initial, backoff_max: @backoff_max]
    conn_state = %{manager: self(), client: state.client}

    case Fresh.start(state.ws_url, Connection, conn_state, conn_opts) do
      {:ok, pid} ->
        %{
          state
          | connection_pid: pid,
            monitor_ref: Process.monitor(pid),
            ready: false,
            next_id: 1
        }

      {:error, reason} ->
        Logger.error(
          "Vagus.Core.EventPusher: failed to start WS connection " <>
            "(#{inspect(reason)}), retrying in #{state.backoff_ms}ms"
        )

        Process.send_after(self(), :retry_connect, state.backoff_ms)
        %{state | backoff_ms: next_backoff(state.backoff_ms)}
    end
  end

  defp next_backoff(current), do: min(current * 2, @backoff_max)

  defp send_now(event_data, state) do
    frame = %{"id" => state.next_id, "type" => "supervisor/event", "data" => event_data}
    Fresh.send(state.connection_pid, {:text, Jason.encode!(frame)})
    %{state | next_id: state.next_id + 1}
  end

  defp enqueue(state, event_data) do
    if state.queue_size >= @max_queue_size do
      {{:value, _dropped}, trimmed} = :queue.out(state.queue)
      %{state | queue: :queue.in(event_data, trimmed)}
    else
      %{state | queue: :queue.in(event_data, state.queue), queue_size: state.queue_size + 1}
    end
  end

  defp flush(state) do
    state.queue
    |> drain()
    |> Enum.reduce(%{state | queue: :queue.new(), queue_size: 0}, &send_now/2)
  end

  defp drain(queue), do: drain(queue, [])

  defp drain(queue, acc) do
    case :queue.out(queue) do
      {{:value, event}, rest} -> drain(rest, [event | acc])
      {:empty, _rest} -> Enum.reverse(acc)
    end
  end

  defp ws_url do
    Application.get_env(:vagus, :core_base_url, "http://localhost:8123")
    |> String.replace_leading("https://", "wss://")
    |> String.replace_leading("http://", "ws://")
    |> Kernel.<>("/api/websocket")
  end
end
