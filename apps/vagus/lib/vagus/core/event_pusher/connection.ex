defmodule Vagus.Core.EventPusher.Connection do
  @moduledoc """
  The `Fresh` WebSocket client backing `Vagus.Core.EventPusher` on the TCP
  fallback (`config :vagus, :core_base_url` — host dev, and any device
  where Core's Supervisor socket isn't there). When the socket IS there,
  `Vagus.Core.EventPusher.SocketConnection` takes this module's place; both
  speak the same lifecycle/result messages back to the manager, and
  `send_frame/2` is the call the manager makes on either.

  Owns only the Core WS auth handshake (`docs/contract-2026.7.md` §4/§5):
  wait for `auth_required`, fetch an access token from `Vagus.Core.Client`,
  send `{"type": "auth", "access_token": token}`, wait for `auth_ok`. All
  queueing and id-sequencing live in the manager
  (`Vagus.Core.EventPusher`) — this module only reports connection
  lifecycle transitions back to it via plain messages
  (`{:event_pusher_connection, :connected | :ready, self()}`) so the
  manager can reset its per-connection id counter and flush its buffer at
  the right times. `result` envelopes are forwarded the same way
  (`{:event_pusher_result, id, {:ok, result} | {:error, {:core_error, e}}}`);
  correlating them with a waiting caller — or deciding a result is
  unmatched — is the manager's job, since only it holds the pending map.

  Ordinary network-level reconnection (dropped socket, upgrade failure,
  Core-initiated close) is handled entirely *inside* `Fresh` itself —
  `handle_disconnect/3` and `handle_error/2` both unconditionally return
  `:reconnect`, and the manager configures `backoff_initial`/`backoff_max`
  (5s/60s) when starting this connection. That keeps the same long-lived
  `gen_statem` process across many TCP-level reconnects, each one firing
  `handle_connect/3` again (which is exactly the "new connection" signal
  the manager resets its id counter on).

  Only an outright crash of this process (a bug, not a normal disconnect)
  needs `Vagus.Core.EventPusher`'s own monitor+backoff restart — which is
  why the manager starts this module with `Fresh.start/4` (unlinked), not
  `Fresh.start_link/4` or this module's `use Fresh`-generated
  `child_spec/1`: a link would propagate a crash here into the manager
  itself, and a supervised `child_spec` would spend `Vagus.Core.Supervisor`'s
  bounded restart budget on every WS hiccup instead of just this one
  connection's own restart accounting living in the manager.
  """

  use Fresh

  require Logger

  alias Vagus.Core.Client

  @doc """
  Sends one WS frame. Mirrors
  `Vagus.Core.EventPusher.SocketConnection.send_frame/2` so the manager can
  hold either client behind the same call.
  """
  @spec send_frame(pid(), {:text, binary()}) :: :ok
  def send_frame(pid, frame), do: Fresh.send(pid, frame)

  @impl Fresh
  def handle_connect(_status, _headers, %{manager: manager} = state) do
    send(manager, {:event_pusher_connection, :connected, self()})
    {:ok, state}
  end

  @impl Fresh
  def handle_in({:text, message}, state) do
    message
    |> Jason.decode()
    |> handle_decoded(state)
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl Fresh
  def handle_disconnect(_code, _reason, _state), do: :reconnect

  @impl Fresh
  def handle_error(_error, _state), do: :reconnect

  defp handle_decoded({:ok, %{"type" => "auth_required"}}, %{client: client} = state) do
    case Client.access_token(client) do
      {:ok, token} ->
        frame = Jason.encode!(%{"type" => "auth", "access_token" => token})
        {:reply, [{:text, frame}], state}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Core.EventPusher.Connection: no access token available " <>
            "(#{inspect(reason)}), closing to retry"
        )

        {:close, 1011, "no access token", state}
    end
  end

  defp handle_decoded({:ok, %{"type" => "auth_ok"}}, %{manager: manager} = state) do
    send(manager, {:event_pusher_connection, :ready, self()})
    {:ok, state}
  end

  defp handle_decoded({:ok, %{"type" => "auth_invalid"} = msg}, %{client: client} = state) do
    Logger.warning(
      "Vagus.Core.EventPusher.Connection: auth_invalid (#{inspect(msg)}), " <>
        "invalidating cached access token"
    )

    Client.invalidate(client)
    {:ok, state}
  end

  defp handle_decoded(
         {:ok, %{"type" => "result", "id" => id, "success" => true} = msg},
         %{manager: manager} = state
       )
       when is_integer(id) do
    send(manager, {:event_pusher_result, id, {:ok, Map.get(msg, "result")}})
    {:ok, state}
  end

  defp handle_decoded(
         {:ok, %{"type" => "result", "id" => id, "success" => false} = msg},
         %{manager: manager} = state
       )
       when is_integer(id) do
    send(manager, {:event_pusher_result, id, {:error, {:core_error, Map.get(msg, "error")}}})
    {:ok, state}
  end

  defp handle_decoded({:ok, other}, state) do
    Logger.debug("Vagus.Core.EventPusher.Connection: ignoring unknown frame #{inspect(other)}")
    {:ok, state}
  end

  defp handle_decoded({:error, reason}, state) do
    Logger.warning("Vagus.Core.EventPusher.Connection: undecodable frame (#{inspect(reason)})")
    {:ok, state}
  end
end
