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
  before its listener starts and hands it to both this and the broker's auth.

  The app process keeps neither entry across its own restart while the broker
  keeps running, so this monitors it and publishes again into the next one,
  retrying on `opts[:publish_retry]` (`{attempts, delay_ms}`) while it is not
  back. On `terminate/2` an app process that is down has nothing to withdraw:
  the next one starts empty. `opts[:withdraw_timeout]` (ms) bounds each of the
  two withdraw calls inside the child's shutdown timeout.
  """

  use GenServer

  require Logger

  alias Vagus.App

  @publish_retry {10, 100}
  @withdraw_timeout 1_000

  @service "mqtt"
  @user "addons"
  @state_file "broker_state.json"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The login this publishes, from the provider opts the broker is given."
  @spec service_login(keyword()) :: %{username: String.t(), password: String.t()}
  def service_login(opts) do
    %{username: @user, password: Keyword.get_lazy(opts, :password, fn -> password(opts) end)}
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
      push: Keyword.get(opts, :push, &Vagus.Discovery.Push.push/2),
      retry: retry,
      attempts: elem(retry, 0),
      ref: nil,
      uuid: nil,
      withdraw_timeout: Keyword.get(opts, :withdraw_timeout, @withdraw_timeout)
    }

    {:ok, publish(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
    {:noreply, publish(%{state | ref: nil, attempts: elem(state.retry, 0)})}
  end

  def handle_info(:publish, %{ref: nil} = state), do: {:noreply, publish(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{slug: slug, withdraw_timeout: timeout} = state) do
    _ = App.withdraw_service(slug, @service, timeout)

    case state.uuid && App.delete_discovery(slug, state.uuid, timeout) do
      {:ok, message} -> state.push.(:delete, message)
      _gone -> :ok
    end

    :ok
  end

  # The process found here may die at any step; its DOWN, or the retry when
  # it was never found, publishes everything again.
  defp publish(%{slug: slug, payload: payload} = state) do
    with {:ok, ref} <- App.monitor(slug),
         :ok <- provide(slug, payload),
         {:ok, message, outcome} <- App.add_discovery(slug, @service, payload) do
      announce(state, message, outcome)
      %{state | ref: ref, uuid: message.uuid}
    else
      failed -> retry(state, failed)
    end
  end

  # Another app providing `mqtt` too is upstream's refusal, not a reason to
  # stop the broker.
  defp provide(slug, payload) do
    case App.provide_service(slug, @service, payload) do
      {:error, :already_provided} -> :ok
      other -> other
    end
  end

  # Push only on `:new`/`:updated`: `:existing` is a record Core already has,
  # and pushing it again is the duplicate config flow the dedup prevents. A
  # new uuid after the app process restarted leaves the old one in Core
  # unless it is deleted there.
  defp announce(state, message, outcome) do
    if outcome != :existing, do: state.push.(:post, message)

    if state.uuid not in [nil, message.uuid],
      do: state.push.(:delete, %{message | uuid: state.uuid})
  end

  defp retry(%{attempts: attempts} = state, failed) when attempts > 1 do
    forget(failed)
    Process.send_after(self(), :publish, elem(state.retry, 1))
    %{state | attempts: attempts - 1}
  end

  defp retry(state, failed) do
    forget(failed)

    Logger.error(
      "Vagus.Mqtt.Broker.Provider: mqtt publish for #{state.slug} failed; " <>
        "the broker runs without its service and discovery"
    )

    state
  end

  # A monitor taken before a later step failed would deliver a second DOWN
  # for a process this is no longer publishing into.
  defp forget({:ok, ref}) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp forget(_failed), do: :ok

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
