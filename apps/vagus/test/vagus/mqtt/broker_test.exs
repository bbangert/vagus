defmodule Vagus.Mqtt.BrokerTest do
  # async: false — the broker binds a real (ephemeral) TCP port and mqttx's
  # singleton client registry / retained-message ETS are process-global.
  use ExUnit.Case, async: false

  alias Vagus.Mqtt.Broker

  # Test-side MQTT client handler: forwards every broker push to the owning test
  # process so assertions can `assert_receive` on delivery.
  defmodule Collector do
    @moduledoc false
    def handle_mqtt_event(:message, {topic, payload, _packet}, %{pid: pid} = state) do
      send(pid, {:mqtt_message, topic, payload})
      state
    end

    def handle_mqtt_event(_event, _data, state), do: state
  end

  setup do
    port = free_port()

    broker =
      start_supervised!({
        Broker,
        # These exercise routing, not auth; opt into anonymous connects so the
        # credential-less test clients are accepted (auth is covered in
        # broker_auth_test.exs).
        name: unique(:broker),
        subscriptions_name: unique(:subs),
        port: port,
        ip: {127, 0, 0, 1},
        auth: [allow_anonymous: true]
      })

    %{broker: broker, port: port}
  end

  test "routes a published message to a matching subscriber at QoS 0 and QoS 1",
       %{port: port} do
    sub = connect_client!(port, "sub")
    pub = connect_client!(port, "pub")

    # Wildcard filter proves mqttx's trie router is actually wired into our
    # fan-out (the framework never wires it itself).
    {:ok, _granted} = MqttX.Client.subscribe(sub, "home/+/temp", qos: 1)

    :ok = MqttX.Client.publish(pub, "home/kitchen/temp", "21.5", qos: 0)
    assert_receive {:mqtt_message, ["home", "kitchen", "temp"], "21.5"}, 1_000

    :ok = MqttX.Client.publish(pub, "home/attic/temp", "9.0", qos: 1)
    assert_receive {:mqtt_message, ["home", "attic", "temp"], "9.0"}, 1_000

    # A non-matching topic must not be delivered.
    :ok = MqttX.Client.publish(pub, "garage/door", "open", qos: 0)
    refute_receive {:mqtt_message, ["garage", "door"], _}, 500
  end

  test "reaps a subscriber's routing entries when it disconnects", %{port: port} do
    sub = connect_client!(port, "sub")
    pub = connect_client!(port, "pub")

    {:ok, _} = MqttX.Client.subscribe(sub, "reap/me", qos: 0)
    :ok = MqttX.Client.publish(pub, "reap/me", "before", qos: 0)
    assert_receive {:mqtt_message, ["reap", "me"], "before"}, 1_000

    :ok = MqttX.Client.disconnect(sub)

    # After the subscriber's connection process exits, its subscription is gone
    # (Subscriptions monitors the connection pid) — the publish reaches no one.
    :ok = MqttX.Client.publish(pub, "reap/me", "after", qos: 0)
    refute_receive {:mqtt_message, ["reap", "me"], "after"}, 750
  end

  @tag :capture_log
  test "the listener restarts cleanly after a forced exit and routes again",
       %{broker: broker, port: port} do
    listener = child_pid(broker, :listener)
    ref = Process.monitor(listener)
    Process.exit(listener, :kill)
    assert_receive {:DOWN, ^ref, :process, ^listener, :killed}, 1_000

    new_listener = wait_for_restart(broker, :listener, listener)
    assert is_pid(new_listener) and new_listener != listener

    sub = connect_client!(port, "sub2")
    pub = connect_client!(port, "pub2")
    {:ok, _} = MqttX.Client.subscribe(sub, "after/restart", qos: 0)
    :ok = MqttX.Client.publish(pub, "after/restart", "ok", qos: 0)
    assert_receive {:mqtt_message, ["after", "restart"], "ok"}, 2_000
  end

  # ---------- helpers ----------

  defp connect_client!(port, tag) do
    {:ok, client} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: "#{tag}-#{System.unique_integer([:positive])}",
        # Broker negotiates 3.1.1 only (supported_versions: [4]); mqttx's client
        # defaults to v5 as of 0.10.0, so opt into v4 explicitly.
        protocol_version: 4,
        clean_session: true,
        retry_interval: 100,
        handler: Collector,
        handler_state: %{pid: self()}
      )

    wait_connected!(client)
    client
  end

  defp wait_connected!(client, tries \\ 100) do
    cond do
      MqttX.Client.connected?(client) -> client
      tries == 0 -> flunk("client never reached connected state")
      true -> Process.sleep(20) && wait_connected!(client, tries - 1)
    end
  end

  defp child_pid(supervisor, id) do
    {^id, pid, _type, _modules} =
      Enum.find(Supervisor.which_children(supervisor), &match?({^id, _, _, _}, &1))

    pid
  end

  defp wait_for_restart(supervisor, id, old_pid, tries \\ 100) do
    case child_pid(supervisor, id) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ when tries == 0 -> flunk("child #{inspect(id)} was not restarted")
      _ -> Process.sleep(20) && wait_for_restart(supervisor, id, old_pid, tries - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
