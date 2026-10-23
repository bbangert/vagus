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
    def handle_mqtt_event(:message, {topic, payload, _packet}, %{pid: pid} = state) do
      send(pid, {:mqtt_message, topic, payload})
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

    test "a published message reaches a subscriber", %{port: port} do
      {:ok, @slug, %{"password" => pass}} = App.service("mqtt")

      {:ok, sub} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "power-sub",
          protocol_version: 4,
          username: "addons",
          password: pass,
          handler: Collector,
          handler_state: %{pid: self()}
        )

      await(sub)
      {:ok, _} = MqttX.Client.subscribe(sub, "cmnd/plug1/Power", qos: 1)

      assert :ok = Vagus.Power.mqtt("cmnd/plug1/Power", "ON")
      assert_receive {:mqtt_message, ["cmnd", "plug1", "Power"], "ON"}, 2_000
    end
  end

  test "no broker service" do
    assert {:error, :no_broker} = Vagus.Power.mqtt("t", "p", service: fn -> :error end)
  end

  test "an unreachable broker is a connect error or times out" do
    creds = %{"port" => free_port(), "username" => "u", "password" => "p"}

    assert {:error, reason} =
             Vagus.Power.mqtt("t", "p",
               service: fn -> {:ok, "x", creds} end,
               timeout_ms: 500
             )

    assert reason == :timeout or match?({:connect, _}, reason)
  end

  defp await(client, tries \\ 80) do
    cond do
      MqttX.Client.connected?(client) -> :ok
      tries == 0 -> flunk("client never connected")
      true -> Process.sleep(25) && await(client, tries - 1)
    end
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
