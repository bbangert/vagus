defmodule Vagus.Mqtt.Broker.Logs do
  @moduledoc """
  The native MQTT broker's log buffer: a `Vagus.Addon.Backend.Native.Logs`
  fed by mqttx's server telemetry (connect / disconnect / subscribe /
  publish), one line per event.

  NOTE: mqttx's server telemetry events are not tagged with the listener, so with
  more than one native broker every buffer would see every broker's events. There
  is exactly one native broker today (`core_mqtt`); revisit if that changes.
  """

  alias Vagus.Addon.Backend.Native

  @events [
    [:mqttx, :server, :client_connect, :start],
    [:mqttx, :server, :client_disconnect],
    [:mqttx, :server, :subscribe],
    [:mqttx, :server, :publish]
  ]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Supervisor.child_spec(
      {Native.Logs, [events: @events, format: &__MODULE__.format/3] ++ opts},
      id: __MODULE__
    )
  end

  @doc false
  @spec format(:telemetry.event_name(), map(), map()) :: String.t() | nil
  def format([:mqttx, :server, :client_connect, :start], _measure, meta),
    do: "CONNECT #{cid(meta)} (MQTT v#{Map.get(meta, :protocol_version, "?")})"

  def format([:mqttx, :server, :client_disconnect], _measure, meta),
    do: "DISCONNECT #{cid(meta)} (#{inspect(Map.get(meta, :reason, :unknown))})"

  def format([:mqttx, :server, :subscribe], _measure, meta),
    do: "SUBSCRIBE #{cid(meta)} #{topics(meta)}"

  def format([:mqttx, :server, :publish], measure, meta) do
    "PUBLISH #{cid(meta)} #{topic(meta)} " <>
      "(#{Map.get(measure, :payload_size, 0)} bytes, qos #{Map.get(meta, :qos, 0)})"
  end

  def format(_event, _measure, _meta), do: nil

  defp cid(meta), do: meta |> Map.get(:client_id) |> to_string()
  defp topic(meta), do: meta |> Map.get(:topic) |> to_topic()
  defp topics(meta), do: meta |> Map.get(:topics, []) |> Enum.map_join(",", &to_topic/1)

  # mqttx normalized topics are segment lists; a plain string passes through.
  defp to_topic(t) when is_list(t), do: Enum.join(t, "/")
  defp to_topic(t) when is_binary(t), do: t
  defp to_topic(other), do: inspect(other)
end
