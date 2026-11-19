defmodule Vagus.Mqtt.Broker.Handler do
  @moduledoc """
  The `MqttX.Server` callback module for the native MQTT broker.

  mqttx drives the wire protocol, the listener's sessions and their
  subscription index, retained messages, Subscription Identifiers and shared
  subscriptions. This module decides **auth** (`handle_connect/3`, see
  `Vagus.Mqtt.Broker.Auth`) and hands every accepted PUBLISH to
  `MqttX.Server.deliver/3`, which fans it out to every matching session:
  straight to a connected one, through the session's queue for one that
  outlives its connection or is away.

  Every CONNECT is authenticated before mqttx resumes a session, so a login
  that no longer authenticates cannot reach the subscriptions or queued
  messages of its old session. There are no per-topic rights to re-check.
  """

  use MqttX.Server

  alias Vagus.Mqtt.Broker.Auth

  # MQTT 5.0 "Not authorized"; mqttx sends a 3.1.1 client return code 5, the
  # `mosquitto_pub` exit-5 case. A v5 CONNACK cannot carry 0x05 (it would go
  # out as 0x80 Unspecified error).
  @connack_not_authorized 0x87

  @impl MqttX.Server
  def init(opts) do
    %{auth: Auth.config(Keyword.get(opts, :auth, [])), client_id: nil}
  end

  @impl MqttX.Server
  def handle_connect(client_id, %{username: username, password: password}, state) do
    # Auth is delegated 100% to this callback (mqttx ships no credential store):
    # service creds → HA user (`Vagus.Auth`) → options logins, see `Broker.Auth`.
    case Auth.authenticate(username, password, state.auth) do
      :ok -> {:ok, %{state | client_id: client_id}}
      :error -> {:error, @connack_not_authorized, state}
    end
  end

  @impl MqttX.Server
  def handle_subscribe(topics, state) do
    {:ok, Enum.map(topics, & &1.qos), state}
  end

  # `publisher` is what no-local subscriptions are compared against. The
  # publisher's properties travel with the message; mqttx drops the Topic
  # Alias and Subscription Identifier, which belong to one connection.
  @impl MqttX.Server
  def handle_publish(topic, payload, opts, state) do
    {:ok, _sessions} =
      MqttX.Server.deliver(topic, payload, %{
        qos: opts.qos,
        retain: opts.retain,
        properties: Map.get(opts, :properties) || %{},
        publisher: state.client_id
      })

    {:ok, state}
  end

  @impl MqttX.Server
  def handle_disconnect(_reason, _state), do: :ok

  @impl MqttX.Server
  def handle_session_expired(client_id, _state) do
    :telemetry.execute([:vagus, :mqtt, :session_expired], %{}, %{client_id: client_id})
  end
end
