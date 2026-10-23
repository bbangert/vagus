defmodule Vagus.Power do
  @moduledoc """
  Publishes to the board's own MQTT broker so the orchestrator can switch
  Tasmota/Shelly smart plugs without a worker container.
  """

  alias Vagus.BoundedCall

  @default_timeout_ms 5_000

  defmodule Notifier do
    @moduledoc false
    # Runs in the MqttX connection process, so the CONNACK reaches the
    # waiting caller as a message instead of being polled for.
    def handle_mqtt_event(:connected, _data, {pid, ref} = state) do
      send(pid, {ref, :connected})
      state
    end

    def handle_mqtt_event(_event, _data, state), do: state
  end

  @type reason :: atom() | {:raised, module()}

  @doc """
  `:ok` means the PUBLISH was written to the socket, not that the broker
  acknowledged it: `MqttX.Client.publish/4` replies before the PUBACK and
  offers no ack-aware variant, so QoS 1 only buys broker-side redelivery.

  Error reasons never carry connect options (the broker password): library
  reasons are reduced to an atom or the exception module.
  """
  @spec mqtt(String.t(), iodata(), keyword()) ::
          :ok
          | {:error,
             :no_broker | :timeout | :crashed | {:connect, reason()} | {:publish, reason()}}
  def mqtt(topic, payload, opts \\ []) do
    service = Keyword.get(opts, :service, fn -> Vagus.App.service("mqtt") end)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case BoundedCall.run(fn -> run(service, topic, payload, opts, timeout) end, timeout) do
      {:error, :attempt_timeout} -> {:error, :timeout}
      # Only a crash of the linked connection process lands here; its exit
      # reason can embed the connection state, password included.
      {:error, {:exit, _reason}} -> {:error, :crashed}
      other -> other
    end
  end

  # The phase deadlines expire inside the outer bound so the caller learns
  # which phase stalled; the remaining fifth covers the service lookup and
  # the disconnect.
  defp run(service, topic, payload, opts, timeout) do
    case service.() do
      {:ok, _slug, creds} ->
        with {:ok, client} <- connect(creds, div(timeout * 3, 5)) do
          result = publish(client, topic, payload, opts, div(timeout, 5))
          close(client, result)
          result
        end

      :error ->
        {:error, :no_broker}
    end
  end

  defp connect(creds, deadline_ms) do
    ref = make_ref()
    # MqttX only calls a handler that function_exported?/3 sees, which is
    # false for a module the code server has not loaded yet.
    Code.ensure_loaded!(Notifier)

    # creds["host"] is the hassio bridge anchor (172.30.32.2) on a board, which
    # can be unbound this early; the broker listens on 0.0.0.0, so loopback
    # always works from the host. Only the port is taken from the service.
    connect_opts = [
      host: "127.0.0.1",
      port: creds["port"],
      client_id: "vagus-power-#{System.unique_integer([:positive])}",
      username: creds["username"],
      password: creds["password"],
      keepalive: 30,
      handler: Notifier,
      handler_state: {self(), ref}
    ]

    case guard(fn -> MqttX.Client.connect(connect_opts) end) do
      {:ok, client} ->
        # connect/1 returns before the TCP connect and retries a refused or
        # rejected attempt forever, so the CONNACK event is the only signal.
        receive do
          {^ref, :connected} -> {:ok, client}
        after
          deadline_ms ->
            close(client, :unconnected)
            {:error, {:connect, :timeout}}
        end

      {:error, reason} ->
        {:error, {:connect, redact(reason)}}
    end
  end

  defp publish(client, topic, payload, opts, deadline_ms) do
    publish_opts = [qos: opts[:qos] || 1, retain: opts[:retain] || false]

    case BoundedCall.run(
           fn ->
             MqttX.Client.publish(client, topic, IO.iodata_to_binary(payload), publish_opts)
           end,
           deadline_ms
         ) do
      :ok -> :ok
      {:error, :attempt_timeout} -> {:error, {:publish, :timeout}}
      {:error, {:exit, reason}} -> {:error, {:publish, redact(reason)}}
      {:error, reason} -> {:error, {:publish, redact(reason)}}
    end
  end

  # disconnect/1 is a cast that writes DISCONNECT unconditionally, which
  # crashes a client whose socket is gone and logs its state, password
  # included; it is only sent after a publish proved the socket live. Any
  # other client may be blocked in its own TCP connect (connected?/1 would
  # block with it), so it is killed, unlinked first so the kill does not
  # take this process along.
  defp close(client, :ok), do: MqttX.Client.disconnect(client)

  defp close(client, _not_ok) do
    Process.unlink(client)
    Process.exit(client, :kill)
  end

  defp guard(fun) do
    fun.()
  catch
    :error, error -> {:error, error}
    :exit, reason -> {:error, reason}
  end

  defp redact(reason) when is_atom(reason), do: reason
  defp redact(%{__exception__: true} = e), do: {:raised, e.__struct__}
  defp redact({%{__exception__: true} = e, _stack}), do: {:raised, e.__struct__}
  defp redact({:timeout, _call}), do: :timeout
  defp redact({:noproc, _call}), do: :noproc
  defp redact({reason, _detail}) when is_atom(reason), do: reason
  defp redact(_reason), do: :redacted
end
