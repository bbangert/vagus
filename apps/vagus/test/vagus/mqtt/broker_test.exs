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

  test "accepts MQTT 5.0 and 3.1 connects and routes across versions", %{port: port} do
    # Home Assistant Core connects with MQTT 5.0; a 3.1.1-only broker rejects it
    # (P6 finding) — `supported_versions: [3, 4, 5]`.
    v5_sub = connect_client!(port, "v5sub", 5)
    v31_pub = connect_client!(port, "v31pub", 3)

    {:ok, _} = MqttX.Client.subscribe(v5_sub, "cross/version", qos: 1)
    :ok = MqttX.Client.publish(v31_pub, "cross/version", "ok", qos: 1)
    assert_receive {:mqtt_message, ["cross", "version"], "ok"}, 1_000
  end

  # MQ-P4-T3-orig (hermetic half): retained + QoS1/2 round-trips. The
  # backup/restore and /services halves were superseded by the revised
  # MQ-P4-T3 (see plan); retained/QoS is what remained untested.
  test "a retained message is delivered to a LATER subscriber", %{port: port} do
    pub = connect_client!(port, "ret-pub")
    :ok = MqttX.Client.publish(pub, "ret/state", "sticky", qos: 1, retain: true)

    # Subscriber connects AFTER the publish — delivery can only come from
    # the broker's retained store.
    sub = connect_client!(port, "ret-sub")
    {:ok, _} = MqttX.Client.subscribe(sub, "ret/state", qos: 1)
    assert_receive {:mqtt_message, ["ret", "state"], "sticky"}, 1_000

    # An empty retained publish clears the store. It's ALSO a normal
    # publish, so the still-connected subscriber legitimately receives the
    # empty payload live (both clients report into this test process) —
    # consume that delivery first.
    :ok = MqttX.Client.publish(pub, "ret/state", "", qos: 1, retain: true)
    assert_receive {:mqtt_message, ["ret", "state"], ""}, 1_000

    # A FRESH subscriber gets nothing: the retained entry is gone.
    #
    # This one gets an inbox of its own. Every other client in this test
    # reports into the test process, and `assert_receive` matches
    # *selectively* — the assertion above steps over any still-unconsumed
    # "sticky" to match "". A wildcard `refute_receive` here would then pick
    # that leftover up and blame it on `late`, which is a different (and
    # racy) claim than "the late subscriber received nothing". QoS 1 is
    # "at least once", so a duplicate delivery to `sub` is spec-legal and
    # cannot be assumed away. Isolating the mailbox makes the assertion mean
    # what its comment says.
    late_inbox = start_inbox()
    late = connect_client!(port, "ret-late", 4, late_inbox)
    {:ok, _} = MqttX.Client.subscribe(late, "ret/state", qos: 1)

    # Same wait `refute_receive` would have used, just against a mailbox only
    # `late` can write to.
    Process.sleep(500)
    assert inbox_messages(late_inbox) == []
  end

  test "QoS 2 publish round-trips to a QoS 2 subscriber", %{port: port} do
    sub = connect_client!(port, "q2-sub")
    pub = connect_client!(port, "q2-pub")

    {:ok, _granted} = MqttX.Client.subscribe(sub, "exactly/once", qos: 2)
    :ok = MqttX.Client.publish(pub, "exactly/once", "one-time", qos: 2)
    assert_receive {:mqtt_message, ["exactly", "once"], "one-time"}, 1_000
    # Exactly-once at the protocol layer: no duplicate delivery.
    refute_receive {:mqtt_message, ["exactly", "once"], "one-time"}, 500
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

  # `owner` is the pid this client's deliveries are sent to. It defaults to
  # the test process (which is what almost every test wants — one mailbox,
  # one `assert_receive`); pass the pid `start_inbox()` returns when an
  # assertion must be about *this* client's deliveries and nothing else's.
  defp connect_client!(port, tag, version \\ 4, owner \\ nil) do
    {:ok, client} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: "#{tag}-#{System.unique_integer([:positive])}",
        protocol_version: version,
        clean_session: true,
        retry_interval: 100,
        handler: Collector,
        handler_state: %{pid: owner || self()}
      )

    wait_connected!(client)
    client
  end

  # A mailbox only one client writes to. Linked, so it dies with the test.
  defp start_inbox do
    spawn_link(fn -> inbox_loop([]) end)
  end

  defp inbox_loop(received) do
    receive do
      {:dump, from} ->
        send(from, {:inbox, Enum.reverse(received)})
        inbox_loop(received)

      message ->
        inbox_loop([message | received])
    end
  end

  defp inbox_messages(inbox) do
    send(inbox, {:dump, self()})

    receive do
      {:inbox, messages} -> messages
    after
      1_000 -> flunk("inbox process never answered")
    end
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
