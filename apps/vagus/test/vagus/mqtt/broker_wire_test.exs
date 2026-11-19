defmodule Vagus.Mqtt.Broker.WireTest do
  # async: false — the broker binds a real (ephemeral) TCP port.
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec
  alias Vagus.Mqtt.Broker

  # Upper bound on any wait for an event; a pass returns as soon as it arrives,
  # so it is generous for a starved runner.
  @wait 10_000

  # Raw sockets rather than MqttX.Client: these assert on the exact packets the
  # broker writes (CONNACK properties, a PUBLISH's Subscription Identifiers,
  # a DISCONNECT), and need to send packets a well-behaved client refuses to.

  defmodule DenyCore do
    @moduledoc false
    def request(:post, "/api/hassio_auth", _opts), do: {:ok, %{status: 401}}
  end

  setup do
    start_broker([])
  end

  defp start_broker(opts) do
    {port, opts} = Keyword.pop_lazy(opts, :port, &free_port/0)
    id = unique(:broker_child)

    broker =
      start_supervised!(
        {Broker,
         [
           name: unique(:broker),
           auth_cache_name: unique(:auth_cache),
           port: port,
           ip: {127, 0, 0, 1},
           auth: [allow_anonymous: true]
         ]
         |> Keyword.merge(opts)},
        id: id
      )

    %{port: port, broker: broker, id: id}
  end

  test "CONNACK advertises Subscription Identifiers", %{port: port} do
    {_sock, connack} = connect(port, 5)
    assert connack.properties[:subscription_identifier_available] == true
  end

  test "a matching PUBLISH carries the subscription's identifier", %{port: port} do
    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "a/b", qos: 0}], 7)

    publish(port, [{"a/b", "x"}])

    assert %{topic: ["a", "b"], payload: "x", properties: props} = recv_publish(sub, 5)
    assert props[:subscription_identifier] == 7
  end

  test "overlapping subscriptions deliver once, with every identifier", %{port: port} do
    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "s/+", qos: 0}], 1)
    subscribe(sub, 5, [%{topic: "s/#", qos: 0}], 2)
    # Matches too but has no identifier, so it adds none.
    subscribe(sub, 5, [%{topic: "s/x", qos: 0}], nil)

    publish(port, [{"s/x", "y"}, {"s/x", "sentinel"}])

    assert %{payload: "y", properties: props} = recv_publish(sub, 5)
    assert Enum.sort(List.wrap(props[:subscription_identifier])) == [1, 2]
    # One connection published both, so they reach the subscriber in order: a
    # duplicate of "y" would come before the sentinel.
    assert %{payload: "sentinel"} = recv_publish(sub, 5)
  end

  test "a retained message delivered on subscribe carries the identifier", %{port: port} do
    # mqttx writes the retained store before it queues the PUBACK.
    {pub, _} = connect(port, 5)

    send_packet(pub, 5, %{
      type: :publish,
      topic: "r/t",
      payload: "kept",
      qos: 1,
      packet_id: 1,
      retain: true
    })

    assert {:ok, %{type: :puback, packet_id: 1}} = recv(pub, 5, @wait)

    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "r/#", qos: 0}], 9)

    assert %{topic: ["r", "t"], retain: true, properties: props} = recv_publish(sub, 5)
    assert props[:subscription_identifier] == 9
  end

  test "a shared subscription's delivery carries its identifier", %{port: port} do
    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "$share/g/sh/t", qos: 0}], 5)

    publish(port, [{"sh/t", "z"}])

    assert %{topic: ["sh", "t"], properties: props} = recv_publish(sub, 5)
    assert props[:subscription_identifier] == 5
  end

  test "a no-local subscription adds no identifier to the publisher's own message",
       %{port: port} do
    {sock, _} = connect(port, 5)
    subscribe(sock, 5, [%{topic: "n/t", qos: 0, no_local: true}], 3)
    subscribe(sock, 5, [%{topic: "n/+", qos: 0}], 4)

    send_packet(sock, 5, %{type: :publish, topic: "n/t", payload: "own", qos: 0})

    assert %{properties: props} = recv_publish(sock, 5)
    assert props[:subscription_identifier] == 4
  end

  test "a client PUBLISH carrying an identifier is refused, not forwarded", %{port: port} do
    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "f/t", qos: 0}], 11)

    {pub, _} = connect(port, 5)

    send_packet(pub, 5, %{
      type: :publish,
      topic: "f/t",
      payload: "forged",
      qos: 0,
      properties: %{subscription_identifier: 99}
    })

    assert {:ok, %{type: :disconnect, reason_code: 0x82}} = recv(pub, 5, @wait)
    # Had it been forwarded, the delivery was sent to the subscriber's
    # connection before that DISCONNECT was written, so ahead of this one.
    publish(port, [{"f/t", "sentinel"}])
    assert %{payload: "sentinel"} = recv_publish(sub, 5)
  end

  test "subscribing twice to one filter delivers once", %{port: port} do
    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "d/+", qos: 0}], nil)
    subscribe(sub, 5, [%{topic: "d/+", qos: 1}], nil)

    publish(port, [{"d/t", "once"}, {"d/t", "sentinel"}])

    assert %{payload: "once"} = recv_publish(sub, 5)
    assert %{payload: "sentinel"} = recv_publish(sub, 5)
  end

  test "a SUBSCRIBE with identifier 0 is refused", %{port: port} do
    {sock, _} = connect(port, 5)

    # The encoder will not build this one: properties length 2, Subscription
    # Identifier (0x0B) with the varint 0, then "t/0" at QoS 0.
    body = <<1::16, 2, 0x0B, 0, 3::16, "t/0", 0>>
    :ok = :gen_tcp.send(sock, [<<0x82, byte_size(body)>>, body])

    assert recv(sock, 5, @wait) == :closed
  end

  test "a v3.1.1 subscriber gets a plain PUBLISH next to a v5 one", %{port: port} do
    {v5, _} = connect(port, 5)
    subscribe(v5, 5, [%{topic: "m/t", qos: 0}], 21)
    {v4, _} = connect(port, 4)
    subscribe(v4, 4, [%{topic: "m/t", qos: 0}], nil)

    publish(port, [{"m/t", "both"}])

    assert %{properties: props} = recv_publish(v5, 5)
    assert props[:subscription_identifier] == 21
    assert %{topic: ["m", "t"], payload: "both"} = v4_publish = recv_publish(v4, 4)
    assert Map.get(v4_publish, :properties, %{}) == %{}
  end

  test "the publisher's properties reach the subscriber", %{port: port} do
    {sub, _} = connect(port, 5)
    subscribe(sub, 5, [%{topic: "pr/t", qos: 0}], 2)
    {pub, _} = connect(port, 5)

    send_packet(pub, 5, %{
      type: :publish,
      topic: "pr/t",
      payload: "{}",
      qos: 0,
      properties: %{content_type: "application/json", user_properties: [{"k", "v"}]}
    })

    assert %{properties: props} = recv_publish(sub, 5)
    assert props[:content_type] == "application/json"
    assert props[:user_properties] == [{"k", "v"}]
    assert props[:subscription_identifier] == 2
  end

  test "a payload over 1 MiB is accepted and delivered intact", %{port: port} do
    {sub, connack} = connect(port, 5)
    refute Map.has_key?(connack.properties, :maximum_packet_size)
    subscribe(sub, 5, [%{topic: "big/t", qos: 1}], nil)

    payload = :crypto.strong_rand_bytes(2 * 1024 * 1024)
    publish(port, [{"big/t", payload, 1}])

    assert %{payload: ^payload} = recv_publish(sub, 5)
  end

  # {filter, topic, matches?} per MQTT 5.0 §4.7, through the broker.
  @filters [
    {"/lead", "/lead", true},
    {"/lead", "lead", false},
    {"trail/", "trail/", true},
    {"trail/", "trail", false},
    {"a//b", "a//b", true},
    {"a//b", "a/b", false},
    {"$SYS/#", "$SYS/x", true},
    {"$SYS/#", "$SYS", true},
    {"#", "a/b", true},
    {"#", "$SYS/x", false},
    {"+/x", "a/x", true},
    {"+/x", "/x", true},
    {"+/x", "$SYS/x", false},
    {"x/+/y", "x//y", true},
    {"x/+/y", "x/a/b/y", false},
    {"x/#", "x", true},
    {"x/#", "x/a/b", true},
    {"+", "a", true},
    {"+", "a/b", false},
    {"+", "/a", false}
  ]

  test "filters match topics as MQTT specifies", %{port: port} do
    for {filter, topic, expected} <- @filters do
      {sub, _} = connect(port, 5)
      subscribe(sub, 5, [%{topic: filter, qos: 0}, %{topic: "sentinel/t", qos: 0}], nil)

      publish(port, [{topic, "probe"}, {"sentinel/t", "sentinel"}])

      got = recv_publish(sub, 5).payload == "probe"
      if got, do: assert(%{payload: "sentinel"} = recv_publish(sub, 5))

      assert {filter, topic, got} == {filter, topic, expected}
      :gen_tcp.close(sub)
    end
  end

  # The ceiling itself, shortened, so the test that the broker turns it off
  # rests on a mechanism shown to cut a keep-alive-0 client.
  test "an idle ceiling, when set, closes a quiet keep-alive-0 client" do
    ctx = start_broker(max_idle_timeout: 200)
    {sock, _} = connect(ctx.port, 4, keep_alive: 0)
    assert recv(sock, 4, @wait) == :closed
  end

  # Clean Start 0 sessions: mqttx keeps them, routes to them and queues for
  # them, so session_present 1 always comes with the subscriptions and the
  # messages the client missed.
  describe "sessions" do
    @persistent [{4, %{}}, {5, %{session_expiry_interval: 100}}]

    test "a reconnect after DISCONNECT resumes the session", ctx do
      for {version, props} <- @persistent do
        id = "clean-#{version}-#{System.unique_integer([:positive])}"
        {sock, conn} = persistent(ctx, version, id, props)

        send_packet(sock, version, %{type: :disconnect, reason_code: 0})
        assert_receive {:DOWN, _, :process, ^conn, _}, @wait

        assert_resumes(ctx, version, id, props)
      end
    end

    test "a reconnect after the socket drops resumes the session", ctx do
      for {version, props} <- @persistent do
        id = "drop-#{version}-#{System.unique_integer([:positive])}"
        {sock, conn} = persistent(ctx, version, id, props)

        :gen_tcp.close(sock)
        assert_receive {:DOWN, _, :process, ^conn, _}, @wait

        assert_resumes(ctx, version, id, props)
      end
    end

    test "a takeover resumes the session", ctx do
      for {version, props} <- @persistent do
        id = "take-#{version}-#{System.unique_integer([:positive])}"
        {_old, _conn} = persistent(ctx, version, id, props)

        {new, connack} = reconnect(ctx, version, id, props)
        assert connack.session_present
        assert_delivered(ctx.port, new, version)
      end
    end

    test "a takeover re-sends the old connection's unacknowledged QoS 1", ctx do
      id = "inflight-#{System.unique_integer([:positive])}"
      {old, _conn} = persistent(ctx, 4, id, %{})
      publish(ctx.port, [{"sess/t", "unacked", 1}])
      assert %{payload: "unacked", qos: 1, dup: false} = recv_publish(old, 4)

      {new, connack} = reconnect(ctx, 4, id, %{})
      assert connack.session_present
      assert %{payload: "unacked", qos: 1, dup: true} = recv_publish(new, 4)
    end

    test "a v5 resume keeps the Subscription Identifier", ctx do
      id = "id-#{System.unique_integer([:positive])}"
      props = %{session_expiry_interval: 100}
      {sock, conn} = persistent(ctx, 5, id, props, 13)
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      {new, connack} = reconnect(ctx, 5, id, props)
      assert connack.session_present
      publish(ctx.port, [{"sess/t", "after"}])

      assert %{payload: "after", properties: %{subscription_identifier: 13}} =
               recv_publish(new, 5)
    end

    test "QoS 1 published while away is delivered on resume; QoS 0 is not queued", ctx do
      id = "away-#{System.unique_integer([:positive])}"
      {sock, conn} = persistent(ctx, 4, id, %{})
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      publish(ctx.port, [{"sess/t", "q0", 0}, {"sess/t", "q1", 1}])

      {new, connack} = reconnect(ctx, 4, id, %{})
      assert connack.session_present
      assert %{payload: "q1", qos: 1} = recv_publish(new, 4)
      publish(ctx.port, [{"sess/t", "sentinel"}])
      assert %{payload: "sentinel"} = recv_publish(new, 4)
    end

    test "the queue for an absent session is bounded", %{port: _} do
      ctx = start_broker(max_queued: 2)
      id = "bound-#{System.unique_integer([:positive])}"
      {sock, conn} = persistent(ctx, 4, id, %{})
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      publish(ctx.port, [{"sess/t", "1", 1}, {"sess/t", "2", 1}, {"sess/t", "3", 1}])
      {new, _} = reconnect(ctx, 4, id, %{})

      assert %{payload: "1"} = recv_publish(new, 4)
      assert %{payload: "2"} = recv_publish(new, 4)
      publish(ctx.port, [{"sess/t", "sentinel"}])
      assert %{payload: "sentinel"} = recv_publish(new, 4)
    end

    test "an expired session is discarded", ctx do
      id = "expire-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler = "expired-#{id}"

      :telemetry.attach(
        handler,
        [:vagus, :mqtt, :session_expired],
        fn _, _, meta, _ -> send(test_pid, {:expired, meta.client_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {sock, _conn} = persistent(ctx, 5, id, %{session_expiry_interval: 1})
      send_packet(sock, 5, %{type: :disconnect, reason_code: 0})
      assert_receive {:expired, ^id}, @wait

      {_sock, connack} = reconnect(ctx, 5, id, %{session_expiry_interval: 1})
      refute connack.session_present
    end

    test "Clean Start 1 discards the session", ctx do
      id = "fresh-#{System.unique_integer([:positive])}"
      {sock, conn} = persistent(ctx, 4, id, %{})
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      publish(ctx.port, [{"sess/t", "missed", 1}])

      {sock, connack} = connect(ctx.port, 4, client_id: id, clean_session: true)
      refute connack.session_present
      # The discarded session took its subscription and queue with it.
      subscribe(sock, 4, [%{topic: "other/t", qos: 0}], nil)
      publish(ctx.port, [{"other/t", "sentinel"}])
      assert %{payload: "sentinel"} = recv_publish(sock, 4)
    end

    test "a login that no longer authenticates does not get its session back" do
      password = :atomics.new(1, [])
      :atomics.put(password, 1, 1)
      login = fn -> %{username: "svc", password: "pw#{:atomics.get(password, 1)}"} end
      cache = start_supervised!({Vagus.Auth, name: nil})

      ctx =
        start_broker(
          auth: [service_login: login, auth_opts: [server: cache, core_client: DenyCore]]
        )

      id = "revoked-#{System.unique_integer([:positive])}"
      creds = [username: "svc", password: "pw1"]
      {sock, conn} = persistent(ctx, 4, id, %{}, nil, creds)
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait
      publish(ctx.port, [{"sess/t", "kept", 1}], creds)

      :atomics.put(password, 1, 2)
      refused = [client_id: id, clean_session: false] ++ creds
      {sock, result} = raw_connect_sock(ctx.port, 4, refused)
      assert {:ok, %{type: :connack, reason_code: 0x05}} = result
      assert recv(sock, 4, @wait) == :closed

      # The refused CONNECT touched nothing: the session and its queue are
      # there for a CONNECT with the current password. (The refused pair is
      # now in the negative-auth cache.)
      {new, connack} =
        connect(ctx.port, 4,
          client_id: id,
          clean_session: false,
          username: "svc",
          password: "pw2"
        )

      assert connack.session_present
      assert %{payload: "kept"} = recv_publish(new, 4)
    end

    test "a listener stop keeps the sessions it held", ctx do
      for {version, props} <- @persistent do
        id = "stop-#{version}-#{System.unique_integer([:positive])}"
        {_sock, conn} = persistent(ctx, version, id, props)

        :ok = Supervisor.terminate_child(ctx.broker, :listener)
        assert_receive {:DOWN, _, :process, ^conn, _}, @wait
        {:ok, _} = Supervisor.restart_child(ctx.broker, :listener)

        assert_resumes(ctx, version, id, props)
      end
    end

    @tag :capture_log
    test "a killed listener keeps the sessions it held", ctx do
      id = "kill-#{System.unique_integer([:positive])}"
      {_sock, conn} = persistent(ctx, 4, id, %{})
      listener = child(ctx.broker, :listener)

      Process.exit(listener, :kill)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait
      await_restart(ctx.broker, :listener, listener)

      assert_resumes(ctx, 4, id, %{})
    end

    # A listener stop skips each connection's close, so every session it held,
    # Clean Start 1 ones too, stays and keeps queuing QoS 1/2 until its client
    # id connects again.
    @tag :capture_log
    test "a listener stop leaves sessions queuing until their client returns", ctx do
      name = Broker.listener_name(ctx.port)
      {_kept, kept_conn} = persistent(ctx, 4, "orphan-kept", %{})
      {clean, _} = connect(ctx.port, 4, client_id: "orphan-clean", clean_session: true)
      subscribe(clean, 4, [%{topic: "sess/t", qos: 1}], nil)

      :ok = Supervisor.terminate_child(ctx.broker, :listener)
      assert_receive {:DOWN, _, :process, ^kept_conn, _}, @wait
      {:ok, _} = Supervisor.restart_child(ctx.broker, :listener)

      assert {:ok, 2} = MqttX.Server.deliver(name, "sess/t", "orphaned", %{qos: 1})

      # Clean Start 1 discards the one it finds.
      {sock, connack} = connect(ctx.port, 4, client_id: "orphan-clean", clean_session: true)
      refute connack.session_present
      {:ok, [conn]} = ThousandIsland.connection_pids(child(ctx.broker, :listener))
      Process.monitor(conn)
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      assert {:ok, 1} = MqttX.Server.deliver(name, "sess/t", "orphaned", %{qos: 1})
    end

    test "a CONNECT past the session limit is refused" do
      ctx = start_broker(max_sessions: 1)
      {_held, _} = connect(ctx.port, 5)

      assert {:ok, %{type: :connack, reason_code: 0x97}} = raw_connect(ctx.port, 5, [])
      assert {:ok, %{type: :connack, reason_code: 0x05}} = raw_connect(ctx.port, 4, [])
    end

    test "sessions and retained messages end with the broker", ctx do
      id = "restart-#{System.unique_integer([:positive])}"
      {sock, conn} = persistent(ctx, 4, id, %{})
      {pub, _} = connect(ctx.port, 5)

      send_packet(pub, 5, %{
        type: :publish,
        topic: "keep/t",
        payload: "r",
        qos: 1,
        packet_id: 1,
        retain: true
      })

      assert {:ok, %{type: :puback}} = recv(pub, 5, @wait)
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      :ok = stop_supervised(ctx.id)
      ctx = start_broker(port: ctx.port)

      {sock, connack} = reconnect(ctx, 4, id, %{})
      refute connack.session_present
      subscribe(sock, 4, [%{topic: "keep/t", qos: 0}, %{topic: "sentinel/t", qos: 0}], nil)
      publish(ctx.port, [{"sentinel/t", "sentinel"}])
      assert %{payload: "sentinel"} = recv_publish(sock, 4)
    end

    test "two listeners share no sessions or retained messages", ctx do
      other = start_broker([])
      id = "iso-#{System.unique_integer([:positive])}"
      {sock, conn} = persistent(ctx, 4, id, %{})
      {pub, _} = connect(ctx.port, 5)

      send_packet(pub, 5, %{
        type: :publish,
        topic: "iso/t",
        payload: "r",
        qos: 1,
        packet_id: 1,
        retain: true
      })

      assert {:ok, %{type: :puback}} = recv(pub, 5, @wait)
      :gen_tcp.close(sock)
      assert_receive {:DOWN, _, :process, ^conn, _}, @wait

      {sock, connack} = reconnect(other, 4, id, %{})
      refute connack.session_present
      subscribe(sock, 4, [%{topic: "iso/t", qos: 0}, %{topic: "sentinel/t", qos: 0}], nil)
      publish(other.port, [{"sentinel/t", "sentinel"}])
      assert %{payload: "sentinel"} = recv_publish(sock, 4)
    end

    test "a v5 Session Expiry Interval is capped at a day", %{port: port} do
      {_sock, connack} =
        connect(port, 5, clean_session: false, properties: %{session_expiry_interval: 0xFFFFFFFE})

      assert connack.properties[:session_expiry_interval] == 86_400
    end
  end

  # A Clean Start 0 connection subscribed to "sess/t" at QoS 1, and its
  # connection process, monitored.
  defp persistent(ctx, version, id, props, sub_id \\ nil, creds \\ []) do
    listener = child(ctx.broker, :listener)
    {:ok, before} = ThousandIsland.connection_pids(listener)

    {sock, connack} =
      connect(
        ctx.port,
        version,
        [client_id: id, clean_session: false, properties: props] ++ creds
      )

    refute connack.session_present
    subscribe(sock, version, [%{topic: "sess/t", qos: 1}], sub_id)
    {:ok, now} = ThousandIsland.connection_pids(listener)
    [conn] = now -- before
    Process.monitor(conn)
    {sock, conn}
  end

  defp reconnect(ctx, version, id, props),
    do: connect(ctx.port, version, client_id: id, clean_session: false, properties: props)

  # A QoS 1 message published while the client was away, then a live one, both
  # without the client subscribing again.
  defp assert_resumes(ctx, version, id, props) do
    publish(ctx.port, [{"sess/t", "missed", 1}])
    {sock, connack} = reconnect(ctx, version, id, props)
    assert connack.session_present
    assert %{payload: "missed"} = recv_publish(sock, version)
    assert_delivered(ctx.port, sock, version)
  end

  defp assert_delivered(port, sock, version) do
    publish(port, [{"sess/t", "live"}])
    assert %{payload: "live"} = recv_publish(sock, version)
  end

  defp child(sup, id) do
    {^id, pid, _, _} = Enum.find(Supervisor.which_children(sup), &match?({^id, _, _, _}, &1))
    pid
  end

  # The supervisor restarts the child when it handles the exit; each call
  # here queues behind that.
  defp await_restart(sup, id, old, tries \\ 200) do
    case child(sup, id) do
      pid when is_pid(pid) and pid != old -> pid
      _ when tries > 0 -> await_restart(sup, id, old, tries - 1)
    end
  end

  test "PUBLISHes to a v5 client carry no Topic Alias", %{port: port} do
    {sub, _} = connect(port, 5, properties: %{topic_alias_maximum: 10})
    subscribe(sub, 5, [%{topic: "al/t", qos: 0}], nil)

    publish(port, [{"al/t", "1"}, {"al/t", "2"}])

    for payload <- ["1", "2"] do
      assert %{topic: ["al", "t"], payload: ^payload, properties: props} = recv_publish(sub, 5)
      refute Map.has_key?(props, :topic_alias)
    end
  end

  # Listeners that share a name across connected nodes form one broker; the
  # default name, the port, is the same on every board.
  test "the listener's cluster group is not named after its port", %{port: port} do
    groups = :pg.which_groups(MqttX.Server.Cluster.scope())
    refute port in groups
    assert Enum.any?(groups, &match?({Broker, _token, ^port}, &1))
  end

  # ---------- raw MQTT client ----------

  defp connect(port, version, opts \\ []) do
    {sock, result} = raw_connect_sock(port, version, opts)
    assert {:ok, %{type: :connack, reason_code: 0} = connack} = result
    {sock, connack}
  end

  defp raw_connect(port, version, opts), do: port |> raw_connect_sock(version, opts) |> elem(1)

  defp raw_connect_sock(port, version, opts) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    send_packet(sock, version, %{
      type: :connect,
      protocol_version: version,
      client_id: Keyword.get(opts, :client_id, "raw-#{System.unique_integer([:positive])}"),
      clean_session: Keyword.get(opts, :clean_session, true),
      keep_alive: Keyword.get(opts, :keep_alive, 60),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      properties: Keyword.get(opts, :properties, %{})
    })

    {sock, recv(sock, version, @wait)}
  end

  defp subscribe(sock, version, topics, id) do
    packet_id = System.unique_integer([:positive, :monotonic]) |> rem(65_535) |> Kernel.+(1)
    props = if id, do: %{subscription_identifier: id}, else: %{}

    send_packet(sock, version, %{
      type: :subscribe,
      packet_id: packet_id,
      topics: topics,
      properties: props
    })

    assert {:ok, %{type: :suback, packet_id: ^packet_id}} = recv(sock, version, @wait)
  end

  # Each message is {topic, payload} or {topic, payload, qos}, all sent on one
  # new connection, so they are handled in order. Returns once every QoS 1
  # message is acknowledged, which mqttx does after the handler fanned it out.
  defp publish(port, messages, creds \\ []) do
    {sock, _} = connect(port, 5, creds)

    messages
    |> Enum.with_index(1)
    |> Enum.each(fn {message, packet_id} ->
      {topic, payload, qos} =
        case message do
          {topic, payload} -> {topic, payload, 0}
          {_topic, _payload, _qos} = full -> full
        end

      packet = %{type: :publish, topic: topic, payload: payload, qos: qos}
      send_packet(sock, 5, if(qos > 0, do: Map.put(packet, :packet_id, packet_id), else: packet))
    end)

    for {{_t, _p, qos}, packet_id} <- Enum.with_index(messages, 1), qos > 0 do
      assert {:ok, %{type: :puback, packet_id: ^packet_id}} = recv(sock, 5, @wait)
    end

    sock
  end

  defp recv_publish(sock, version) do
    assert {:ok, %{type: :publish} = publish} = recv(sock, version, @wait)
    publish
  end

  defp send_packet(sock, version, packet) do
    {:ok, data} = Codec.encode(version, packet)
    :ok = :gen_tcp.send(sock, data)
  end

  # Bytes past the decoded packet are kept per socket for the next call.
  defp recv(sock, version, timeout) do
    buffer = Process.get({:buffer, sock}, <<>>)

    case Codec.decode(version, buffer) do
      {:ok, {packet, rest}} ->
        Process.put({:buffer, sock}, rest)
        {:ok, packet}

      {:error, :incomplete} ->
        case :gen_tcp.recv(sock, 0, timeout) do
          {:ok, data} ->
            Process.put({:buffer, sock}, buffer <> data)
            recv(sock, version, timeout)

          {:error, :timeout} ->
            :timeout

          {:error, :closed} ->
            :closed
        end
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
