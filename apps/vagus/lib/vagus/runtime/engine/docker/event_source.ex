defmodule Vagus.Runtime.Engine.Docker.EventSource do
  @moduledoc """
  Docker's `GET /events` as a `Vagus.Runtime.Events.Source`. The response
  never ends: the daemon writes one JSON event per line for as long as the
  connection lives, so this holds one Mint connection in active mode and
  reassembles lines across chunks.

  ## Filtering

  The request filters to `{"type":["container"]}` only. It cannot be
  narrower: Docker ANDs filter keys, so a `label=supervisor_managed` filter
  would also drop the label-less adopted Core container, whose events the
  Core watchdog needs. Some Engine-API versions ignore filters anyway, so
  non-container events are dropped here too, and Events applies the managed
  gate.

  ## Bounded memory

  A corrupt or adversarial stream could send an unbounded line with no
  `\\n`; on a 1GB device that would grow the buffer forever. The pending
  line is capped at 1MB and dropped (logged at `warning`) past it.
  """

  @behaviour Vagus.Runtime.Events.Source

  require Logger

  alias Vagus.Runtime.Docker
  alias Vagus.Runtime.Engine.Event

  @max_buffer_bytes 1_048_576

  @impl true
  def init(opts) do
    %{socket: opts[:socket] || Docker.socket_path(), conn: nil, request_ref: nil, buffer: ""}
  end

  @impl true
  def connect(src) do
    filters = URI.encode_www_form(Jason.encode!(%{"type" => ["container"]}))

    case Mint.HTTP.connect(:http, {:local, src.socket}, 0, hostname: "localhost", mode: :active) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, "GET", "/events?filters=" <> filters, [], "") do
          {:ok, conn, ref} ->
            {:ok, %{src | conn: conn, request_ref: ref, buffer: ""}}

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, {:request, reason}}
        end

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  @impl true
  def close(%{conn: nil} = src), do: %{src | request_ref: nil, buffer: ""}

  def close(src) do
    Mint.HTTP.close(src.conn)
    %{src | conn: nil, request_ref: nil, buffer: ""}
  end

  # Mint recognises its own socket messages; anything else is `:unknown`.
  @impl true
  def handle_info(_msg, %{conn: nil}), do: :unknown

  def handle_info(msg, src) do
    case Mint.HTTP.stream(src.conn, msg) do
      {:ok, conn, responses} ->
        responses |> fold(%{src | conn: conn}) |> result(nil)

      # Whatever arrived before the stream errored still counts.
      {:error, conn, reason, responses} ->
        responses |> fold(%{src | conn: conn}) |> result(reason)

      :unknown ->
        :unknown
    end
  end

  defp result({notices, src, nil}, nil), do: {:ok, notices, src}
  defp result({notices, src, closed}, nil), do: {:closed, closed, notices, src}
  defp result({notices, src, _closed}, reason), do: {:closed, reason, notices, src}

  defp fold(responses, src) do
    {notices, src, closed} =
      Enum.reduce(responses, {[], src, nil}, fn response, acc -> response(response, acc) end)

    {Enum.reverse(notices), src, closed}
  end

  defp response({:status, ref, status}, {notices, %{request_ref: ref} = src, closed}) do
    Logger.debug("Vagus.Runtime.Engine.Docker.EventSource: connected, status #{status}")
    {[if(status == 200, do: :ready, else: :answered) | notices], src, closed}
  end

  defp response({:headers, ref, _headers}, {notices, %{request_ref: ref} = src, closed}),
    do: {[:answered | notices], src, closed}

  defp response({:data, ref, data}, {notices, %{request_ref: ref} = src, closed}) do
    {lines, remainder} = split_lines(src.buffer <> data)
    events = for line <- lines, event = decode(line), do: event
    {Enum.reverse(events, notices), %{src | buffer: cap_buffer(remainder)}, closed}
  end

  defp response({:done, ref}, {notices, %{request_ref: ref} = src, closed}),
    do: {notices, src, closed || :stream_ended}

  defp response({:error, ref, reason}, {notices, %{request_ref: ref} = src, closed}),
    do: {notices, src, closed || reason}

  defp response(_other, acc), do: acc

  # The last element is the (possibly empty, possibly partial) remainder,
  # kept until a later chunk completes it.
  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)
    {complete, remainder}
  end

  defp cap_buffer(buffer) when byte_size(buffer) > @max_buffer_bytes do
    Logger.warning(
      "Vagus.Runtime.Engine.Docker.EventSource: pending line exceeded #{@max_buffer_bytes} bytes without a newline; dropping buffer"
    )

    ""
  end

  defp cap_buffer(buffer), do: buffer

  defp decode(""), do: nil

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{"Type" => "container"} = event} ->
        normalize(event)

      {:ok, _other_type} ->
        nil

      {:error, reason} ->
        Logger.debug(
          "Vagus.Runtime.Engine.Docker.EventSource: malformed event line skipped (#{inspect(reason)})"
        )

        nil
    end
  end

  @doc false
  @spec normalize(map()) :: Event.t()
  def normalize(event) do
    actor = Map.get(event, "Actor") || %{}
    attributes = Map.get(actor, "Attributes") || %{}
    {action, health} = action(Map.get(event, "Action"))

    %Event{
      action: action,
      health: health,
      name: Map.get(attributes, "name"),
      id: Map.get(actor, "ID"),
      exit_code: exit_code(Map.get(attributes, "exitCode")),
      time_ns: Map.get(event, "timeNano"),
      managed: Map.has_key?(attributes, "supervisor_managed")
    }
  end

  defp action("start"), do: {:start, nil}
  defp action("die"), do: {:die, nil}
  defp action("create"), do: {:create, nil}
  defp action("destroy"), do: {:destroy, nil}
  defp action("health_status: healthy"), do: {:health, :healthy}
  defp action("health_status: unhealthy"), do: {:health, :unhealthy}
  defp action("health_status: starting"), do: {:health, :starting}
  defp action(_other), do: {:other, nil}

  defp exit_code(code) when is_integer(code), do: code

  defp exit_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp exit_code(_other), do: nil
end
