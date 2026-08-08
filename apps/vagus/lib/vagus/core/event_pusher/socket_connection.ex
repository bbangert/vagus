defmodule Vagus.Core.EventPusher.SocketConnection do
  @moduledoc """
  The Supervisor↔Core **unix socket** WebSocket client backing
  `Vagus.Core.EventPusher` — the socket-transport sibling of
  `Vagus.Core.EventPusher.Connection`, which stays the TCP-fallback client.

  Two clients rather than one because the vendored `fresh`
  (`Vagus.Core.EventPusher.Connection`'s engine) dials from a parsed URL
  (`Mint.HTTP.connect(scheme, uri.host, uri.port, ...)`) and a unix socket
  has no host/port to parse — the plan's Phase A explicitly rules out
  patching `fresh` for this. So the socket leg is raw `Mint.WebSocket`,
  built the same way `Vagus.API.CoreProxy.WSBridge.Upstream` is, and the
  TCP leg keeps working exactly as it does today.

  ## No handshake: authenticated from the first frame (A3)

  Core treats a socket peer as the Supervisor user, so it sends no
  `auth_required` and wants no `auth` message — there is no access token in
  this module at all, and `Vagus.Core.Client` is never consulted. The
  manager's two lifecycle signals therefore both fire the moment the WS
  upgrade completes: `{:event_pusher_connection, :connected, self()}`
  immediately followed by `{:event_pusher_connection, :ready, self()}`, at
  which point the manager flushes its offline queue and `command/2` works.
  A stray handshake frame (a future Core deciding to send one anyway) is
  ignored rather than treated as a protocol error.

  ## Lifecycle

  Started **unlinked** (`GenServer.start/3`) and monitored by the manager,
  exactly like `Fresh.start/4` on the TCP leg and for the same reason: a
  connection failure must spend the manager's own backoff budget, never
  `Vagus.Core.Supervisor`'s restart budget. Unlike `fresh`, this process
  does not reconnect internally — any terminal event (Core's close frame, a
  transport error, an undecodable stream) stops it `:normal`, the manager
  sees `:DOWN` and reconnects on its existing capped-exponential backoff,
  re-resolving the transport as it does so.

  ## `send_timeout` on the Mint socket (issue #37)

  `Mint.HTTP.connect/4` carries `transport_opts: [send_timeout: ...,
  send_timeout_close: true]` — the same option, from the same
  `config :vagus, :core_ws_send_timeout` (default 5s), that
  `Vagus.API.CoreProxy.WSBridge.Upstream` sets. Without it, a Core whose
  socket receive buffer has filled (wedged or restarting mid-write) blocks
  `send_frame_now/2`'s `:gen_tcp.send/2` **forever**: this GenServer would
  never exit, so the manager's monitor never fires, `ready: true` would
  persist, `push/2` casts would pile into a mailbox nobody drains and
  `command/2` would answer `{:error, :timeout}` without ever triggering a
  reconnect. With it, a stalled send surfaces as
  `stream_request_body/3`'s ordinary `{:error, conn, reason}`, which stops
  this process `:normal` and hands the manager its usual reconnect.
  """

  use GenServer

  require Logger

  alias Vagus.Core.Transport

  @ws_path "/api/websocket"
  @default_send_timeout_ms 5_000

  @typedoc "State for the Core-side Mint.WebSocket connection over the unix socket."
  @type state :: %{
          manager: pid(),
          conn: Mint.HTTP.t(),
          ref: reference(),
          status: Mint.Types.status() | nil,
          resp_headers: Mint.Types.headers(),
          websocket: Mint.WebSocket.t() | nil,
          upgraded?: boolean(),
          # Raw bytes from `{:data, ^ref, _}` responses seen while
          # `upgraded?: false` — see `process_response/2`'s `:done` clause.
          pre_upgrade_data: binary()
        }

  @doc """
  Starts an unlinked connection over `args.socket`, reporting lifecycle and
  `result` envelopes to `args.manager`.
  """
  @spec start(%{required(:manager) => pid(), required(:socket) => String.t()}) ::
          GenServer.on_start()
  def start(args), do: GenServer.start(__MODULE__, args)

  @doc """
  Sends one WS frame. Mirrors `Vagus.Core.EventPusher.Connection.send_frame/2`
  so the manager can hold either client behind the same call.
  """
  @spec send_frame(pid(), {:text, binary()}) :: :ok
  def send_frame(pid, frame), do: GenServer.cast(pid, {:frame, frame})

  @impl GenServer
  def init(%{manager: manager, socket: socket}) do
    transport = {:socket, socket}
    {scheme, address, port} = Transport.connect_args(transport)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, address, port, mint_connect_opts(transport)),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(Transport.ws_scheme(transport), conn, @ws_path, []) do
      {:ok,
       %{
         manager: manager,
         conn: conn,
         ref: ref,
         status: nil,
         resp_headers: [],
         websocket: nil,
         upgraded?: false,
         pre_upgrade_data: <<>>
       }}
    else
      {:error, reason} ->
        {:stop, {:connect_failed, reason}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:stop, {:upgrade_request_failed, reason}}
    end
  end

  @impl GenServer
  def handle_cast({:frame, frame}, %{upgraded?: true} = state) do
    case send_frame_now(frame, state) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:stop, :normal, state}
    end
  end

  # The manager only sends once it has been told `:ready`, which happens
  # after the upgrade — so this is unreachable in practice and dropping the
  # frame (rather than buffering it) keeps the "events are best-effort"
  # contract the manager's own bounded queue already sets.
  def handle_cast({:frame, _frame}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(msg, state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        process_responses(responses, %{state | conn: conn})

      {:error, conn, _reason, responses} ->
        case process_responses(responses, %{state | conn: conn}) do
          {:noreply, state} -> {:stop, :normal, state}
          stop -> stop
        end

      :unknown ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{conn: conn}) do
    Mint.HTTP.close(conn)
    :ok
  end

  ## Internals

  @doc false
  @spec mint_connect_opts(Transport.t()) :: keyword()
  def mint_connect_opts(transport) do
    [
      mode: :active,
      protocols: [:http1],
      # See the moduledoc's "`send_timeout` on the Mint socket" section.
      transport_opts: [send_timeout: send_timeout_ms(), send_timeout_close: true]
    ] ++ Transport.connect_opts(transport)
  end

  defp send_timeout_ms do
    Application.get_env(:vagus, :core_ws_send_timeout, @default_send_timeout_ms)
  end

  # Reaches into Mint.HTTP1's own struct on purpose (see `process_response/2`'s
  # `:done` clause) — guarded so an upstream struct change degrades to a no-op
  # (treated as "no leftover", `conn` returned untouched) rather than
  # crashing. Clears the buffer in the same step it's read: on a
  # `{:tcp_closed, _}` message `Mint.WebSocket.stream/2` falls through to
  # `Mint.HTTP.stream/2`, which WOULD consult a stale buffer and could
  # surface a bogus HTTP parse error in place of a clean close.
  defp take_mint_http1_leftover(conn) do
    case conn do
      %{buffer: bin} when is_binary(bin) and bin != <<>> -> {bin, %{conn | buffer: <<>>}}
      _ -> {<<>>, conn}
    end
  end

  defp process_responses([], state), do: {:noreply, state}

  defp process_responses([response | rest], state) do
    case process_response(response, state) do
      {:continue, state} -> process_responses(rest, state)
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  defp process_response({:status, ref, status}, %{ref: ref} = state) do
    {:continue, %{state | status: status}}
  end

  defp process_response({:headers, ref, headers}, %{ref: ref} = state) do
    {:continue, %{state | resp_headers: headers}}
  end

  # mint_web_socket's post-`new/4` stream takes over the raw transport and
  # never revisits Mint.HTTP1's own parse buffer — Core's first frame,
  # bundled with (or immediately behind) the 101 response, would be stranded
  # there forever unless drained here, once, right after `new/4`. It can also
  # reach us as an ordinary `{:data, ^ref, _}` response *before* this `:done`
  # in the very same batch (Mint.HTTP1 treats a 101's body as "whatever's
  # left in this read", RFC7230-legal since a 101 has no framed body) —
  # `pre_upgrade_data` (accumulated below, `upgraded?: false`) catches that
  # case, since `conn`'s own buffer is already empty by the time the bytes
  # were parsed out as that `:data` response.
  defp process_response({:done, ref}, %{ref: ref, upgraded?: false} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        {buffered, conn} = take_mint_http1_leftover(conn)
        leftover = state.pre_upgrade_data <> buffered
        upgraded = %{state | conn: conn, websocket: websocket, upgraded?: true}

        decoded =
          case leftover do
            <<>> -> {:continue, upgraded}
            bin -> process_response({:data, ref, bin}, upgraded)
          end

        # Decode the leftover BEFORE announcing readiness — implicit auth
        # means both signals fire at once (see moduledoc), but only once
        # decoding confirms the connection is actually usable; a Close or
        # malformed leftover must stop it without ever announcing
        # :connected/:ready to the manager.
        case decoded do
          {:continue, state} ->
            send(state.manager, {:event_pusher_connection, :connected, self()})
            send(state.manager, {:event_pusher_connection, :ready, self()})
            {:continue, state}

          {:stop, state} ->
            {:stop, state}
        end

      {:error, conn, reason} ->
        Logger.warning(
          "Vagus.Core.EventPusher.SocketConnection: WS upgrade rejected (#{inspect(reason)})"
        )

        {:stop, %{state | conn: conn}}
    end
  end

  # Pre-upgrade: see the `:done` clause's comment on `pre_upgrade_data` —
  # nothing to decode with yet (no `websocket` codec state exists until
  # `new/4` runs), so just accumulate in arrival order.
  defp process_response({:data, ref, data}, %{ref: ref, upgraded?: false} = state) do
    {:continue, %{state | pre_upgrade_data: state.pre_upgrade_data <> data}}
  end

  defp process_response({:data, ref, data}, %{ref: ref, upgraded?: true} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> handle_frames(frames, %{state | websocket: websocket})
      {:error, websocket, _reason} -> {:stop, %{state | websocket: websocket}}
    end
  end

  defp process_response(_other, state), do: {:continue, state}

  defp handle_frames([], state), do: {:continue, state}

  defp handle_frames([{:text, data} | rest], state) do
    data
    |> Jason.decode()
    |> report(state)

    handle_frames(rest, state)
  end

  defp handle_frames([{:ping, data} | rest], state) do
    case send_frame_now({:pong, data}, state) do
      {:ok, state} -> handle_frames(rest, state)
      {:error, state} -> {:stop, state}
    end
  end

  defp handle_frames([{:close, _code, _reason} | _rest], state), do: {:stop, state}

  defp handle_frames([_other | rest], state), do: handle_frames(rest, state)

  # Same envelope handling as `Vagus.Core.EventPusher.Connection` — the
  # manager holds the pending map, so this only forwards.
  defp report({:ok, %{"type" => "result", "id" => id, "success" => true} = msg}, state)
       when is_integer(id) do
    send(state.manager, {:event_pusher_result, id, {:ok, Map.get(msg, "result")}})
  end

  defp report({:ok, %{"type" => "result", "id" => id, "success" => false} = msg}, state)
       when is_integer(id) do
    send(
      state.manager,
      {:event_pusher_result, id, {:error, {:core_error, Map.get(msg, "error")}}}
    )
  end

  defp report({:ok, _other}, _state), do: :ok

  defp report({:error, reason}, _state) do
    Logger.warning(
      "Vagus.Core.EventPusher.SocketConnection: undecodable frame (#{inspect(reason)})"
    )
  end

  defp send_frame_now(frame, state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, encoded} ->
        state = %{state | websocket: websocket}

        case Mint.WebSocket.stream_request_body(state.conn, state.ref, encoded) do
          {:ok, conn} -> {:ok, %{state | conn: conn}}
          {:error, conn, _reason} -> {:error, %{state | conn: conn}}
        end

      {:error, websocket, _reason} ->
        {:error, %{state | websocket: websocket}}
    end
  end
end
