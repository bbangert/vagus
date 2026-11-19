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
    service_login = %{username: "svcuser", password: "svcpass"}

    config =
      Auth.config(
        slug: "core_mqtt",
        service_login: fn -> service_login end,
        auth_opts: [server: cache, core_client: StubCore],
        logins: [%{username: "optuser", password: "optpass"}]
      )

    %{cache: cache, service_login: service_login, config: config}
  end

  describe "authenticate/3" do
    test "accepts a valid Home Assistant user (via check_login → Core)", %{config: config} do
      assert :ok = Auth.authenticate("alice", "s3cret", config)
    end

    test "rejects a Home Assistant user with the wrong password", %{config: config} do
      assert :error = Auth.authenticate("alice", "wrong", config)
    end

    test "accepts the service login it was started with", %{config: config} do
      assert :ok = Auth.authenticate("svcuser", "svcpass", config)
      # A service user with the wrong password still falls through to rejection.
      assert :error = Auth.authenticate("svcuser", "nope", config)
    end

    test "has no service login unless it was started with one", %{config: config} do
      assert :error = Auth.authenticate("svcuser", "svcpass", %{config | service_login: nil})
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
         %{cache: cache} do
      table = :"nc_#{System.unique_integer([:positive])}"
      start_supervised!({AuthCache, name: table})
      Process.put(:core_hits, 0)

      config =
        Auth.config(
          slug: "core_mqtt",
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
         port: port,
         ip: {127, 0, 0, 1},
         auth: [
           slug: config.slug,
           service_login: config.service_login,
           auth_opts: config.auth_opts,
           logins: config.logins
         ]}
      )

      %{port: port}
    end

    test "a valid HA user connects (exit-0 analog)", %{port: port} do
      assert {:ok, client} = connect(port, "alice", "s3cret")
      assert MqttX.Client.connected?(client)
    end

    test "an accepted service user connects", %{port: port} do
      assert {:ok, client} = connect(port, "svcuser", "svcpass")
      assert MqttX.Client.connected?(client)
    end

    @tag :capture_log
    test "a wrong password is rejected — never connects (exit-5 analog)", %{port: port} do
      assert {:error, {:connack_error, 0x05, _}} = connect(port, "alice", "wrong")
    end

    @tag :capture_log
    test "an unknown user is rejected", %{port: port} do
      assert {:error, {:connack_error, 0x05, _}} = connect(port, "mallory", "letmein")
    end

    # The client reports the code its CONNACK carried: 5 is the byte the
    # mosquitto_pub exit-5 gate checks; a v5 CONNACK has no 0x05 and says 0x87.
    @tag :capture_log
    test "a rejected CONNECT is Not authorized on the wire for both versions",
         %{port: port} do
      assert {:error, {:connack_error, 0x05, _}} = connect(port, "alice", "wrong", 4)
      assert {:error, {:connack_error, 0x87, _}} = connect(port, "alice", "wrong", 5)
    end
  end

  # ---------- helpers ----------

  # `await_connect: true` returns the CONNACK's verdict; a rejected client
  # stops itself instead of retrying.
  defp connect(port, username, password, version \\ 4) do
    MqttX.Client.connect(
      host: "127.0.0.1",
      port: port,
      client_id: "c-#{System.unique_integer([:positive])}",
      protocol_version: version,
      clean_session: true,
      await_connect: true,
      username: username,
      password: password
    )
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
