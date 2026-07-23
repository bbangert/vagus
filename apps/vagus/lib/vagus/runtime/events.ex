defmodule Vagus.Runtime.Events do
  @moduledoc """
  Streaming docker-events client — GET `/events?filters=...` over the
  daemon's Unix socket, the container-event half of the watchdog
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B6.1, real Supervisor's
  `DockerMonitor._run()`). Unlike `Vagus.Runtime.Docker`'s one-shot
  request/response calls, this endpoint's HTTP response never ends: the
  daemon keeps the connection open and writes one newline-delimited JSON
  event object per line, forever. This module holds a single long-lived
  Mint connection in **active** mode inside a `GenServer` (house pattern —
  see `Vagus.DNS`, `Vagus.Core.ApiSocket`), reassembles the line-delimited
  JSON across TCP/chunk boundaries, and fans decoded events out to
  subscribers as `{:docker_event, map}`.

  ## Filtering — server-side + client-side

  The request asks the daemon to filter to `{"type":["container"]}` only —
  it can't be narrower, because docker ANDs filter keys (a
  `label=supervisor_managed` filter would also exclude the label-less
  adopted Core container, whose events the Core watchdog needs). The
  authoritative gate is client-side (the plan's self-check #1 — some older
  Engine-API versions silently ignore filters anyway): only
  `Type == "container"` events whose Actor attributes carry the
  `supervisor_managed` label key, whose container name starts with
  `addon_`, or whose name equals `Vagus.Core.Container.name()` (the
  adopted Core container carries no Vagus label until its first rebuild —
  name is its only stable identity) are ever sent to a subscriber. A
  daemon that ignores the server-side filter entirely still can't flood
  subscribers with unrelated host-container noise.

  ## Reconnect

  A dropped stream (the request's `:done`, a transport error/close, or a
  failed connect) is followed by a reconnect with exponential backoff — 1s,
  2s, 4s, ... capped at 30s — so a daemon restart or a momentary socket
  hiccup doesn't spin. The backoff resets to 1s as soon as a connection
  makes it far enough to receive an HTTP status/headers (i.e. the daemon
  really was there and responding); a connection that never gets that far
  keeps escalating. Each drop is logged once at `warning`; the retry ticks
  themselves log at `debug` so a prolonged outage doesn't spam the log at
  warning level once per attempt.

  ## Bounded memory

  Docker's line-delimited stream is normally tiny per line, but a corrupt
  or adversarial stream could send an unbounded line with no `\\n` — on a
  1GB device that would balloon the buffer forever. The pending-line buffer
  is capped at 1MB; a line that grows past the cap without a newline is
  dropped (logged at `warning`) rather than accumulated further.

  Gated at the application-supervisor level by `config :vagus, :events_enabled`
  (default `true`, `false` in `config/test.exs`) — mirrors `Vagus.DNS`'s
  `:dns_enabled` gating in `Vagus.Application`. This module itself always
  runs (and always tries to connect) once started; it doesn't gate itself.
  """

  use GenServer

  require Logger

  alias Vagus.Runtime.Docker

  @initial_backoff_ms 1_000
  @max_backoff_ms 30_000
  # Caps the pending (no-newline-yet) line buffer so a corrupt/adversarial
  # stream can't exhaust memory on a 1GB device.
  @max_buffer_bytes 1_048_576

  @typedoc "A decoded, client-filtered docker container event."
  @type event :: %{
          action: String.t() | nil,
          name: String.t() | nil,
          id: String.t() | nil,
          exit_code: integer() | nil,
          time_nano: integer() | nil,
          attributes: map()
        }

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the calling process to `{:docker_event, event}` messages. The
  server monitors the caller and drops it from the subscriber list on
  `:DOWN` — a crashed/dead subscriber is pruned automatically, never leaked.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Unsubscribes the calling process."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    state = %{
      socket: Keyword.get(opts, :socket, Docker.socket_path()),
      conn: nil,
      request_ref: nil,
      buffer: "",
      subscribers: %{},
      backoff_ms: @initial_backoff_ms
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, do_connect(state)}

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, %{subscribers: subs} = state) do
    subs =
      if Map.has_key?(subs, pid) do
        subs
      else
        Map.put(subs, pid, Process.monitor(pid))
      end

    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, %{subscribers: subs} = state) do
    case Map.pop(subs, pid) do
      {nil, ^subs} ->
        {:reply, :ok, state}

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: rest}}
    end
  end

  @impl GenServer
  # The retry timer: the debug-level counterpart to the warning logged once
  # when the drop that scheduled it happened (see schedule_reconnect/2).
  def handle_info(:connect, state) do
    Logger.debug("Vagus.Runtime.Events: attempting to (re)connect to #{state.socket}")
    {:noreply, do_connect(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{subscribers: subs} = state) do
    case Map.fetch(subs, pid) do
      {:ok, ^ref} -> {:noreply, %{state | subscribers: Map.delete(subs, pid)}}
      _ -> {:noreply, state}
    end
  end

  # Mint active-mode messages (raw socket messages tagged for the transport)
  # are routed through Mint.HTTP.stream/2, which either recognizes them as
  # belonging to `state.conn` or returns `:unknown` for anything else
  # (another process's messages, stray timer sends, etc).
  def handle_info(msg, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.HTTP.stream(conn, msg) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(responses, %{state | conn: conn})}

      {:error, conn, reason, responses} ->
        # Process whatever data arrived before the stream errored, then treat
        # the error itself as a drop — one reconnect scheduled, not two, even
        # though `responses` might itself contain no :done/:error entry.
        state = handle_responses(responses, %{state | conn: conn})
        Mint.HTTP.close(conn)
        {:noreply, schedule_reconnect(reason, %{state | conn: nil, request_ref: nil})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Connect

  # Type-only server filter: docker ANDs filter keys, so a label filter here
  # would drop the (label-less) adopted Core container's events entirely —
  # see moduledoc "Filtering". The client-side check in dispatch/2 is the
  # authoritative gate.
  defp do_connect(state) do
    filters = URI.encode_www_form(Jason.encode!(%{"type" => ["container"]}))

    path = "/events?filters=" <> filters

    case Mint.HTTP.connect(:http, {:local, state.socket}, 0, hostname: "localhost", mode: :active) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, "GET", path, [], "") do
          {:ok, conn, ref} ->
            %{state | conn: conn, request_ref: ref, buffer: ""}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            schedule_reconnect({:request, reason}, %{state | conn: nil, request_ref: nil})
        end

      {:error, reason} ->
        schedule_reconnect({:connect, reason}, state)
    end
  end

  # Logs the drop exactly once (warning) and arms the retry timer; the retry
  # tick itself (handle_info(:connect, ...)) logs at debug. Backoff for the
  # *next* schedule_reconnect/2 call is always doubled (capped) here — but a
  # connection that got at least a status/headers response resets
  # `backoff_ms` back to the floor first (see handle_response/2), so a stream
  # that dies after actually talking to the daemon starts its next retry at
  # 1s rather than continuing to escalate.
  defp schedule_reconnect(reason, state) do
    delay = state.backoff_ms

    Logger.warning(
      "Vagus.Runtime.Events: docker-events stream dropped (#{inspect(reason)}); reconnecting in #{delay}ms"
    )

    Process.send_after(self(), :connect, delay)

    %{
      state
      | conn: nil,
        request_ref: nil,
        buffer: "",
        backoff_ms: min(delay * 2, @max_backoff_ms)
    }
  end

  ## Response handling

  defp handle_responses(responses, state), do: Enum.reduce(responses, state, &handle_response/2)

  defp handle_response({:status, ref, status}, state) do
    if ref == state.request_ref do
      Logger.debug("Vagus.Runtime.Events: connected, status #{status}")
      %{state | backoff_ms: @initial_backoff_ms}
    else
      state
    end
  end

  defp handle_response({:headers, ref, _headers}, state) do
    if ref == state.request_ref, do: %{state | backoff_ms: @initial_backoff_ms}, else: state
  end

  defp handle_response({:data, ref, data}, state) do
    if ref == state.request_ref, do: process_data(data, state), else: state
  end

  defp handle_response({:done, ref}, state) do
    if ref == state.request_ref do
      if state.conn, do: Mint.HTTP.close(state.conn)
      schedule_reconnect(:stream_ended, %{state | conn: nil, request_ref: nil})
    else
      state
    end
  end

  defp handle_response({:error, ref, reason}, state) do
    if ref == state.request_ref do
      if state.conn, do: Mint.HTTP.close(state.conn)
      schedule_reconnect(reason, %{state | conn: nil, request_ref: nil})
    else
      state
    end
  end

  defp handle_response(_other, state), do: state

  ## Line buffering + decoding

  defp process_data(data, state) do
    {lines, remainder} = split_lines(state.buffer <> data)
    Enum.each(lines, &handle_line(&1, state))
    %{state | buffer: cap_buffer(remainder)}
  end

  # Docker emits one JSON object per `\n`-terminated line; the last element
  # of the split is always the (possibly empty, possibly partial) remainder
  # — kept in the buffer until a future chunk completes it.
  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)
    {complete, remainder}
  end

  defp cap_buffer(buffer) do
    if byte_size(buffer) > @max_buffer_bytes do
      Logger.warning(
        "Vagus.Runtime.Events: pending line exceeded #{@max_buffer_bytes} bytes without a newline; dropping buffer"
      )

      ""
    else
      buffer
    end
  end

  defp handle_line("", _state), do: :ok

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, event} ->
        dispatch(event, state)

      {:error, reason} ->
        Logger.debug("Vagus.Runtime.Events: malformed event line skipped (#{inspect(reason)})")
    end
  end

  defp dispatch(event, state) do
    actor = Map.get(event, "Actor") || %{}
    attributes = Map.get(actor, "Attributes") || %{}
    name = Map.get(attributes, "name")

    # Core-name pass-through: the adopted Core container has no Vagus label
    # (and won't until a rebuild), so its fixed name is its identity here.
    # Container.name/0 is an Application.get_env read — cheap per event.
    managed? =
      Map.has_key?(attributes, "supervisor_managed") or
        (is_binary(name) and
           (String.starts_with?(name, "addon_") or name == Vagus.Core.Container.name()))

    if Map.get(event, "Type") == "container" and managed? do
      payload = %{
        action: Map.get(event, "Action"),
        name: name,
        id: Map.get(actor, "ID"),
        exit_code: parse_exit_code(Map.get(attributes, "exitCode")),
        time_nano: Map.get(event, "timeNano"),
        attributes: attributes
      }

      Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, {:docker_event, payload}) end)
    end
  end

  defp parse_exit_code(nil), do: nil
  defp parse_exit_code(code) when is_integer(code), do: code

  defp parse_exit_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp parse_exit_code(_other), do: nil
end
