defmodule Vagus.PowerTest do
  use ExUnit.Case, async: false

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.Config
  alias Vagus.Addon.Store.BuiltinFetcher
  alias Vagus.App

  @slug "core_mqtt"
  @id "addon_core_mqtt"

  defmodule Collector do
    @moduledoc false
    def handle_mqtt_event(:message, {topic, payload, packet}, %{pid: pid} = state) do
      send(pid, {:mqtt_message, topic, payload, Map.take(packet, [:qos, :retain])})
      state
    end

    def handle_mqtt_event(:connected, _data, %{pid: pid, id: id} = state) do
      send(pid, {:mqtt_connected, id})
      state
    end

    def handle_mqtt_event(_event, _data, state), do: state
  end

  describe "mqtt/3 against the real broker" do
    setup do
      port = free_port()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)

      dir = Path.join(System.tmp_dir!(), "vagus_power_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:vagus, :addon_data_root, dir)

      on_exit(fn ->
        Native.stop(@id)
        forget_app()
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
        File.rm_rf(dir)
      end)

      {:ok, config} = Config.parse(BuiltinFetcher.config(:mqtt))
      assert :ok = App.install(%{config | slug: @slug})
      assert {:ok, %{slug: @slug}} = App.start(@slug)
      %{port: port}
    end

    test "a published message reaches a subscriber at QoS 1", %{port: port} do
      sub = subscriber(port, "power-sub")
      {:ok, _} = MqttX.Client.subscribe(sub, "cmnd/plug1/Power", qos: 1)

      assert :ok = Vagus.Power.mqtt("cmnd/plug1/Power", "ON")

      assert_receive {:mqtt_message, ["cmnd", "plug1", "Power"], "ON", %{qos: 1, retain: false}},
                     2_000
    end

    # A live delivery always has retain cleared, so the flag is only
    # observable on a subscribe that arrives after the publish.
    test "retain: true is stored by the broker", %{port: port} do
      assert :ok = Vagus.Power.mqtt("stat/plug1/Power", "OFF", retain: true)

      sub = subscriber(port, "power-late-sub")
      {:ok, _} = MqttX.Client.subscribe(sub, "stat/plug1/Power", qos: 1)

      assert_receive {:mqtt_message, ["stat", "plug1", "Power"], "OFF", %{retain: true}},
                     2_000
    end
  end

  test "no broker service" do
    assert {:error, :no_broker} = Vagus.Power.mqtt("t", "p", service: fn -> :error end)
  end

  test "an unreachable broker is a connect timeout" do
    creds = %{"port" => free_port(), "username" => "u", "password" => "p"}

    assert {:error, {:connect, :timeout}} =
             Vagus.Power.mqtt("t", "p",
               service: fn -> {:ok, "x", creds} end,
               timeout_ms: 500
             )
  end

  test "a refused connect does not echo the password" do
    password = "s3cret-#{System.unique_integer([:positive])}"
    creds = %{"port" => free_port(), "username" => "u", "password" => password}

    assert {:error, reason} =
             Vagus.Power.mqtt("t", "p", service: fn -> {:ok, "x", creds} end, timeout_ms: 300)

    refute inspect(reason) =~ password
  end

  defp subscriber(port, client_id) do
    {:ok, @slug, %{"password" => pass}} = App.service("mqtt")

    {:ok, sub} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: client_id,
        protocol_version: 4,
        username: "addons",
        password: pass,
        handler: Collector,
        handler_state: %{pid: self(), id: client_id}
      )

    assert_receive {:mqtt_connected, ^client_id}, 2_000
    sub
  end

  defp forget_app do
    Vagus.AppFixtures.forget_app(@slug)
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
