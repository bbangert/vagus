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
  """

  use GenServer

  require Logger

  alias Vagus.Core.Transport

  @ws_path "/api/websocket"

  @typedoc "State for the Core-side Mint.WebSocket connection over the unix socket."
  @type state :: %{
          manager: pid(),
          conn: Mint.HTTP.t(),
          ref: reference(),
          status: Mint.Types.status() | nil,
          resp_headers: Mint.Types.headers(),
          websocket: Mint.WebSocket.t() | nil,
          upgraded?: boolean()
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
    connect_opts = [mode: :active, protocols: [:http1]] ++ Transport.connect_opts(transport)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, address, port, connect_opts),
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
         upgraded?: false
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

  defp process_response({:done, ref}, %{ref: ref, upgraded?: false} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        # Implicitly authenticated: both signals at once (see moduledoc).
        send(state.manager, {:event_pusher_connection, :connected, self()})
        send(state.manager, {:event_pusher_connection, :ready, self()})
        {:continue, %{state | conn: conn, websocket: websocket, upgraded?: true}}

      {:error, conn, reason} ->
        Logger.warning(
          "Vagus.Core.EventPusher.SocketConnection: WS upgrade rejected (#{inspect(reason)})"
        )

        {:stop, %{state | conn: conn}}
    end
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
