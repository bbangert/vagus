defmodule Vagus.Power do
  @moduledoc """
  Publishes to the board's own MQTT broker so the orchestrator can switch
  Tasmota/Shelly smart plugs without a worker container.
  """

  alias Vagus.BoundedCall

  @default_timeout_ms 5_000
  @connected_poll_ms 25

  @spec mqtt(String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def mqtt(topic, payload, opts \\ []) do
    service = Keyword.get(opts, :service, fn -> Vagus.App.service("mqtt") end)

    case service.() do
      {:ok, _slug, creds} ->
        case BoundedCall.run(
               fn -> publish(creds, topic, payload, opts) end,
               Keyword.get(opts, :timeout_ms, @default_timeout_ms)
             ) do
          {:error, :attempt_timeout} -> {:error, :timeout}
          {:error, {:exit, reason}} -> {:error, {:connect, reason}}
          other -> other
        end

      :error ->
        {:error, :no_broker}
    end
  end

  defp publish(creds, topic, payload, opts) do
    # creds["host"] is the hassio bridge anchor (172.30.32.2) on a board, which
    # can be unbound this early; the broker listens on 0.0.0.0, so loopback
    # always works from the host. Only the port is taken from the service.
    connect_opts = [
      host: "127.0.0.1",
      port: creds["port"],
      client_id: "vagus-power-#{System.unique_integer([:positive])}",
      username: creds["username"],
      password: creds["password"],
      keepalive: 30
    ]

    with {:ok, client} <- connect(connect_opts) do
      try do
        case MqttX.Client.publish(client, topic, payload,
               qos: opts[:qos] || 1,
               retain: opts[:retain] || false
             ) do
          :ok -> :ok
          {:error, reason} -> {:error, {:publish, reason}}
        end
      after
        MqttX.Client.disconnect(client)
      end
    end
  end

  defp connect(connect_opts) do
    case MqttX.Client.connect(connect_opts) do
      {:ok, client} ->
        await_connected(client)

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  # connect/1 returns before the CONNACK; a publish on an unconnected client
  # would fail spuriously. The caller's BoundedCall deadline bounds this loop.
  defp await_connected(client) do
    if MqttX.Client.connected?(client) do
      {:ok, client}
    else
      Process.sleep(@connected_poll_ms)
      await_connected(client)
    end
  end
end
