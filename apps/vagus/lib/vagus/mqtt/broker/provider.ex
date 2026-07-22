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
    3. adds the `mqtt` discovery message (`Vagus.Discovery`) **and pushes it to
       Core** via `Vagus.Discovery.Push`, exactly as a container add-on's
       `POST /discovery` does — so Core live-configures the MQTT integration
       instead of only noticing on its next boot-time `GET /discovery` pull. If
       Core isn't up yet (the broker boots ahead of it) the push is a no-op and
       Core's boot pull covers it.

  To stay idempotent across a broker **crash** (where `terminate` never ran and
  a previous uuid was left orphaned in `Vagus.Discovery` and in Core), init
  first clears any `mqtt` discovery still owned by this slug — pushing a delete
  for each — before adding the fresh one, so Core always ends up with exactly
  one entry rather than a duplicate.

  On `terminate` it deregisters the service and discovery (pushing the discovery
  delete to Core), so both follow broker liveness. Registry calls are
  best-effort — a missing registry (isolated test) is not fatal.
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
    # Trap exits so `terminate/2` runs when the broker subtree is shut down
    # (e.g. the add-on is stopped/uninstalled) — without it a plain GenServer is
    # killed on the supervisor's shutdown signal and the service/discovery
    # deregister below never fires, leaving a stale `mqtt` service + a stale
    # discovery in Core.
    Process.flag(:trap_exit, true)

    slug = Keyword.fetch!(opts, :slug)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    services = Keyword.get(opts, :services, Vagus.Services)
    discovery = Keyword.get(opts, :discovery, Vagus.Discovery)
    push = Keyword.get(opts, :push, &Vagus.Discovery.Push.push/2)
    data_dir = Keyword.get(opts, :data_dir, data_dir(slug))

    password = load_or_generate_password(data_dir)
    payload = service_payload(host, port, password)

    # A prior broker instance that crashed (no terminate) may have left an mqtt
    # discovery orphaned here + in Core. Clear it first so we never publish a
    # duplicate.
    clear_stale_discovery(discovery, slug, push)

    publish_service(services, slug, payload)
    uuid = publish_discovery(discovery, slug, payload, push)

    {:ok, %{slug: slug, services: services, discovery: discovery, push: push, uuid: uuid}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if alive?(state.services), do: Vagus.Services.delete(@service, state.slug, state.services)

    if state.uuid && alive?(state.discovery) do
      case Vagus.Discovery.delete(state.uuid, state.slug, state.discovery) do
        {:ok, message} -> state.push.(:delete, message)
        _ -> :ok
      end
    end

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

  defp publish_discovery(discovery, slug, payload, push) do
    if alive?(discovery) do
      # Discovery.add/4 is speced `{:ok, message()}` — match it directly.
      {:ok, %{uuid: uuid} = message} = Vagus.Discovery.add(slug, @service, payload, discovery)
      push.(:post, message)
      uuid
    end
  end

  # Push a delete for any mqtt discovery this slug still owns from a prior
  # (crashed) broker instance, so a fresh publish never duplicates it in Core.
  defp clear_stale_discovery(discovery, slug, push) do
    if alive?(discovery) do
      {:ok, removed} = Vagus.Discovery.delete_by_slug(slug, discovery)
      Enum.each(removed, &push.(:delete, &1))
    end
  end

  # Persist the addons password so it's stable across broker restarts AND
  # survives a backup/restore round-trip (the file rides along in the data dir).
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

  defp alive?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp alive?(server) when is_pid(server), do: Process.alive?(server)
end
