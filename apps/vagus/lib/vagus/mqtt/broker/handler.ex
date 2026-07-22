defmodule Vagus.Mqtt.Broker.Handler do
  @moduledoc """
  The `MqttX.Server` callback module for the native MQTT broker (M5,
  `.claude/plans/vagus-mqtt/`).

  mqttx drives the wire protocol (CONNECT/CONNACK, QoS ack state machines,
  keepalive, LWT, retained storage/delivery, version negotiation) and calls back
  here for the application decisions it deliberately leaves to us. The two that
  matter are **auth** (`handle_connect/3` — accepts all connects for now; real
  validation lands in MQ-P1) and **routing**, which mqttx does not do at all:
  we register subscriptions in `Vagus.Mqtt.Broker.Subscriptions` and fan each
  PUBLISH out to matching subscribers ourselves.

  Every callback runs *inside* the per-connection ThousandIsland process, so
  `self()` here is the connection's pid: we register it as the subscription's
  client ref, and deliver to it by sending `{:mqtt_deliver, ...}`, which returns
  as a `{:publish, ...}` tuple from `handle_info/2` (mqttx's downlink contract,
  `deps/mqttx` README §"Publishing from a server callback").
  """

  use MqttX.Server

  alias Vagus.Mqtt.Broker.{Auth, Subscriptions}

  # CONNACK "not authorised" (MQTT 3.1.1 §3.2.2.3) — the codec writes this byte
  # verbatim, so it must be the v3.1.1 return code, matching `mosquitto_pub` exit-5.
  @connack_not_authorized 0x05

  @impl MqttX.Server
  def init(opts) do
    %{
      subscriptions: Keyword.fetch!(opts, :subscriptions),
      auth: Auth.config(Keyword.get(opts, :auth, []))
    }
  end

  @impl MqttX.Server
  def handle_connect(_client_id, %{username: username, password: password}, state) do
    # Auth is delegated 100% to this callback (mqttx ships no credential store):
    # service creds → HA user (`Vagus.Auth`) → options logins, see `Broker.Auth`.
    case Auth.authenticate(username, password, state.auth) do
      :ok -> {:ok, state}
      :error -> {:error, @connack_not_authorized, state}
    end
  end

  @impl MqttX.Server
  def handle_subscribe(topics, state) do
    granted =
      Enum.map(topics, fn topic ->
        :ok =
          Subscriptions.subscribe(state.subscriptions, topic.topic, self(), subscribe_opts(topic))

        topic.qos
      end)

    {:ok, granted, state}
  end

  # Carry the full subscription options (not just QoS) into the Router so that
  # `no_local`/`retain_as_published`/`retain_handling` are honoured — the broker
  # accepts MQTT 5.0 (`supported_versions: [3, 4, 5]`), whose subscribers can set
  # these; `match/3`'s no-local filtering relies on them being plumbed here.
  defp subscribe_opts(topic) do
    [
      qos: topic.qos,
      no_local: Map.get(topic, :no_local, false),
      retain_as_published: Map.get(topic, :retain_as_published, false),
      retain_handling: Map.get(topic, :retain_handling, 0)
    ]
  end

  @impl MqttX.Server
  def handle_unsubscribe(topics, state) do
    Enum.each(topics, &Subscriptions.unsubscribe(state.subscriptions, &1, self()))
    {:ok, state}
  end

  @impl MqttX.Server
  def handle_publish(topic, payload, opts, state) do
    # Retained storage/delivery is handled by mqttx before this callback; we own
    # the live fan-out. `self()` as publisher honours the no-local subscription
    # option. Delivered QoS is the min of the publish and subscription QoS (§3.8.4).
    Enum.each(Subscriptions.match(state.subscriptions, topic, self()), fn {pid, sub} ->
      send(pid, {:mqtt_deliver, topic, payload, min(opts.qos, sub.qos)})
    end)

    {:ok, state}
  end

  @impl MqttX.Server
  def handle_info({:mqtt_deliver, topic, payload, qos}, state) do
    {:publish, topic, payload, %{qos: qos, retain: false}, state}
  end

  @impl MqttX.Server
  def handle_disconnect(_reason, _state) do
    # No explicit cleanup: `Subscriptions` monitors this connection pid and reaps
    # all of its subscriptions when the process exits (graceful DISCONNECT and
    # abnormal close both terminate it).
    :ok
  end
end
