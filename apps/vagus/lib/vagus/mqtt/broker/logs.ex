defmodule Vagus.Mqtt.Broker.Logs do
  @moduledoc """
  A bounded, in-memory log buffer for the native MQTT broker (M5, MQ-P3-T2).

  A native "virtual add-on" has no container, so `GET /addons/<slug>/logs` can't
  read `Docker.container_logs`. This GenServer synthesizes an equivalent: it
  attaches a `:telemetry` handler to mqttx's server events (connect / disconnect
  / subscribe / publish) and keeps the most recent `@max` formatted lines, which
  the router's native logs branch serves as `text/plain`, one entry per line —
  the same shape `Vagus.Runtime.Logs.format/2` produces for a container.

  Started as a child of the `Vagus.Mqtt.Broker` subtree (named `<broker>.Logs`),
  so it lives and dies with the broker. The telemetry callback runs in the
  emitting connection process and only `cast`s here, never blocking it.

  NOTE: mqttx's server telemetry events are not tagged with the listener, so with
  more than one native broker every buffer would see every broker's events. There
  is exactly one native broker today (`core_mqtt`); revisit if that changes.
  """

  use GenServer

  @max 200

  @events [
    [:mqttx, :server, :client_connect, :start],
    [:mqttx, :server, :client_disconnect],
    [:mqttx, :server, :subscribe],
    [:mqttx, :server, :publish]
  ]

  @doc "Starts the buffer. `:name` (default `#{inspect(__MODULE__)}`) is the process + handler key."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The most recent `n` log lines, oldest first."
  @spec tail(GenServer.server(), pos_integer()) :: [String.t()]
  def tail(server, n \\ 100), do: GenServer.call(server, {:tail, n})

  @doc """
  Subscribes the calling process to `{:broker_log, line}` messages, one per
  appended log line (the live half of `/logs/follow`; use `tail/2` for the
  backfill). The server monitors the caller and prunes it on `:DOWN`, so a
  dead subscriber is never leaked — same seam as `Vagus.Runtime.Events`.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc "Unsubscribes the calling process."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  # Telemetry callback (remote capture — runs in the connection process).
  @doc false
  def handle_event(event, measurements, metadata, server) do
    case format(event, measurements, metadata) do
      nil -> :ok
      line -> GenServer.cast(server, {:append, line})
    end
  end

  @impl GenServer
  def init(opts) do
    handler_id = {__MODULE__, Keyword.get(opts, :name, __MODULE__)}
    # Detach first so a restart (where terminate/2 may not have run) can re-attach.
    _ = :telemetry.detach(handler_id)
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, self())
    {:ok, %{lines: [], handler_id: handler_id, subscribers: %{}}}
  end

  @impl GenServer
  # DELIBERATE asymmetry with the docker follow path (which ack-gates its
  # reads): this fan-out has no backpressure, so a slow /logs/follow client
  # blocked in chunk/2 queues {:broker_log, _} in the request process's
  # mailbox. Bounded in practice by this buffer's own event rate (broker
  # telemetry, a few lines/sec at worst) and by dead-client teardown
  # (chunk error / idle window) — an ack protocol here would buy nothing
  # measurable for the complexity.
  def handle_cast({:append, line}, state) do
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, {:broker_log, line}) end)
    {:noreply, %{state | lines: Enum.take([line | state.lines], @max)}}
  end

  @impl GenServer
  def handle_call({:tail, n}, _from, state) do
    {:reply, state.lines |> Enum.take(n) |> Enum.reverse(), state}
  end

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
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{subscribers: subs} = state) do
    case Map.fetch(subs, pid) do
      {:ok, ^ref} -> {:noreply, %{state | subscribers: Map.delete(subs, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = :telemetry.detach(state.handler_id)
    :ok
  end

  # -- line formatting -------------------------------------------------------

  defp format([:mqttx, :server, :client_connect, :start], _measure, meta) do
    line("CONNECT #{cid(meta)} (MQTT v#{Map.get(meta, :protocol_version, "?")})")
  end

  defp format([:mqttx, :server, :client_disconnect], _measure, meta) do
    line("DISCONNECT #{cid(meta)} (#{inspect(Map.get(meta, :reason, :unknown))})")
  end

  defp format([:mqttx, :server, :subscribe], _measure, meta) do
    line("SUBSCRIBE #{cid(meta)} #{topics(meta)}")
  end

  defp format([:mqttx, :server, :publish], measure, meta) do
    line(
      "PUBLISH #{cid(meta)} #{topic(meta)} " <>
        "(#{Map.get(measure, :payload_size, 0)} bytes, qos #{Map.get(meta, :qos, 0)})"
    )
  end

  defp format(_event, _measure, _meta), do: nil

  defp line(body), do: "[#{Time.utc_now() |> Time.truncate(:second) |> Time.to_string()}] #{body}"

  defp cid(meta), do: meta |> Map.get(:client_id) |> to_string()
  defp topic(meta), do: meta |> Map.get(:topic) |> to_topic()
  defp topics(meta), do: meta |> Map.get(:topics, []) |> Enum.map_join(",", &to_topic/1)

  # mqttx normalized topics are segment lists; a plain string passes through.
  defp to_topic(t) when is_list(t), do: Enum.join(t, "/")
  defp to_topic(t) when is_binary(t), do: t
  defp to_topic(other), do: inspect(other)
end
