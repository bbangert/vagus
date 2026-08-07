defmodule Vagus.Core.EventPusher do
  @moduledoc """
  Persistent WS client manager for `supervisor/event` pushes to Core
  (`docs/contract-2026.7.md` §4).

  ## Two transports, one manager (`Vagus.Core.Transport`)

  Every connection attempt re-resolves the transport, so a socket that
  isn't there yet at boot (Core creates it when it starts) is picked up by
  the next attempt with nothing to invalidate:

    * socket present → `Vagus.Core.EventPusher.SocketConnection` (raw
      `Mint.WebSocket` over `{:local, path}`). Core authenticates the peer
      as the Supervisor user, so there is **no** `auth_required`/`auth`
      handshake and **no** access token — and therefore no reason to wait
      for a refresh token before connecting at all.
    * socket absent → `Vagus.Core.EventPusher.Connection` (the vendored
      `fresh`), today's TCP flow unchanged: lazy until
      `Vagus.Core.TokenStore` has a refresh token, then Core's own WS auth
      handshake.

  Both report the same lifecycle messages and take the same
  `send_frame/2` call, so everything below this paragraph is transport-
  agnostic.

  This module is the manager half of a monitor+backoff pair — mirroring
  `Vagus.Engine.Manager`'s house pattern for supervising an external
  resource without ever letting its restart intensity threaten the parent
  supervisor's budget. Both connection modules are started unlinked
  (`Fresh.start/4`, `SocketConnection.start/1`) and monitored
  (`Process.monitor/1`), never added as supervised children directly.

  **Neither leg ever reconnects on its own**: one connection attempt per
  process, and every loss — blip, close frame, transport error, connect
  failure — kills it. The `:DOWN` that follows is what re-enters this
  GenServer's capped-exponential backoff (5s -> 60s, doubling) and, with
  it, a fresh `Transport.current/0` resolution. A leg that healed itself
  would keep dialling the endpoint it was born with and starve the
  manager of the only moment it can change transports (see `Connection`'s
  moduledoc for the port-80 wedge that taught us this).

  ## Ready timeout

  Every connection is given `config :vagus, :event_pusher_ready_timeout`
  milliseconds (default 60_000) to report `:ready`. If it hasn't, the
  manager kills it and takes the ordinary `:DOWN` path above.
  Transport-agnostic belt-and-braces against any half-open wedge — a leg
  that connects but never finishes the auth handshake, a TCP socket to a
  port nothing answers on any more, a close frame the peer never echoes —
  none of which the monitor alone can see, because the process is alive
  and simply idle. The timer is re-armed on every `:connected` (which
  resets `ready`) and cancelled the moment `:ready` lands.

  Lazy on the TCP transport: no connection is attempted until
  `Vagus.Core.TokenStore` has a refresh token (subscribed at `init/1`,
  also checked directly in case one is already present — e.g. this
  process restarted after the token had already landed). On the socket
  transport there is nothing to be lazy about — the connection needs no
  credential — so it is dialed straight away. When neither is available
  (no socket yet, no token yet), a `:retry_connect` is armed on the same
  backoff, which is what picks the socket up once Core creates it even if
  a refresh token never arrives. `push/2` before a connection exists (or
  during any later disconnect) buffers into a bounded queue
  (`@max_queue_size`, drop-oldest) since a lost event only means a future
  poll will be a little late — never a hard requirement to redeliver.

  Id sequencing: Core's WS API requires strictly increasing `id`s within
  one connection, but no relationship between connections. This counter is
  therefore never reset — monotonic for the life of the manager, which
  satisfies Core on every connection AND means an id can never name two
  different requests over time. That is deliberate: with a per-connection
  reset, an already-delivered `{:command_timeout, id}` sitting in this
  process's mailbox (`Process.cancel_timer/1` cannot unsend one) could fail
  a *new* request that happened to reuse the id. Timers are additionally
  drained when `cancel_timer/1` reports the message already went out, so
  neither half of that race depends on the other.

  `command/2` adds a request/response path over the same socket for the
  commands that only exist on Core's WS API. Every in-flight request is
  still failed with `{:error, :disconnected}` and the pending map cleared
  whenever the connection goes away (a fresh `handle_connect/3`, and the
  connection process dying): the answer can only ever arrive on the
  connection the request was issued on. Commands never enter the offline
  queue: a buffered command whose caller has already given up is
  worthless, so they fail fast with `{:error, :not_connected}` instead.
  """

  use GenServer

  require Logger

  alias Vagus.Core.EventPusher.{Connection, SocketConnection}
  alias Vagus.Core.TokenStore
  alias Vagus.Core.Transport

  @max_queue_size 50
  @backoff_initial 5_000
  @backoff_max 60_000
  @command_timeout 5_000
  @ready_timeout 60_000

  # The caller's `GenServer.call/3` timeout must outlive the manager's own
  # per-request timer, or the call would exit with `:timeout` before the
  # manager can reply — leaving a pending entry the caller never sees.
  @call_grace_ms 1_000

  @doc """
  Starts the manager.

  Options:

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:ws_url` - overrides the computed Core WS URL (for tests).
    * `:token_store` - the `Vagus.Core.TokenStore` server, defaults to
      `Vagus.Core.TokenStore`.
    * `:client` - the `Vagus.Core.Client` server the WS connection uses
      for access tokens, defaults to `Vagus.Core.Client`.
    * `:ready_timeout` - milliseconds a connection may stay connected
      without reporting `:ready` before the manager kills it, defaults to
      `config :vagus, :event_pusher_ready_timeout` and then to
      `#{@ready_timeout}`.
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

  @doc """
  Sends `payload` as a WS command frame and blocks until Core answers with
  the matching `result` envelope.

  `payload` is the frame *minus* `"id"` (e.g. `%{"type" => "config/auth/list"}`)
  — the manager assigns the id, since ids must be sequenced per connection.

  Returns `{:ok, result}` (the envelope's `"result"` field) on
  `success: true`, `{:error, {:core_error, error}}` on `success: false`,
  and otherwise `{:error, reason}` where `reason` is one of:

    * `:not_connected` - no live, authenticated connection right now
      (returned immediately; commands are never buffered).
    * `:disconnected` - the connection went away while this request was
      in flight.
    * `:timeout` - Core did not answer within `:timeout`.
    * `:not_started` - the manager itself isn't running.

  Options:

    * `:server` - the manager, defaults to `__MODULE__`.
    * `:timeout` - milliseconds to wait for the result, defaults to
      `#{@command_timeout}`.
  """
  @spec command(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def command(payload, opts \\ []) when is_map(payload) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    call_command(server, payload, timeout)
  end

  defp call_command(server, payload, timeout) do
    GenServer.call(server, {:command, payload, timeout}, timeout + @call_grace_ms)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
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
      conn_mod: Connection,
      connection_pid: nil,
      monitor_ref: nil,
      retry_ref: nil,
      ready_ref: nil,
      ready_timeout_ms: ready_timeout(opts),
      ready: false,
      next_id: 1,
      pending: %{},
      queue: :queue.new(),
      queue_size: 0,
      backoff_ms: @backoff_initial
    }

    {:ok, connect(state)}
  end

  @impl GenServer
  def handle_call({:command, payload, timeout}, from, state) do
    if state.ready and state.connection_pid do
      id = state.next_id
      send_frame(state, Map.put(payload, "id", id))
      timer = Process.send_after(self(), {:command_timeout, id}, timeout)

      {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, {from, timer})}}
    else
      {:reply, {:error, :not_connected}, state}
    end
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
    # `next_id` deliberately survives — see the moduledoc's id-sequencing
    # section for why resetting it is what made stale timeouts dangerous.
    state = %{fail_pending(state) | ready: false, backoff_ms: @backoff_initial}

    {:noreply, arm_ready_timeout(state, pid)}
  end

  def handle_info({:event_pusher_connection, :ready, pid}, %{connection_pid: pid} = state) do
    {:noreply, flush(%{clear_ready_timeout(state) | ready: true})}
  end

  # Stale message from a connection pid that's no longer current - ignore.
  def handle_info({:event_pusher_connection, _event, _pid}, state), do: {:noreply, state}

  def handle_info({:event_pusher_result, id, result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        log_unmatched(result, id)
        {:noreply, state}

      {{from, timer}, pending} ->
        cancel_timeout(timer, id)
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    Logger.warning(
      "Vagus.Core.EventPusher: WS connection is down (#{inspect(reason)}), " <>
        "retrying in #{state.backoff_ms}ms"
    )

    state =
      %{fail_pending(state) | connection_pid: nil, monitor_ref: nil, ready: false}
      |> clear_ready_timeout()

    {:noreply, schedule_retry(state)}
  end

  # Connected but never ready: the process is alive, so the monitor will
  # never speak up. Kill it and let the `:DOWN` above run the ordinary
  # backoff + re-pick — no second retry path to keep in sync.
  def handle_info({:ready_timeout, pid}, %{connection_pid: pid, ready: false} = state) do
    Logger.warning(
      "Vagus.Core.EventPusher: connection #{inspect(pid)} never became ready within " <>
        "#{state.ready_timeout_ms}ms, killing it to force a fresh transport pick"
    )

    Process.exit(pid, :kill)

    {:noreply, %{state | ready_ref: nil}}
  end

  # Ready, or for a connection that is no longer current - a stale timer.
  def handle_info({:ready_timeout, _pid}, state), do: {:noreply, state}

  def handle_info(:retry_connect, %{connection_pid: nil} = state) do
    {:noreply, connect(state)}
  end

  # Already reconnected by some other path (or a stale timer) - no-op.
  def handle_info(:retry_connect, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  # Every id becomes ambiguous the moment the counter resets, so no pending
  # request may outlive the connection it was issued on.
  defp fail_pending(state) do
    Enum.each(state.pending, fn {id, {from, timer}} ->
      cancel_timeout(timer, id)
      GenServer.reply(from, {:error, :disconnected})
    end)

    %{state | pending: %{}}
  end

  # `Process.cancel_timer/1` returning `false` means the timer had already
  # fired and its `{:command_timeout, id}` is sitting in this process's
  # mailbox — unsending it is impossible, so drain it here instead. Ids are
  # monotonic (moduledoc), so a leaked one could only ever be a no-op
  # anyway; this keeps the mailbox honest rather than relying on that.
  defp cancel_timeout(timer, id) do
    if Process.cancel_timer(timer) == false do
      receive do
        {:command_timeout, ^id} -> :ok
      after
        0 -> :ok
      end
    end

    :ok
  end

  # Results nobody is waiting for are the norm on this socket: every
  # fire-and-forget `push/2` frame is acked. Only a nack is worth a word.
  defp log_unmatched({:ok, _result}, _id), do: :ok

  defp log_unmatched({:error, reason}, id) do
    Logger.warning(
      "Vagus.Core.EventPusher: unmatched result for id #{inspect(id)} " <>
        "nacked: #{inspect(reason)}"
    )
  end

  # Re-resolved on every attempt, never cached: this is what picks up the
  # socket Core creates when it starts (and drops back to TCP if a Core
  # recreate takes it away).
  defp connect(state) do
    case Transport.current() do
      {:socket, path} -> start_socket_connection(state, path)
      {:tcp, _base_url} -> connect_tcp(state)
    end
  end

  defp connect_tcp(state) do
    case TokenStore.get_refresh_token(state.token_store) do
      nil -> schedule_retry(state)
      _token -> start_connection(state)
    end
  end

  defp start_socket_connection(state, path) do
    case SocketConnection.start(%{manager: self(), socket: path}) do
      {:ok, pid} ->
        connected(state, pid, SocketConnection)

      {:error, reason} ->
        Logger.error(
          "Vagus.Core.EventPusher: failed to open the Core socket WS connection " <>
            "(#{inspect(reason)}), retrying in #{state.backoff_ms}ms"
        )

        schedule_retry(state)
    end
  end

  defp start_connection(state) do
    # No `backoff_initial`/`backoff_max` here even though `Fresh`
    # understands them (`vendor/fresh/lib/fresh/option.ex`): they only
    # govern `Fresh`'s *internal* reconnect, which `Connection` never
    # asks for. Reconnect timing is this module's `@backoff_initial` /
    # `next_backoff/1` alone, so that every wait is followed by a fresh
    # transport resolution.
    conn_state = %{manager: self(), client: state.client}

    case Fresh.start(state.ws_url, Connection, conn_state, []) do
      {:ok, pid} ->
        connected(state, pid, Connection)

      {:error, reason} ->
        Logger.error(
          "Vagus.Core.EventPusher: failed to start WS connection " <>
            "(#{inspect(reason)}), retrying in #{state.backoff_ms}ms"
        )

        schedule_retry(state)
    end
  end

  defp connected(state, pid, conn_mod) do
    state = %{
      clear_retry(state)
      | connection_pid: pid,
        conn_mod: conn_mod,
        monitor_ref: Process.monitor(pid),
        ready: false
    }

    arm_ready_timeout(state, pid)
  end

  # At most one armed ready timer, same discipline as `retry_ref`: a
  # connection can announce `:connected` more than once, and each one
  # re-opens the window.
  defp arm_ready_timeout(state, pid) do
    state = clear_ready_timeout(state)
    ref = Process.send_after(self(), {:ready_timeout, pid}, state.ready_timeout_ms)
    %{state | ready_ref: ref}
  end

  defp clear_ready_timeout(%{ready_ref: nil} = state), do: state

  defp clear_ready_timeout(%{ready_ref: ref} = state) do
    # `cancel_timer/1` returning `false` means the message already went
    # out and cannot be unsent — drain it rather than leave a
    # `{:ready_timeout, _}` that would only be discarded later by the
    # stale clause. Only ever one such message, since only one timer is
    # armed at a time.
    if Process.cancel_timer(ref) == false do
      receive do
        {:ready_timeout, _pid} -> :ok
      after
        0 -> :ok
      end
    end

    %{state | ready_ref: nil}
  end

  defp ready_timeout(opts) do
    Keyword.get_lazy(opts, :ready_timeout, fn ->
      Application.get_env(:vagus, :event_pusher_ready_timeout, @ready_timeout)
    end)
  end

  # At most one armed retry at a time: `:retry_connect` and a
  # `:refresh_token_available` notification can both want one, and each
  # failed attempt arms another, so without this the timers would multiply.
  defp schedule_retry(state) do
    state = clear_retry(state)
    ref = Process.send_after(self(), :retry_connect, state.backoff_ms)
    %{state | retry_ref: ref, backoff_ms: next_backoff(state.backoff_ms)}
  end

  defp clear_retry(%{retry_ref: nil} = state), do: state

  defp clear_retry(%{retry_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | retry_ref: nil}
  end

  defp next_backoff(current), do: min(current * 2, @backoff_max)

  defp send_now(event_data, state) do
    frame = %{"id" => state.next_id, "type" => "supervisor/event", "data" => event_data}
    send_frame(state, frame)
    %{state | next_id: state.next_id + 1}
  end

  defp send_frame(state, frame) do
    state.conn_mod.send_frame(state.connection_pid, {:text, Jason.encode!(frame)})
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
