defmodule Vagus.API.Router do
  @moduledoc """
  The Supervisor-API emulator's HTTP surface.

  Pipeline order: body parsing, then `Vagus.API.Auth` (no exempt routes —
  every request, including ones that end up 404ing, must authenticate),
  then routing. Every response — success, honest no-op, honest error, the
  catch-all 404, or an exception raised anywhere in the pipeline (`use
  Plug.ErrorHandler`, `handle_errors/2` below) — goes out through
  `Vagus.API.Envelope` so a bare/default Plug response never leaks through
  unwrapped.

  Endpoints cover the green surface Home Assistant Core's `hassio`
  integration actually calls (`docs/contract-2026.7.md` §3): the main/
  addon/stats coordinators' polled GETs, the one-time entry-setup calls
  (`supervisor/ping`, `core/options`, `supervisor/options`), and the
  non-scheduled-refresh extras (`reload_updates`, `store/reload`), plus
  (P4) the non-polled network-interface/host-action routes. Most response
  data still comes from the plain-function `Vagus.API.StaticData` seam;
  `os/info`, `host/info`, `network/info`, and the network-interface/host
  routes instead call through `Vagus.Backend` (`network/0`, `host/0`,
  `os/0`) to a real host-management backend — see that module and
  `Vagus.Backend.{Network,Host,OS}` for the behaviours/selection.
  """

  use Plug.Router
  use Plug.ErrorHandler

  require Logger

  alias Vagus.API.{Envelope, StaticData}
  alias Vagus.Backend
  alias Vagus.Core.TokenStore
  alias Vagus.Discovery
  alias Vagus.Services

  alias Vagus.API.Models.{
    AccessPoint,
    AccessPointList,
    AddonsList,
    AvailableUpdates,
    CoreStats,
    HomeAssistantInfo,
    HostInfo,
    JobsInfo,
    MountsInfo,
    NetworkInfo,
    NetworkInterface,
    OSInfo,
    ResolutionInfo,
    RootInfo,
    StoreInfo,
    SupervisorInfo
  }

  # Supervisor-API payloads are all tiny (options posts, network configure);
  # `Plug.Parsers`' 8MB default would let an unauthenticated caller (auth
  # runs after parsing) pressure a 1GB device's memory just by posting a
  # huge body.
  #
  # `pass: ["*/*"]` so a body whose content-type has no parser is skipped,
  # not rejected with 415. Core's Supervisor client (`aiohasupervisor` via
  # aiohttp) sends bodyless action POSTs — e.g. `supervisor/update` during
  # entry setup while not yet onboarded — with `Content-Type:
  # application/octet-stream, Content-Length: 0`. Without a pass-through the
  # parser 415s before routing, and `aiohasupervisor` maps the non-400 to a
  # generic error, so `hassio` never sees the route's honest 400 ("no update
  # available") and wedges in ConfigEntryNotReady. The real Supervisor
  # (aiohttp server) tolerates these, so we must too.
  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 65_536
  )

  plug(Vagus.API.Auth)
  plug(:match)
  plug(:dispatch)

  # `Plug.Parsers.ParseError` (malformed JSON body) gets its own honest
  # message; anything else falls back to the status `Plug.ErrorHandler`
  # already resolved onto `conn` (`Plug.Exception.status/1`, defaulting to
  # 500) with a generic message — never a bare Plug-rendered error body.
  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}) do
    Envelope.send_error(conn, "invalid JSON body", 400)
  end

  def handle_errors(conn, %{reason: _reason}) do
    Envelope.send_error(conn, "internal server error", conn.status || 500)
  end

  # -- Main coordinator (5 min) + one-time setup GETs -----------------------

  get "/info" do
    Envelope.send_ok(conn, RootInfo.build!(StaticData.root_info()))
  end

  get "/supervisor/info" do
    Envelope.send_ok(conn, SupervisorInfo.build!(StaticData.supervisor_info()))
  end

  get "/core/info" do
    Envelope.send_ok(conn, HomeAssistantInfo.build!(StaticData.core_info()))
  end

  get "/os/info" do
    Envelope.send_ok(conn, OSInfo.build!(Backend.os().info()))
  end

  get "/host/info" do
    Envelope.send_ok(conn, HostInfo.build!(Backend.host().info()))
  end

  get "/network/info" do
    Envelope.send_ok(conn, NetworkInfo.build!(Backend.network().info()))
  end

  # -- Network per-interface (P4-T3, not in the polled green surface —
  # frontend-triggered network settings pages) ------------------------------

  get "/network/interface/:ifname/info" do
    case Backend.network().interface_info(ifname) do
      {:ok, attrs} -> Envelope.send_ok(conn, NetworkInterface.build!(attrs))
      {:error, message} -> Envelope.send_error(conn, message, 400)
    end
  end

  get "/network/interface/:ifname/accesspoints" do
    case Backend.network().access_points(ifname) do
      {:ok, access_points} ->
        attrs = %{accesspoints: Enum.map(access_points, &AccessPoint.build!/1)}
        Envelope.send_ok(conn, AccessPointList.build!(attrs))

      {:error, message} ->
        Envelope.send_error(conn, message, 400)
    end
  end

  post "/network/interface/:ifname/update" do
    case Backend.network().configure(ifname, conn.body_params) do
      :ok -> Envelope.send_ok(conn, %{})
      {:error, message} -> Envelope.send_error(conn, message, 400)
    end
  end

  # -- Host actions (P4-T4) --------------------------------------------------
  #
  # The ok envelope is sent BEFORE the actual reboot/shutdown call — Core
  # expects the HTTP response before the box goes down. `Task.start/1`
  # decouples the side effect from this request's process entirely (rather
  # than calling it inline right after `send_ok`) so a real target reboot,
  # which may never return, can't be mistaken for blocking the response.
  post "/host/reboot" do
    conn = Envelope.send_ok(conn, %{})
    Task.start(fn -> run_host_action(:reboot, fn -> Backend.host().reboot() end) end)
    conn
  end

  post "/host/shutdown" do
    conn = Envelope.send_ok(conn, %{})
    Task.start(fn -> run_host_action(:shutdown, fn -> Backend.host().shutdown() end) end)
    conn
  end

  # Wire path is "store", NOT "/store/info" (§3, §20).
  get "/store" do
    Envelope.send_ok(conn, StoreInfo.build!(StaticData.store_info()))
  end

  # Wire path is "mounts", NOT "/mounts/info" (§3, §20).
  get "/mounts" do
    Envelope.send_ok(conn, MountsInfo.build!(StaticData.mounts_info()))
  end

  # Not polled on a timer by Core's coordinator (populated once at entry
  # setup via SupervisorIssues.async_update(), then kept current by WS
  # events) — still a real GET route, implemented the same way.
  get "/resolution/info" do
    Envelope.send_ok(conn, ResolutionInfo.build!(StaticData.resolution_info()))
  end

  get "/jobs/info" do
    Envelope.send_ok(conn, JobsInfo.build!(StaticData.jobs_info()))
  end

  # -- Addon coordinator (15 min) -------------------------------------------

  get "/addons" do
    Envelope.send_ok(conn, AddonsList.build!(StaticData.addons_list()))
  end

  # An add-on reads its own effective (merged + schema-validated) options
  # (§A3.4 / `supervisor/api/apps.py` `options_config`) — bashio's
  # `bashio::config`/`bashio::addon.config` fetch this once and cache it. Only
  # `self` is permitted (the real handler 403s any other slug); `self` resolves
  # to the calling add-on. The effective options are exactly what
  # `Manager.start` wrote to that add-on's `/data/options.json`.
  get "/addons/:slug/options/config" do
    cond do
      slug != "self" ->
        Envelope.send_error(conn, "This can be only read by the app itself!", 403)

      match?({:addon, _}, conn.assigns.caller) ->
        {:addon, %{slug: caller_slug}} = conn.assigns.caller

        case read_addon_options(caller_slug) do
          {:ok, options} -> Envelope.send_ok(conn, options)
          :error -> Envelope.send_error(conn, "Invalid configuration data for the app", 400)
        end

      true ->
        Envelope.send_error(conn, "Self is not an App", 400)
    end
  end

  # -- Stats coordinator (60s) -----------------------------------------------

  get "/core/stats" do
    Envelope.send_ok(conn, CoreStats.build!(StaticData.core_stats()))
  end

  get "/supervisor/stats" do
    Envelope.send_ok(conn, CoreStats.build!(StaticData.core_stats()))
  end

  # Not called by the hassio integration's coordinator in this Core
  # version, but still a real route (e.g. the frontend's supervisor/api WS
  # passthrough) — implemented as a valid, idle response (§8, §21).
  get "/available_updates" do
    Envelope.send_ok(conn, AvailableUpdates.build!(StaticData.available_updates()))
  end

  # Polled by hassio's addon_panel setup at every Core boot (observed on
  # device 2026-07-20: 404 here logs "Can't read panel info: not found").
  # Raw-dict path in Core (no aiohasupervisor model) — `data["panels"]` is a
  # map of addon-slug → panel config; honestly empty with no add-ons.
  get "/ingress/panels" do
    Envelope.send_ok(conn, %{panels: %{}})
  end

  # -- Discovery registry (§A3.2) --------------------------------------------
  # An add-on publishes a discovery message (POST) for a service it declares
  # in its config.yaml `discovery:` list; Supervisor mints a uuid, stores it,
  # and pushes the message (minus `config`) to Core, which re-fetches the full
  # record here and drives a config flow. Core reads the list at every boot
  # (`@require_home_assistant` → the supervisor token); add-ons only write.

  get "/discovery" do
    if home_assistant?(conn.assigns.caller) do
      messages = Discovery.list()

      services =
        messages
        |> Enum.group_by(& &1.service, & &1.addon)
        |> Map.new(fn {service, slugs} -> {service, Enum.uniq(slugs)} end)

      Envelope.send_ok(conn, %{
        discovery: Enum.map(messages, &discovery_view/1),
        services: services
      })
    else
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  get "/discovery/:uuid" do
    if home_assistant?(conn.assigns.caller) do
      case Discovery.get(uuid) do
        {:ok, message} -> Envelope.send_ok(conn, discovery_view(message))
        :error -> Envelope.send_error(conn, "Discovery message not found", 404)
      end
    else
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  post "/discovery" do
    with {:addon, %{slug: slug, discovery: declared}} <- conn.assigns.caller,
         {:ok, service, config} <- validate_discovery(conn.body_params),
         true <- service in declared do
      {:ok, message} = Discovery.add(slug, service, config)
      push_discovery(:post, message)
      Envelope.send_ok(conn, %{uuid: message.uuid})
    else
      {:error, message} -> Envelope.send_error(conn, message, 400)
      # A non-add-on caller, or an add-on that didn't declare the service.
      _ -> Envelope.send_error(conn, "Caller may not provide this discovery", 403)
    end
  end

  delete "/discovery/:uuid" do
    case conn.assigns.caller do
      {:addon, %{slug: slug}} ->
        case Discovery.delete(uuid, slug) do
          {:ok, message} ->
            push_discovery(:delete, message)
            Envelope.send_ok(conn, %{})

          {:error, :not_found} ->
            Envelope.send_error(conn, "Discovery message not found", 404)

          {:error, :not_owner} ->
            Envelope.send_error(conn, "Caller does not own this discovery", 403)
        end

      _ ->
        Envelope.send_error(conn, "Caller may not delete discovery", 403)
    end
  end

  # Polled by Core's backup integration ("hassio.local" agent — observed on
  # device 2026-07-20: 404 logs "Unexpected error for hassio.local: not
  # found"). aiohasupervisor `BackupList` requires only `backups`;
  # `GET /backups/info` (`BackupsInfo`) additionally requires
  # `days_until_stale` (Supervisor default: 30). Honestly empty — backups
  # are out of this slug's scope.
  get "/backups" do
    Envelope.send_ok(conn, %{backups: []})
  end

  get "/backups/info" do
    Envelope.send_ok(conn, %{backups: [], days_until_stale: 30})
  end

  # -- Add-on service registry (§A3.1) ---------------------------------------
  # An add-on that provides a service (e.g. Mosquitto → mqtt) publishes its
  # connection config; Core/other add-ons read it. Access is by the caller's
  # `services_role` grant (from its config.yaml `services:`).

  get "/services" do
    Envelope.send_ok(conn, %{services: Services.list()})
  end

  post "/services/:service" do
    if provider?(conn.assigns.caller, service) do
      case validate_service(service, conn.body_params) do
        {:ok, data} ->
          case Services.set(service, data, addon_slug(conn.assigns.caller)) do
            :ok ->
              Envelope.send_ok(conn, %{})

            {:error, :already_provided} ->
              Envelope.send_error(conn, "Service already provided", 400)
          end

        {:error, message} ->
          Envelope.send_error(conn, message, 400)
      end
    else
      Envelope.send_error(conn, "Caller may not provide '#{service}'", 403)
    end
  end

  get "/services/:service" do
    if service_reader?(conn.assigns.caller, service) do
      case Services.get(service) do
        {:ok, data} -> Envelope.send_ok(conn, data)
        :error -> Envelope.send_error(conn, "Service not enabled", 400)
      end
    else
      Envelope.send_error(conn, "Caller not authorized for '#{service}'", 403)
    end
  end

  delete "/services/:service" do
    if provider?(conn.assigns.caller, service) do
      Services.delete(service, addon_slug(conn.assigns.caller))
      Envelope.send_ok(conn, %{})
    else
      Envelope.send_error(conn, "Caller may not delete '#{service}'", 403)
    end
  end

  # -- Add-on auth API (§A3.3) -----------------------------------------------
  # A provider add-on with `auth_api: true` (e.g. Mosquitto's NGINX) validates
  # an external client's HA username/password. Credentials arrive as Basic
  # header, JSON, or form body (in that order); the add-on itself authenticates
  # via `X-Supervisor-Token` (so the `Authorization` header is free for Basic).
  # Success → 200; failure → 401 + `WWW-Authenticate`.

  get "/auth" do
    handle_auth(conn)
  end

  post "/auth" do
    handle_auth(conn)
  end

  delete "/auth/cache" do
    if match?({:addon, %{auth_api: true}}, conn.assigns.caller) do
      :ok = Vagus.Auth.reset_cache()
      Envelope.send_ok(conn, %{})
    else
      Envelope.send_error(conn, "Caller is not allowed to access the auth API", 403)
    end
  end

  # -- Entry setup (once) ----------------------------------------------------

  get "/supervisor/ping" do
    Envelope.send_ok(conn, %{})
  end

  # Wire path is "core/options", NOT "homeassistant/options" (§5) — fired
  # at every entry setup with {ssl, port, refresh_token}, most importantly
  # the Supervisor-user refresh token (§5) EventPusher/Client need. "/homeassistant/options"
  # is also registered (P3-T1) in case a client posts to the aiohasupervisor
  # attribute-name path instead — Core 2026.7.2 itself always posts to
  # "core/options", but both routes persist identically via
  # Vagus.Core.TokenStore. Accepted fields are whitelisted against contract
  # §22 (Vagus.Core.TokenStore.accepted_fields/0); anything else is ignored.
  # Always an ok envelope, whether or not refresh_token is present (an
  # options-only call, e.g. ssl/port with no token change, is valid).
  post "/core/options" do
    handle_core_options(conn)
  end

  post "/homeassistant/options" do
    handle_core_options(conn)
  end

  post "/supervisor/options" do
    Envelope.send_ok(conn, %{})
  end

  # -- Honest no-ops (accepted, do nothing) -----------------------------------

  post "/supervisor/reload" do
    Envelope.send_ok(conn, %{})
  end

  post "/refresh_updates" do
    Envelope.send_ok(conn, %{})
  end

  post "/reload_updates" do
    Envelope.send_ok(conn, %{})
  end

  # Fired by the addon coordinator on non-scheduled refreshes, before
  # re-listing addons (§3).
  post "/store/reload" do
    Envelope.send_ok(conn, %{})
  end

  # -- Honest errors: genuinely not supported by this emulator yet -----------

  post "/supervisor/restart" do
    Envelope.send_error(conn, "supervisor/restart is not supported yet", 400)
  end

  post "/supervisor/update" do
    Envelope.send_error(conn, "supervisor/update is not supported yet", 400)
  end

  match _ do
    Envelope.send_error(conn, "not found", 404)
  end

  defp handle_core_options(conn) do
    :ok = TokenStore.put_options(conn.body_params)
    Envelope.send_ok(conn, %{})
  end

  # The response has already gone out by the time this runs (see the
  # moduledoc above the reboot/shutdown routes) — a failed backend call has
  # nowhere left to report to but the log, and since it's running inside a
  # bare `Task.start/1` an uncaught exception would otherwise just crash
  # that throwaway process silently instead of being visible in RingLogger.
  defp run_host_action(action, backend_call) do
    backend_call.()
  rescue
    exception ->
      Logger.error(
        "Vagus.API.Router: host/#{action} backend call failed:\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
  end

  # -- discovery helpers -----------------------------------------------------

  # The V1 single/list message shape Core's hassio discovery reads.
  defp discovery_view(%{uuid: uuid, addon: addon, service: service, config: config}) do
    %{addon: addon, service: service, uuid: uuid, config: config}
  end

  # POST /discovery body `SCHEMA_DISCOVERY`: {service(req str), config(req dict)}.
  defp validate_discovery(params) when is_map(params) do
    with {:ok, service} <- require_string(params, "service"),
         config when is_map(config) <- Map.get(params, "config") do
      {:ok, service, config}
    else
      _ -> {:error, "config is required and must be an object"}
    end
  end

  defp validate_discovery(_params), do: {:error, "invalid discovery body"}

  # Fire-and-forget push to Core `POST|DELETE api/hassio_push/discovery/{uuid}`
  # with the message minus `config` (`app`→`addon`), only meaningful once Core
  # is reachable — `Vagus.Core.Client.request` returns `{:error,
  # :no_refresh_token}` until the handshake has happened, which is exactly the
  # `check_api_state()` gate. Decoupled via `Task.start/1` so the add-on's
  # response never waits on a Core round-trip; failures are logged only.
  defp push_discovery(method, %{uuid: uuid, addon: addon, service: service}) do
    body = Jason.encode!(%{"addon" => addon, "service" => service, "uuid" => uuid})

    Task.start(fn ->
      case Vagus.Core.Client.request(method, "/api/hassio_push/discovery/#{uuid}",
             headers: [{"content-type", "application/json"}],
             body: body
           ) do
        {:ok, _response} ->
          :ok

        {:error, :no_refresh_token} ->
          Logger.debug("Vagus.API.Router: discovery #{method} not pushed — Core not connected")

        {:error, reason} ->
          Logger.warning(
            "Vagus.API.Router: discovery #{method} push for #{uuid} failed: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  # -- addon self-config helper ----------------------------------------------

  # Reads the effective options `Manager.start` wrote to the add-on's
  # `/data/options.json` (data root from `config :vagus, :addon_data_root`).
  defp read_addon_options(slug) do
    path =
      Path.join([
        Application.get_env(:vagus, :addon_data_root, "/data"),
        "addons",
        "data",
        slug,
        "options.json"
      ])

    with {:ok, bin} <- File.read(path),
         {:ok, options} when is_map(options) <- Jason.decode(bin) do
      {:ok, options}
    else
      _ -> :error
    end
  end

  # -- auth helpers ----------------------------------------------------------

  defp handle_auth(conn) do
    case conn.assigns.caller do
      {:addon, %{auth_api: true, slug: slug}} ->
        case extract_credentials(conn) do
          {:ok, username, password} ->
            if Vagus.Auth.check_login(username, password, slug) do
              Envelope.send_ok(conn, %{})
            else
              unauthorized_basic(conn)
            end

          :error ->
            unauthorized_basic(conn)
        end

      _ ->
        Envelope.send_error(conn, "Caller is not allowed to access the auth API", 403)
    end
  end

  # Credential channels in order: Basic header, then JSON/form body
  # (`username` or its alias `user`, plus `password`).
  defp extract_credentials(conn) do
    case basic_credentials(conn) do
      {:ok, _username, _password} = ok ->
        ok

      :error ->
        params = conn.body_params
        username = params["username"] || params["user"]
        password = params["password"]

        if is_binary(username) and is_binary(password),
          do: {:ok, username, password},
          else: :error
    end
  end

  defp basic_credentials(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [username, password] <- String.split(decoded, ":", parts: 2) do
      {:ok, username, password}
    else
      _ -> :error
    end
  end

  defp unauthorized_basic(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Home Assistant Authentication"))
    |> Envelope.send_error("Invalid authentication", 401)
  end

  # -- caller/grant helpers (see Vagus.API.Auth for how :caller is assigned) --

  defp addon_slug({:addon, %{slug: slug}}), do: slug
  defp addon_slug(_), do: nil

  # Discovery reads are Core-only (`@require_home_assistant`): Core polls with
  # the supervisor token, resolved to `:supervisor` by `Vagus.API.Auth`.
  defp home_assistant?(:supervisor), do: true
  defp home_assistant?(_caller), do: false

  # May the caller provide/delete this service? (its role must be "provide").
  defp provider?({:addon, %{services_role: roles}}, service),
    do: Map.get(roles, service) == "provide"

  defp provider?(_caller, _service), do: false

  # May the caller read the service? Supervisor/Core always; an add-on iff it
  # declares any role for the service (provide/want/need).
  defp service_reader?(:supervisor, _service), do: true

  defp service_reader?({:addon, %{services_role: roles}}, service),
    do: Map.has_key?(roles, service)

  defp service_reader?(_caller, _service), do: false

  # Validate a service publish body. Only `mqtt` is known (§A3.1
  # SCHEMA_SERVICE_MQTT).
  defp validate_service("mqtt", params) when is_map(params) do
    with {:ok, host} <- require_string(params, "host"),
         {:ok, port} <- require_port(params, "port"),
         {:ok, protocol} <- mqtt_protocol(params) do
      data =
        %{
          "host" => host,
          "port" => port,
          "ssl" => Map.get(params, "ssl", false),
          "protocol" => protocol
        }
        |> put_optional_string(params, "username")
        |> put_optional_string(params, "password")

      if is_boolean(data["ssl"]), do: {:ok, data}, else: {:error, "ssl must be a boolean"}
    end
  end

  defp validate_service(service, _params), do: {:error, "unknown service '#{service}'"}

  defp require_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp require_port(params, key) do
    case Map.get(params, key) do
      p when is_integer(p) and p >= 1 and p <= 65_535 -> {:ok, p}
      _ -> {:error, "#{key} must be a port (1-65535)"}
    end
  end

  defp mqtt_protocol(params) do
    case Map.get(params, "protocol", "3.1.1") do
      v when v in ["3.1", "3.1.1"] -> {:ok, v}
      _ -> {:error, "protocol must be 3.1 or 3.1.1"}
    end
  end

  defp put_optional_string(data, params, key) do
    case Map.get(params, key) do
      v when is_binary(v) -> Map.put(data, key, v)
      _ -> data
    end
  end
end
