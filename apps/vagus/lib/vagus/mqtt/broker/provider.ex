defmodule Vagus.Mqtt.Broker.Provider do
  @moduledoc """
  Publishes the native broker as the `mqtt` service + discovery (M5, MQ-P4-T1),
  the in-process equivalent of what Mosquitto's s6 scripts do on start.

  Started as a child of the `Vagus.Mqtt.Broker` subtree **only when the broker is
  run as the real native add-on** (`Vagus.Addon.Backend.Native` passes a
  `:provider` config); bare broker instances (the routing/auth unit tests) omit
  it and never touch the global service/discovery registries. On `init` it:

    1. loads (or generates + persists) the `addons` service password in
       `<data_dir>/broker_state.json` — the broker's snapshot-able state. Because
       that file lives in the add-on's data dir it is included in a hot backup
       automatically and staged back on restore, so the same credentials survive
       backup → uninstall → reinstall → restore (MQ-P4-T2) with no `backup_pre`
       script to run;
    2. registers the `mqtt` service (`Vagus.Services`) — `host` = the advertised
       broker IP, `port`, `protocol: "3.1.1"`, `username: "addons"`, `password`.
       `Vagus.Mqtt.Broker.Auth`'s service-credentials path reads the same entry,
       so an add-on connecting as `addons`/`<password>` authenticates;
    3. adds the `mqtt` discovery message (`Vagus.Discovery`).

  On `terminate` it deregisters both, so the service/discovery follow broker
  liveness. Registry calls are best-effort — a missing registry (isolated test)
  is not fatal.
  """

  use GenServer

  require Logger

  @service "mqtt"
  @user "addons"
  @state_file "broker_state.json"

  @doc "Starts the provider. Required opts: `:slug`, `:host`, `:port`. See moduledoc."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    slug = Keyword.fetch!(opts, :slug)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    services = Keyword.get(opts, :services, Vagus.Services)
    discovery = Keyword.get(opts, :discovery, Vagus.Discovery)
    data_dir = Keyword.get(opts, :data_dir, data_dir(slug))

    password = load_or_generate_password(data_dir)
    payload = service_payload(host, port, password)

    publish_service(services, slug, payload)
    uuid = publish_discovery(discovery, slug, payload)

    {:ok, %{slug: slug, services: services, discovery: discovery, uuid: uuid}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if alive?(state.services), do: Vagus.Services.delete(@service, state.slug, state.services)

    if state.uuid && alive?(state.discovery),
      do: Vagus.Discovery.delete(state.uuid, state.slug, state.discovery)

    :ok
  end

  ## Internals

  defp service_payload(host, port, password) do
    %{
      "host" => host,
      "port" => port,
      "ssl" => false,
      "protocol" => "3.1.1",
      "username" => @user,
      "password" => password
    }
  end

  defp publish_service(services, slug, payload) do
    if alive?(services), do: Vagus.Services.set(@service, payload, slug, services)
  end

  defp publish_discovery(discovery, slug, payload) do
    if alive?(discovery) do
      # Discovery.add/4 is speced `{:ok, message()}` — match it directly.
      {:ok, %{uuid: uuid}} = Vagus.Discovery.add(slug, @service, payload, discovery)
      uuid
    end
  end

  # Persist the addons password so it's stable across broker restarts AND
  # survives a backup/restore round-trip (the file rides along in the data dir).
  defp load_or_generate_password(data_dir) do
    path = Path.join(data_dir, @state_file)

    with {:ok, json} <- File.read(path),
         {:ok, %{"addons_password" => p}} when is_binary(p) and p != "" <- Jason.decode(json) do
      p
    else
      _ -> generate_and_persist(path)
    end
  end

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

  defp alive?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp alive?(server) when is_pid(server), do: Process.alive?(server)
end
