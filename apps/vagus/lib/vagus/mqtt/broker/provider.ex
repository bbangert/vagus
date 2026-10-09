defmodule Vagus.Mqtt.Broker.Provider do
  @moduledoc """
  Publishes the native broker as the `mqtt` service and discovery of its own
  app process, the in-process equivalent of what Mosquitto's s6 scripts post
  on start. Started only when the broker runs as the real native app
  (`Vagus.Addon.Backend.Native` passes `:provider`); bare broker instances
  never publish.

  The `addons` password lives in `<data_dir>/broker_state.json`, so a hot
  backup carries it and a restore brings the same credentials back without a
  `backup_pre` script. `Vagus.Mqtt.Broker` reads it through `service_login/1`
  before its listener starts and hands it, in a closure, to both this and the
  broker's auth.

  The app process keeps neither entry across its own restart while the broker
  keeps running, so this monitors it and publishes again into the next one,
  retrying on `opts[:publish_retry]` (`{attempts, delay_ms}`) while it is not
  back, then every `opts[:publish_backoff_ms]` for as long as it takes: a
  native app always gets its service back. On `terminate/2` an app process that is down has nothing to withdraw:
  the next one starts empty. `opts[:withdraw_timeout]` (ms) bounds each of the
  two withdraw calls inside the child's shutdown timeout.
  """

  use GenServer

  require Logger

  alias Vagus.App
  alias Vagus.Discovery.Push

  @publish_retry {10, 100}
  @publish_backoff_ms 30_000
  @withdraw_timeout 1_000

  @service "mqtt"
  @user "addons"
  @state_file "broker_state.json"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The login this publishes: `opts[:service_login]`'s when given, else the
  persisted one, generated on first use.
  """
  @spec service_login(keyword()) :: %{username: String.t(), password: String.t()}
  def service_login(opts) do
    case Keyword.fetch(opts, :service_login) do
      {:ok, login} -> login.()
      :error -> %{username: @user, password: password(opts)}
    end
  end

  @impl GenServer
  def init(opts) do
    # Without it the supervisor's shutdown kills this outright and the
    # withdraw in `terminate/2` never runs, leaving Core a stale discovery.
    Process.flag(:trap_exit, true)

    slug = Keyword.fetch!(opts, :slug)
    login = service_login(opts)
    retry = Keyword.get(opts, :publish_retry, @publish_retry)

    state = %{
      slug: slug,
      payload: payload(Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :port), login),
      retry: retry,
      attempts: elem(retry, 0),
      backoff_ms: Keyword.get(opts, :publish_backoff_ms, @publish_backoff_ms),
      ref: nil,
      uuid: nil,
      withdraw_timeout: Keyword.get(opts, :withdraw_timeout, @withdraw_timeout)
    }

    # A continue: the publish talks to another tree and must not hold up the broker's start.
    {:ok, state, {:continue, :publish}}
  end

  @impl GenServer
  def handle_continue(:publish, state), do: {:noreply, publish(state)}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
    {:noreply, publish(%{state | ref: nil, attempts: elem(state.retry, 0)})}
  end

  def handle_info(:publish, %{ref: nil} = state), do: {:noreply, publish(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    Map.replace_lazy(status, :state, fn
      %{payload: _payload} = state -> %{state | payload: :redacted}
      state -> state
    end)
  end

  @impl GenServer
  def terminate(_reason, %{slug: slug, withdraw_timeout: timeout} = state) do
    _ = App.withdraw_service(slug, @service, timeout)

    if state.uuid, do: App.delete_discovery(slug, state.uuid, timeout)
    :ok
  end

  # The process found here may die at any step; its DOWN, or the retry when
  # it was never found, publishes everything again.
  defp publish(%{slug: slug} = state) do
    case App.monitor(slug) do
      {:ok, ref} ->
        case publish_into(state) do
          {:ok, message, _outcome} ->
            retire_old_uuid(state, message)

            if state.attempts == 0,
              do: Logger.info("Vagus.Mqtt.Broker.Provider: mqtt service published again")

            %{state | ref: ref, uuid: message.uuid, attempts: elem(state.retry, 0)}

          _failed ->
            # Else every retry would leave one more monitor, each a later DOWN.
            Process.demonitor(ref, [:flush])
            retry(state)
        end

      :absent ->
        retry(state)
    end
  end

  defp publish_into(%{slug: slug, payload: payload} = state) do
    with :ok <- provide(state),
         do: App.add_discovery(slug, @service, payload)
  end

  # The key already held by this app is its own earlier post; held by another
  # app, the broker runs without the service until that app lets it go.
  defp provide(%{slug: slug, payload: payload} = state) do
    with {:error, :already_provided} <- App.provide_service(slug, @service, payload) do
      case List.keyfind(App.services(), @service, 0) do
        {@service, ^slug} ->
          :ok

        {@service, owner} ->
          if state.attempts > 0 do
            Logger.error(
              "Vagus.Mqtt.Broker.Provider: the mqtt service is provided by app #{owner}, " <>
                "not by #{slug}"
            )
          end

          {:error, {:provided_by, owner}}

        # Withdrawn since the refusal.
        nil ->
          {:error, :already_provided}
      end
    end
  end

  # The app process queued the new uuid's POST before replying, so this DELETE
  # queues behind it. The old uuid's process is gone and cannot push it, and
  # Core would keep its flow beside the new one.
  defp retire_old_uuid(state, message) do
    if state.uuid not in [nil, message.uuid],
      do: Push.notify(:delete, %{message | uuid: state.uuid})
  end

  defp retry(%{attempts: attempts} = state) when attempts > 1 do
    Process.send_after(self(), :publish, elem(state.retry, 1))
    %{state | attempts: attempts - 1}
  end

  # `attempts: 0` marks the slow cadence, so the error is logged once per outage.
  defp retry(state) do
    if state.attempts == 1 do
      Logger.error(
        "Vagus.Mqtt.Broker.Provider: mqtt publish for #{state.slug} failed; " <>
          "the broker runs without its service and discovery until it succeeds"
      )
    end

    Process.send_after(self(), :publish, state.backoff_ms)
    %{state | attempts: 0}
  end

  defp payload(host, port, login) do
    %{
      "host" => host,
      "port" => port,
      "ssl" => false,
      "protocol" => "3.1.1",
      "username" => login.username,
      "password" => login.password
    }
  end

  defp password(opts) do
    data_dir = Keyword.get_lazy(opts, :data_dir, fn -> data_dir(Keyword.fetch!(opts, :slug)) end)
    load_or_generate_password(data_dir)
  end

  # path is internal/config-derived (`:addon_data_root` + a constant filename),
  # not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp load_or_generate_password(data_dir) do
    path = Path.join(data_dir, @state_file)

    with {:ok, json} <- File.read(path),
         {:ok, %{"addons_password" => p}} when is_binary(p) and p != "" <- Jason.decode(json) do
      p
    else
      _ -> generate_and_persist(path)
    end
  end

  # path is internal/config-derived (`:addon_data_root` + a constant filename),
  # not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp generate_and_persist(path) do
    password = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    _ = File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(%{"addons_password" => password})) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Vagus.Mqtt.Broker.Provider: could not persist broker state: #{inspect(reason)}"
        )
    end

    password
  end

  defp data_dir(slug) do
    root = Application.get_env(:vagus, :addon_data_root, "/data")
    Path.join([root, "addons", "data", slug])
  end
end
