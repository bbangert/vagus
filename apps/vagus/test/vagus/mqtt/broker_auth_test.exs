defmodule Vagus.Mqtt.Broker.AuthTest do
  # async: false — the e2e cases bind a real TCP port.
  use ExUnit.Case, async: false

  alias Vagus.Mqtt.Broker
  alias Vagus.Mqtt.Broker.Auth
  alias Vagus.Mqtt.Broker.AuthCache

  # Counts Core hits in the calling (test) process — used to prove the negative
  # cache short-circuits before `check_login` reaches Core.
  defmodule CountingCore do
    def request(:post, "/api/hassio_auth", _opts) do
      Process.put(:core_hits, (Process.get(:core_hits) || 0) + 1)
      {:ok, %{status: 401}}
    end
  end

  # Stateless stub Core: alice/s3cret is the one valid HA user. Must be
  # stateless (not process-dictionary based like the /auth unit test's stub)
  # because `check_login/4` runs inside the broker's connection process, not
  # the test process — `request/3` matches `Vagus.Core.Client.request/3`.
  defmodule StubCore do
    def request(:post, "/api/hassio_auth", opts) do
      case Jason.decode!(Keyword.fetch!(opts, :body)) do
        %{"username" => "alice", "password" => "s3cret"} -> {:ok, %{status: 200}}
        _ -> {:ok, %{status: 401}}
      end
    end
  end

  setup do
    cache = start_supervised!({Vagus.Auth, name: nil})

    services =
      start_supervised!({Vagus.Services, name: :"svc_#{System.unique_integer([:positive])}"})

    config =
      Auth.config(
        slug: "core_mqtt",
        services: services,
        auth_opts: [server: cache, core_client: StubCore],
        logins: [%{username: "optuser", password: "optpass"}]
      )

    %{cache: cache, services: services, config: config}
  end

  describe "authenticate/3" do
    test "accepts a valid Home Assistant user (via check_login → Core)", %{config: config} do
      assert :ok = Auth.authenticate("alice", "s3cret", config)
    end

    test "rejects a Home Assistant user with the wrong password", %{config: config} do
      assert :error = Auth.authenticate("alice", "wrong", config)
    end

    test "accepts registered mqtt service credentials", %{services: services, config: config} do
      :ok =
        Vagus.Services.set(
          "mqtt",
          %{"host" => "h", "port" => 1883, "username" => "svcuser", "password" => "svcpass"},
          "core_mqtt",
          services
        )

      assert :ok = Auth.authenticate("svcuser", "svcpass", config)
      # A service user with the wrong password still falls through to rejection.
      assert :error = Auth.authenticate("svcuser", "nope", config)
    end

    test "accepts a static broker options login", %{config: config} do
      assert :ok = Auth.authenticate("optuser", "optpass", config)
    end

    test "rejects an unknown user", %{config: config} do
      assert :error = Auth.authenticate("mallory", "letmein", config)
    end

    test "rejects an anonymous connect unless allow_anonymous", %{config: config} do
      assert :error = Auth.authenticate(nil, nil, config)
      assert :error = Auth.authenticate("", "", config)
      assert :ok = Auth.authenticate(nil, nil, %{config | allow_anonymous: true})
    end

    test "rejects an empty username and an empty password", %{config: config} do
      # "" username is anonymous (rejected by default); a present username with
      # an empty password is always rejected so an empty secret can't authenticate.
      assert :error = Auth.authenticate("", "s3cret", config)
      assert :error = Auth.authenticate("alice", "", config)
    end

    test "negative cache collapses repeated identical failures to one Core hit",
         %{cache: cache, services: services} do
      table = :"nc_#{System.unique_integer([:positive])}"
      start_supervised!({AuthCache, name: table})
      Process.put(:core_hits, 0)

      config =
        Auth.config(
          slug: "core_mqtt",
          services: services,
          auth_opts: [server: cache, core_client: CountingCore],
          neg_cache: table
        )

      assert :error = Auth.authenticate("ghost", "nope", config)
      assert :error = Auth.authenticate("ghost", "nope", config)
      # Second attempt short-circuited on the cache — Core hit only once.
      assert Process.get(:core_hits) == 1

      # A different password is a different key — not blocked by the cached failure.
      assert :error = Auth.authenticate("ghost", "other", config)
      assert Process.get(:core_hits) == 2
    end
  end

  describe "CONNECT through the broker (mirrors mosquitto_pub exit 0 / exit 5)" do
    setup %{config: config} do
      port = free_port()

      start_supervised!(
        {Broker,
         name: unique(:broker),
         subscriptions_name: unique(:subs),
         port: port,
         ip: {127, 0, 0, 1},
         auth: [
           slug: config.slug,
           services: config.services,
           auth_opts: config.auth_opts,
           logins: config.logins
         ]}
      )

      %{port: port}
    end

    test "a valid HA user connects (exit-0 analog)", %{port: port} do
      assert connected_within?(client(port, "alice", "s3cret"))
    end

    test "an accepted service user connects", %{port: port, services: services} do
      :ok =
        Vagus.Services.set(
          "mqtt",
          %{"host" => "h", "port" => 1883, "username" => "svcuser", "password" => "svcpass"},
          "core_mqtt",
          services
        )

      assert connected_within?(client(port, "svcuser", "svcpass"))
    end

    @tag :capture_log
    test "a wrong password is rejected — never connects (exit-5 analog)", %{port: port} do
      refute connected_within?(client(port, "alice", "wrong"), 12)
    end

    @tag :capture_log
    test "an unknown user is rejected", %{port: port} do
      refute connected_within?(client(port, "mallory", "letmein"), 12)
    end

    @tag :capture_log
    test "a rejected CONNECT gets CONNACK reason code 0x05 (not authorised)", %{port: port} do
      handler_id = "connack-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:mqttx, :server, :client_connect, :exception],
        fn _event, _measure, meta, _cfg ->
          send(test_pid, {:connack_reject, meta[:reason_code]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      client(port, "alice", "wrong")
      # The server emits the connect-exception with the reason code it put in the
      # CONNACK — assert it's 0x05, the byte the P6 mosquitto_pub exit-5 gate checks.
      assert_receive {:connack_reject, 0x05}, 1_000
    end
  end

  # ---------- helpers ----------

  defp client(port, username, password) do
    {:ok, client} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: "c-#{System.unique_integer([:positive])}",
        protocol_version: 4,
        clean_session: true,
        retry_interval: 200,
        username: username,
        password: password
      )

    client
  end

  defp connected_within?(client, tries \\ 40) do
    cond do
      MqttX.Client.connected?(client) -> true
      tries == 0 -> false
      true -> Process.sleep(25) && connected_within?(client, tries - 1)
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
