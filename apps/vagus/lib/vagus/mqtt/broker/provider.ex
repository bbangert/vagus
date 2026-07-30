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
    3. adds the `mqtt` discovery message (`Vagus.Discovery`) — pushing it to
       Core via `Vagus.Discovery.Push` only when `Discovery.add/4` says the
       registry actually changed — exactly as a container add-on's
       `POST /discovery` does, so Core live-configures the MQTT integration
       instead of only noticing on its next boot-time `GET /discovery` pull. If
       Core isn't up yet (the broker boots ahead of it) the push is a no-op and
       Core's boot pull covers it.

  Idempotency across a broker **crash** (where `terminate` never ran and a
  previous uuid was left in `Vagus.Discovery`) no longer needs a manual
  clear-then-add here: `Discovery.add/4` dedups on `(slug, service)` itself
  (audit B3), so a fresh `init` for the same slug either finds the leftover
  entry's config unchanged (`:existing` — nothing to push, nothing
  duplicated) or changed (`:updated` — the *same* uuid is kept, `config` is
  replaced in place, and exactly one push goes out). Either way there is
  never more than one `mqtt` discovery for this slug, without this module
  having to delete anything first.

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

    publish_service(services, slug, payload)
    uuid = publish_discovery(discovery, slug, payload, push)

    {:ok, %{slug: slug, services: services, discovery: discovery, push: push, uuid: uuid}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if alive?(state.services),
      do: best_effort(fn -> Vagus.Services.delete(@service, state.slug, state.services) end)

    if state.uuid && alive?(state.discovery) do
      case best_effort(fn -> Vagus.Discovery.delete(state.uuid, state.slug, state.discovery) end) do
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
    if alive?(services),
      do: best_effort(fn -> Vagus.Services.set(@service, payload, slug, services) end)
  end

  defp publish_discovery(discovery, slug, payload, push) do
    if alive?(discovery) do
      # Discovery.add/4 is speced `{:ok, message(), outcome}`; `best_effort`
      # adds `:error` if the registry died mid-call, so match both. Push only
      # on `:new`/`:updated` — `:existing` means this exact (slug, service,
      # config) triple is already in Core, so pushing again would recreate
      # the duplicate the dedup exists to prevent (mirrors the router's
      # `POST /discovery`, audit B3).
      case best_effort(fn -> Vagus.Discovery.add(slug, @service, payload, discovery) end) do
        {:ok, %{uuid: uuid} = message, outcome} when outcome in [:new, :updated] ->
          push.(:post, message)
          uuid

        {:ok, %{uuid: uuid}, :existing} ->
          uuid

        _ ->
          nil
      end
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

  # Registry calls are best-effort in two layers: `alive?/1` skips a registry
  # that was never started (isolated tests), and this swallows an `:exit` should
  # the registry crash *between* that check and the call (the TOCTOU) — so a
  # registry blip never propagates out of the Provider and restarts the whole
  # broker subtree. Returns the fun's value, or `:error` on exit.
  defp best_effort(fun) do
    fun.()
  catch
    :exit, reason ->
      Logger.debug("Vagus.Mqtt.Broker.Provider: registry call skipped (exit #{inspect(reason)})")
      :error
  end
end
