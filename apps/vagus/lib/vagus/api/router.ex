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

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.{Manager, OptionsSchema, State, Store, StoreView}
  alias Vagus.API.{Envelope, StaticData}
  alias Vagus.Backend
  alias Vagus.Backups
  alias Vagus.Core.TokenStore
  alias Vagus.Discovery
  alias Vagus.Runtime.{Docker, Logs, Stats}
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
  #
  # No `:multipart` parser here (B1 fix). An earlier revision carved out a
  # 256MB multipart `length:` override on this same router-wide plug, which
  # runs BEFORE `Vagus.API.Auth` — so an unauthenticated multipart POST to
  # ANY path would spool up to 256MB to disk with no token at all,
  # exhausting a 1GB device's disk/FDs under concurrent requests (exactly
  # the memory-pressure attack the 64KB default below exists to prevent).
  # `POST /backups/new/upload` is the one route that legitimately needs a
  # large multipart body (a backup tar); it now parses its own still-unread
  # body itself, route-locally, AFTER `Vagus.API.Auth` and the
  # supervisor-only check have both run (see `handle_backup_upload/1`'s
  # `parse_multipart/1`). Every other multipart POST — including a
  # non-supervisor caller hitting this same route — passes through here
  # completely unread (`pass: ["*/*"]` below), so it's never spooled to disk
  # pre-auth.
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

  # Wire path is "store", NOT "/store/info" (§3, §20). Backed by the live
  # `Vagus.Addon.Store` catalog (§A1 store routes) — honestly empty until a
  # repository is configured + `POST /store/reload` fetches it.
  get "/store" do
    Envelope.send_ok(conn, StoreInfo.build!(store_info_data()))
  end

  get "/store/addons" do
    Envelope.send_ok(conn, %{addons: store_addon_summaries()})
  end

  get "/store/addons/:slug" do
    case Store.get(slug) do
      {:ok, entry} -> Envelope.send_ok(conn, StoreView.detail(slug, entry, installed?(slug)))
      :error -> Envelope.send_error(conn, "Addon #{slug} does not exist in the store", 404)
    end
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

  # Backed by `Vagus.Addon.State` (not `StaticData`, unlike most other GETs
  # here) — the installed-addon list a `POST .../install` grows and a
  # `POST .../uninstall` shrinks. Each entry reuses `Vagus.Addon.Info.render/4`
  # (the `GET /addons/{slug}/info` shape, a superset of the wire's
  # `InstalledAddon`) rather than a separate summary builder — `AddonsList`
  # only pins the outer `addons` key (`Vagus.API.Model`), so the extra fields
  # are harmless. Honestly empty with no add-ons installed.
  get "/addons" do
    addons = Enum.map(State.list(), &addon_list_entry/1)
    Envelope.send_ok(conn, AddonsList.build!(%{addons: addons}))
  end

  # Add-on info (§A1; `supervisor/api/apps.py` `info_data`). Core's hassio
  # discovery fetches this for a discovery message's provider slug to resolve
  # the add-on name before creating the config flow. Readable by the supervisor
  # (Core) for any slug, and by an add-on for itself (`self` or its own slug).
  #
  # `GET /addons/self/info` resolves through `resolve_info_slug/2` to the
  # caller's own slug and hits this same clause, so an ingress add-on reading
  # its own info gets its resolved dynamic `ingress_port` back exactly the way
  # `bashio::addon.ingress_port` expects (§B3.2 fact 5) — no separate path
  # needed for the self-read case.
  get "/addons/:slug/info" do
    caller = conn.assigns.caller

    with {:ok, resolved} <- resolve_info_slug(slug, caller),
         {:ok, %{config: config, state: state} = entry} <- Vagus.Addon.State.get(resolved) do
      options =
        case read_addon_options(resolved) do
          {:ok, opts} -> opts
          :error -> config.options
        end

      Envelope.send_ok(
        conn,
        Vagus.Addon.Info.render(config, state, options, ingress_settings(entry))
      )
    else
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
      _ -> Envelope.send_error(conn, "Add-on #{slug} does not exist", 404)
    end
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

  # -- Addon lifecycle (M4-P3-T1; §A1.1) -------------------------------------
  #
  # Every route here is supervisor-only (Core drives install/start/stop from
  # the frontend's addon dashboard; an add-on never manages its own or
  # another's lifecycle) — a non-supervisor caller gets a 403 before any
  # `Manager`/`Store` call.

  # Store slug is rewritten onto the parsed config (a store entry's own
  # `config.slug` is the add-on's bare slug, e.g. "mosquitto"; installed
  # add-ons run under the store slug, e.g. "core_mosquitto" — see
  # `Vagus.Addon.Store`'s moduledoc) before `Manager.install/2` builds the
  # container spec from it, and before `State.put/3` records it as
  # installed-but-stopped (a freshly-installed add-on isn't started yet).
  post "/store/addons/:slug/install" do
    handle_install(conn, slug)
  end

  # Legacy alias some Supervisor-API clients use instead of the `/store/...`
  # path for the same action.
  post "/addons/:slug/install" do
    handle_install(conn, slug)
  end

  post "/addons/:slug/start" do
    lifecycle_action(conn, slug, fn -> Manager.start_slug(slug) end)
  end

  post "/addons/:slug/stop" do
    lifecycle_action(conn, slug, fn -> Manager.stop(slug) end)
  end

  post "/addons/:slug/restart" do
    lifecycle_action(conn, slug, fn -> Manager.restart(slug) end)
  end

  # `{"remove_config": bool}` is accepted (Core's `AddonsOptions`/uninstall
  # payload) and ignored — this emulator has no separate "keep config"
  # retention to honor; `Manager.uninstall/2` always purges the data dir.
  post "/addons/:slug/uninstall" do
    lifecycle_action(conn, slug, fn -> Manager.uninstall(slug) end)
  end

  # `POST /addons/{slug}/options` (SCHEMA_OPTIONS). Implements three keys:
  # `options` (`null` resets to no user options, a map is validated against
  # the add-on's schema — merged over its config defaults, mirroring what
  # `Manager.start/2` would write — and, only if valid, stored raw via
  # `State.put_options/2`), `watchdog`, and `ingress_panel` (both booleans,
  # persisted via `State.put_setting/3` — §B3.1/§B8 of
  # `docs/contract-2026.7-m4b-ingress-watchdog.md`; the real Supervisor sets
  # both from this same handler, sharing `SCHEMA_OPTIONS`). Other
  # SCHEMA_OPTIONS keys (`boot`, `auto_update`, …) aren't modeled yet;
  # they're accepted and ignored rather than 400ing a caller that also sets
  # them. Never restarts the add-on itself — the caller is expected to
  # follow up with `.../restart` if it wants the new options live.
  post "/addons/:slug/options" do
    handle_addon_options(conn, slug)
  end

  # -- Stats coordinator (60s) -----------------------------------------------

  get "/core/stats" do
    Envelope.send_ok(conn, CoreStats.build!(container_stats(core_container())))
  end

  get "/supervisor/stats" do
    Envelope.send_ok(conn, CoreStats.build!(container_stats(supervisor_container())))
  end

  # Real per-add-on resource usage from the engine (§A5/P5-T2). Readable by the
  # supervisor (Core) for any slug and by an add-on for itself.
  get "/addons/:slug/stats" do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} ->
        Envelope.send_ok(conn, CoreStats.build!(container_stats("addon_#{resolved}")))

      {:error, :forbidden} ->
        Envelope.send_error(conn, "Not authorized for this add-on", 403)
    end
  end

  # -- Logs (§A5) — text/plain, one entry per line, X-First-Cursor +
  # X-Accel-Buffering headers. One-shot (the frontend's tolerated legacy GET);
  # live `/follow` streaming is a later add. Sourced from the engine's container
  # logs; families without a container (host) are honestly empty. ------------

  get "/addons/:slug/logs" do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} -> send_logs(conn, "addon_#{resolved}")
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
    end
  end

  get "/addons/:slug/logs/latest" do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} -> send_logs(conn, "addon_#{resolved}", no_colors: true)
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
    end
  end

  get("/core/logs", do: send_logs(conn, core_container()))
  get("/core/logs/latest", do: send_logs(conn, core_container(), no_colors: true))
  get("/supervisor/logs", do: send_logs(conn, supervisor_container()))
  get("/supervisor/logs/latest", do: send_logs(conn, supervisor_container(), no_colors: true))
  get("/host/logs", do: send_logs(conn, nil))
  get("/host/logs/latest", do: send_logs(conn, nil, no_colors: true))

  # JSON side-endpoints (§A5): one boot (we don't track journald boots), no
  # extra syslog identifiers.
  get "/host/logs/boots" do
    Envelope.send_ok(conn, %{boots: %{"0" => "vagus"}})
  end

  get "/host/logs/identifiers" do
    Envelope.send_ok(conn, %{identifiers: []})
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
  # map of addon-slug → panel config. Backed by `Vagus.Ingress.Panels.list/1`
  # (IW-P2-T3; §B4.1) — one entry per installed ingress-capable add-on,
  # `enable` reflecting its `ingress_panel` toggle. Auth is unchanged: §B1.4
  # explicitly does NOT put this route in the ingress-proxy's
  # no-security-check bypass, so it goes through the router's normal
  # token-validation middleware like every other route (any authenticated
  # caller, not just the supervisor/Core).
  get "/ingress/panels" do
    Envelope.send_ok(conn, %{panels: Vagus.Ingress.Panels.list()})
  end

  # -- Ingress session lifecycle (IW-P2-T1; §B1.1/B1.2) ----------------------
  # Both routes are `@require_home_assistant` upstream: only a caller
  # authenticated as Core's own Supervisor token may create/renew a session
  # — resolved to `:supervisor` by `Vagus.API.Auth`, same as `home_assistant?`
  # elsewhere in this router. Deliberately **401**, not this router's usual
  # 403-for-wrong-caller pattern (e.g. `supervisor_only/2`'s backup routes) —
  # upstream's `@require_home_assistant` wrapper raises `HTTPUnauthorized`
  # specifically, and the contract calls this out as the one place a
  # wrong-caller rejection isn't a 403.
  post "/ingress/session" do
    if conn.assigns.caller == :supervisor do
      # `session_data_user_id` (§B1.1) would resolve an HA user via
      # `sys_homeassistant.list_users()` to attach to the session; this
      # emulator doesn't model HA users, so the key is accepted (no 400) and
      # simply ignored.
      {:ok, token} = Vagus.Ingress.create_session()
      Envelope.send_ok(conn, %{session: token})
    else
      Envelope.send_error(conn, "unauthorized", 401)
    end
  end

  post "/ingress/validate_session" do
    if conn.assigns.caller == :supervisor do
      case Map.fetch(conn.body_params, "session") do
        {:ok, session} when is_binary(session) ->
          case Vagus.Ingress.validate_session(session) do
            :ok -> Envelope.send_ok(conn, %{})
            :error -> Envelope.send_error(conn, "Session does not exist", 401)
          end

        _missing_or_invalid ->
          Envelope.send_error(conn, "session is required", 400)
      end
    else
      Envelope.send_error(conn, "unauthorized", 401)
    end
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
  # `days_until_stale` (Supervisor default: 30). Backed by `Vagus.Backups`
  # (M4-P6-T2; §A4) — supervisor-caller only, same as the rest of the
  # backup surface below.

  get "/backups" do
    supervisor_only(conn, fn ->
      entries = Backups.list() |> Enum.map(&backup_list_entry/1)
      Envelope.send_ok(conn, %{backups: entries})
    end)
  end

  get "/backups/info" do
    supervisor_only(conn, fn ->
      entries = Backups.list() |> Enum.map(&backup_list_entry/1)
      Envelope.send_ok(conn, %{backups: entries, days_until_stale: 30})
    end)
  end

  get "/backups/:slug/info" do
    supervisor_only(conn, fn ->
      case Backups.get(slug) do
        {:ok, entry} -> Envelope.send_ok(conn, backup_info(entry))
        :error -> Envelope.send_error(conn, "Backup does not exist", 404)
      end
    end)
  end

  post "/backups/new/partial" do
    supervisor_only(conn, fn -> handle_backup_new_partial(conn, conn.body_params) end)
  end

  post "/backups/new/upload" do
    supervisor_only(conn, fn -> handle_backup_upload(conn) end)
  end

  post "/backups/:slug/restore/partial" do
    supervisor_only(conn, fn -> handle_backup_restore(conn, slug, conn.body_params) end)
  end

  get "/backups/:slug/download" do
    supervisor_only(conn, fn -> handle_backup_download(conn, slug) end)
  end

  delete "/backups/:slug" do
    supervisor_only(conn, fn ->
      case Backups.delete(slug) do
        :ok -> Envelope.send_ok(conn, %{})
        :error -> Envelope.send_error(conn, "Backup does not exist", 404)
      end
    end)
  end

  post "/backups/reload" do
    supervisor_only(conn, fn ->
      :ok = Backups.reload()
      Envelope.send_ok(conn, %{})
    end)
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
  # re-listing addons (§3). Re-fetches the store repositories.
  post "/store/reload" do
    {:ok, _count} = Store.reload()
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

  # -- logs helpers ----------------------------------------------------------

  # Send a plain-text log body (§A5): the required headers, then the demuxed +
  # (optionally) de-colored container logs. No container / an engine error is an
  # honestly-empty 200, not a failure — a log poll must not error. `?lines=N`
  # tails, `?no_colors` strips ANSI.
  defp send_logs(conn, ref, opts \\ []) do
    conn = fetch_query_params(conn)
    lines = log_lines(conn)

    no_colors =
      Map.has_key?(conn.query_params, "no_colors") or Keyword.get(opts, :no_colors, false)

    body = log_body(ref, lines, no_colors)

    conn
    |> put_resp_header("x-first-cursor", "0")
    |> put_resp_header("x-accel-buffering", "no")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
    |> halt()
  end

  defp log_body(nil, _lines, _no_colors), do: ""

  # Native "virtual add-ons" have no container — serve the broker's telemetry log
  # buffer (already text/plain, one entry per line) instead of Docker logs.
  defp log_body(ref, lines, no_colors) do
    if Native.running?(ref) do
      ref |> Native.logs(lines: lines) |> Enum.join("\n")
    else
      case Docker.container_logs(ref, tail: lines) do
        {:ok, raw} -> Logs.format(raw, no_colors: no_colors)
        {:error, _reason} -> ""
      end
    end
  end

  defp log_lines(conn) do
    case Integer.parse(Map.get(conn.query_params, "lines", "100")) do
      {n, _} when n >= 2 -> n
      _ -> 100
    end
  end

  # -- stats helpers ---------------------------------------------------------

  # Real engine stats for `ref`, or all-zeros when there's no container
  # configured/running (honest idle) — a stats poll must never error.
  defp container_stats(nil), do: Stats.zero()

  # Native add-ons have no container to poll — derive stats from the broker
  # subtree's processes (same shape) instead of `Docker.stats`.
  defp container_stats(ref) do
    if Native.running?(ref) do
      Native.stats(ref)
    else
      case Docker.stats(ref) do
        {:ok, raw} -> Stats.compute(raw)
        {:error, _reason} -> Stats.zero()
      end
    end
  end

  defp core_container, do: Application.get_env(:vagus, :core_container)
  defp supervisor_container, do: Application.get_env(:vagus, :supervisor_container)

  # -- store helpers ---------------------------------------------------------

  defp store_info_data do
    %{addons: store_addon_summaries(), repositories: store_repositories()}
  end

  defp store_addon_summaries do
    Store.catalog()
    |> Enum.map(fn {slug, entry} -> StoreView.summary(slug, entry, installed?(slug)) end)
  end

  # Store slugs and installed-state slugs share the same namespace
  # (`core_mosquitto` both in the catalog and in `Vagus.Addon.State`).
  defp installed?(store_slug), do: match?({:ok, _}, State.get(store_slug))

  # The Repository wire shape (slug/name/source/url/maintainer, all strings).
  defp store_repositories do
    Enum.map(Store.repositories(), fn repo ->
      %{
        slug: repo.slug,
        name: Map.get(repo, :name, repo.slug),
        source: repo.url,
        url: repo.url,
        maintainer: Map.get(repo, :maintainer, "")
      }
    end)
  end

  # -- addon lifecycle helpers ------------------------------------------------

  # `GET /addons` entry: the effective options (falling back to the config
  # defaults, same as `/addons/{slug}/info`) rendered through
  # `Vagus.Addon.Info.render/4`.
  defp addon_list_entry(%{config: config, state: state} = entry) do
    options =
      case read_addon_options(config.slug) do
        {:ok, opts} -> opts
        :error -> config.options
      end

    Vagus.Addon.Info.render(config, state, options, ingress_settings(entry))
  end

  # `Vagus.Addon.Info.render/4`'s `settings` param is exactly the State
  # entry's ingress/watchdog fields, minus `config`/`state`/`user_options`.
  defp ingress_settings(entry) do
    Map.take(entry, [:ingress_token, :ingress_port, :ingress_panel, :watchdog])
  end

  defp handle_install(conn, slug) do
    if conn.assigns.caller == :supervisor do
      case Store.get(slug) do
        {:ok, %{config: entry_config}} ->
          # The store entry's own `config.slug` is the add-on's bare slug
          # (e.g. "mosquitto"); installed add-ons run under the store slug
          # (e.g. "core_mosquitto" — see `Vagus.Addon.Store`'s moduledoc).
          config = %{entry_config | slug: slug}

          case Manager.install(config) do
            :ok ->
              :ok = State.put(config, :stopped)
              Envelope.send_ok(conn, %{})

            {:error, reason} ->
              Envelope.send_error(conn, inspect(reason), 400)
          end

        :error ->
          Envelope.send_error(conn, "Addon #{slug} does not exist in the store", 404)
      end
    else
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  # Shared supervisor-only-caller + result-mapping wrapper for
  # start/stop/restart/uninstall — all four share the same
  # `:ok | {:ok, _} | {:error, :not_found} | {:error, reason}` result shape.
  defp lifecycle_action(conn, slug, fun) do
    if conn.assigns.caller == :supervisor do
      case fun.() do
        :ok -> Envelope.send_ok(conn, %{})
        {:ok, _} -> Envelope.send_ok(conn, %{})
        {:error, :not_found} -> Envelope.send_error(conn, "Addon #{slug} does not exist", 404)
        {:error, reason} -> Envelope.send_error(conn, inspect(reason), 400)
      end
    else
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  defp handle_addon_options(conn, slug) do
    if conn.assigns.caller == :supervisor do
      case State.get(slug) do
        :error ->
          Envelope.send_error(conn, "Addon #{slug} does not exist", 404)

        {:ok, %{config: config}} ->
          apply_addon_options(conn, slug, config, conn.body_params)
      end
    else
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  # Validates every known key present in the body *before* applying any of
  # them — a 400 from a bad `watchdog` must not leave a valid `options` half
  # -applied — then applies whichever of the three were present. A body with
  # none of `options`/`watchdog`/`ingress_panel` (or only unmodeled keys like
  # `boot`) is accepted and ignored, matching the pre-existing
  # accept-and-ignore behavior for SCHEMA_OPTIONS keys this emulator doesn't
  # implement.
  defp apply_addon_options(conn, slug, config, body) do
    with {:ok, options_action} <- validate_options_key(body, config),
         {:ok, watchdog_action} <- validate_watchdog_key(body),
         {:ok, ingress_panel_action} <- validate_ingress_panel_key(body) do
      apply_options_action(slug, options_action)
      apply_watchdog_action(slug, config, watchdog_action)
      apply_ingress_panel_action(slug, ingress_panel_action)
      Envelope.send_ok(conn, %{})
    else
      {:error, message} -> Envelope.send_error(conn, message, 400)
    end
  end

  # `options: nil` resets to no user options; a map is validated (merged over
  # the config defaults, mirroring `Manager.start/2`'s own write path) —
  # stored raw if valid (not the merged/validated result — `start_slug/2`
  # redoes that merge+validate itself against whatever the config looks like
  # at start time). No `options` key at all is a no-op, not an error.
  defp validate_options_key(body, config) do
    case Map.fetch(body, "options") do
      :error ->
        {:ok, :none}

      {:ok, nil} ->
        {:ok, :reset}

      {:ok, options} when is_map(options) ->
        case OptionsSchema.effective(config.schema, config.options, options) do
          {:ok, _validated} -> {:ok, {:set, options}}
          {:error, _reason} -> {:error, "Invalid options"}
        end

      {:ok, _other} ->
        {:error, "options must be an object or null"}
    end
  end

  defp apply_options_action(_slug, :none), do: :ok
  defp apply_options_action(slug, :reset), do: State.put_options(slug, %{})
  defp apply_options_action(slug, {:set, options}), do: State.put_options(slug, options)

  # `watchdog` must be a boolean when present; no key at all is a no-op.
  defp validate_watchdog_key(body) do
    case Map.fetch(body, "watchdog") do
      :error -> {:ok, :none}
      {:ok, value} when is_boolean(value) -> {:ok, {:set, value}}
      {:ok, _other} -> {:error, "watchdog must be a boolean"}
    end
  end

  # `startup: "once"` add-ons silently ignore a `watchdog: true` POST
  # (contract §B8 — the real Supervisor's `App.watchdog` setter logs a
  # warning and drops it rather than persisting a watchdog on a one-shot
  # container) but still return 200, matching the real handler's behavior of
  # never 400ing over this. `false` is always honored (there's nothing
  # unsafe about explicitly disabling a watchdog that could never have been
  # enabled).
  defp apply_watchdog_action(_slug, _config, :none), do: :ok

  defp apply_watchdog_action(slug, %{startup: "once"}, {:set, true}) do
    Logger.warning(
      "Vagus.API.Router: ignoring watchdog=true for #{slug} (startup: once add-ons never watchdog)"
    )

    :ok
  end

  defp apply_watchdog_action(slug, _config, {:set, value}) do
    :ok = State.put_setting(slug, :watchdog, value)
  end

  # `ingress_panel` must be a boolean when present; no key at all is a no-op.
  # The Core panel push the real Supervisor also does here
  # (`sys_ingress.update_hass_panel`, contract §B4.4) is applied by
  # `apply_ingress_panel_action/2` below, right after persisting the toggle.
  defp validate_ingress_panel_key(body) do
    case Map.fetch(body, "ingress_panel") do
      :error -> {:ok, :none}
      {:ok, value} when is_boolean(value) -> {:ok, {:set, value}}
      {:ok, _other} -> {:error, "ingress_panel must be a boolean"}
    end
  end

  defp apply_ingress_panel_action(_slug, :none), do: :ok

  defp apply_ingress_panel_action(slug, {:set, value}) do
    :ok = State.put_setting(slug, :ingress_panel, value)

    # §B4.4: real Supervisor `await`s `sys_ingress.update_hass_panel(app)`
    # inside this same request. Ours fire-and-forgets (the default async
    # path in `Vagus.Ingress.Panels.update_hass_panel/2`) so this options
    # POST never blocks on Core's availability — see that function's
    # moduledoc for why that's safe (Core re-fetches the full panel list
    # itself rather than trusting the push body).
    Vagus.Ingress.Panels.update_hass_panel(slug)
  end

  # -- backup helpers (M4-P6-T2; §A4) -----------------------------------------

  # Shared supervisor-only-caller guard for every `/backups...` route — Core
  # drives backups from the frontend, an add-on never manages backups.
  defp supervisor_only(conn, fun) do
    if conn.assigns.caller == :supervisor,
      do: fun.(),
      else: Envelope.send_error(conn, "unauthorized", 403)
  end

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  # `GET /backups` / `GET /backups/info` list entry (pinned V1 shape).
  defp backup_list_entry(%{backup: b, size_bytes: size_bytes}) do
    %{
      slug: b["slug"],
      name: b["name"],
      date: b["date"],
      type: "partial",
      size: mb(size_bytes),
      size_bytes: size_bytes,
      location: nil,
      locations: [nil],
      protected: false,
      compressed: true,
      location_attributes: %{".local" => %{protected: false, size_bytes: size_bytes}},
      content: %{
        homeassistant: false,
        addons: Enum.map(b["addons"] || [], & &1["slug"]),
        folders: []
      }
    }
  end

  # `GET /backups/{slug}/info` shape.
  defp backup_info(%{backup: b, size_bytes: size_bytes}) do
    %{
      slug: b["slug"],
      type: "partial",
      name: b["name"],
      date: b["date"],
      size: mb(size_bytes),
      size_bytes: size_bytes,
      compressed: true,
      protected: false,
      location_attributes: %{".local" => %{protected: false, size_bytes: size_bytes}},
      supervisor_version: b["supervisor_version"],
      homeassistant: nil,
      location: nil,
      locations: [nil],
      addons:
        Enum.map(b["addons"] || [], fn a ->
          %{slug: a["slug"], name: a["name"], version: a["version"], size: a["size"]}
        end),
      repositories: [],
      folders: [],
      homeassistant_exclude_database: nil,
      extra: %{}
    }
  end

  defp handle_backup_new_partial(conn, params) do
    with :ok <- reject_password(params),
         :ok <- reject_homeassistant(params, "Core backup not supported"),
         :ok <- reject_folders(params),
         :ok <- validate_filename(params),
         {:ok, addon_slugs} <- resolve_create_addon_slugs(params) do
      case Backups.create_partial(Map.get(params, "name"), addon_slugs) do
        {:ok, slug} ->
          Envelope.send_ok(conn, %{slug: slug, job_id: new_job_id()})

        {:error, {:not_installed, addon_slug}} ->
          Envelope.send_error(conn, "Addon #{addon_slug} is not installed", 400)

        {:error, reason} ->
          Envelope.send_error(conn, inspect(reason), 400)
      end
    else
      {:error, message} -> Envelope.send_error(conn, message, 400)
    end
  end

  defp handle_backup_restore(conn, slug, params) do
    case Backups.get(slug) do
      :error ->
        Envelope.send_error(conn, "Backup does not exist", 404)

      {:ok, _entry} ->
        with :ok <- reject_password(params),
             :ok <- reject_homeassistant(params, "Core restore not supported"),
             :ok <- reject_folders(params),
             {:ok, addon_slugs} <- require_addons_list(params) do
          case Backups.restore_partial(slug, addon_slugs) do
            :ok ->
              Envelope.send_ok(conn, %{job_id: new_job_id()})

            {:error, message} when is_binary(message) ->
              Envelope.send_error(conn, message, 400)

            {:error, reason} ->
              Envelope.send_error(conn, inspect(reason), 400)
          end
        else
          {:error, message} -> Envelope.send_error(conn, message, 400)
        end
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule", "Traversal.SendFile"]
  defp handle_backup_download(conn, slug) do
    case Backups.get(slug) do
      {:ok, %{backup: b, path: path}} ->
        filename = Regex.replace(~r/[^A-Za-z0-9]+/, b["name"] || slug, "_") <> ".tar"

        conn
        |> put_resp_content_type("application/tar", nil)
        |> put_resp_header("content-disposition", "attachment; filename=#{filename}")
        |> send_file(200, path)

      :error ->
        Envelope.send_error(conn, "Backup does not exist", 404)
    end
  end

  # Memoized `Plug.Parsers.init/1` result for the route-local multipart parse
  # below — `init/1` only normalizes options into an opaque tuple, so
  # computing it once at compile time (rather than per-request) is safe.
  @multipart_parser_opts Plug.Parsers.init(parsers: [{:multipart, length: 268_435_456}], pass: [])

  # The uploaded tar's bytes are validated by `Backups.put_file/1` itself
  # (`Vagus.Backup.read/1`) — any field name is accepted (the first
  # `%Plug.Upload{}` found in the parsed multipart params is used), matching
  # the real Supervisor's tolerance of arbitrary multipart field naming.
  #
  # Multipart parsing happens HERE (B1), not on the router-wide
  # `Plug.Parsers` — by the time this runs, `Vagus.API.Auth` and
  # `supervisor_only/2` (this route's caller only reaches here through that
  # wrapper) have already gated the request to an authenticated supervisor
  # caller, so the 256MB/disk-spooling multipart parse only ever happens for
  # that caller. The body is still unread at this point (the router-wide
  # parser passed it through, `pass: ["*/*"]`), so `parse_multipart/1` is
  # reading it for the first time.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp handle_backup_upload(conn) do
    case parse_multipart(conn) do
      {:ok, conn} ->
        case first_upload(conn.body_params) do
          {:ok, %Plug.Upload{path: path}} ->
            with {:ok, tar} <- File.read(path),
                 {:ok, slug} <- Backups.put_file(tar) do
              Envelope.send_ok(conn, %{slug: slug})
            else
              _ -> Envelope.send_error(conn, "invalid backup file", 400)
            end

          :error ->
            Envelope.send_error(conn, "no file uploaded", 400)
        end

      {:error, conn} ->
        Envelope.send_error(conn, "invalid backup upload", 400)
    end
  end

  # `pass: []` on this route-local parser means a non-multipart content-type
  # raises `Plug.Parsers.UnsupportedMediaTypeError` (this route has no other
  # valid upload method) rather than silently passing through unparsed; a
  # malformed multipart body raises `Plug.Parsers.ParseError`. Both are
  # honest 400s here rather than falling through to the router's generic
  # `Plug.ErrorHandler`/`handle_errors/2`, which would 415/500 them.
  defp parse_multipart(conn) do
    {:ok, Plug.Parsers.call(conn, @multipart_parser_opts)}
  rescue
    e in [Plug.Parsers.ParseError, Plug.Parsers.UnsupportedMediaTypeError] ->
      Logger.debug("Vagus.API.Router: multipart upload parse failed: #{Exception.message(e)}")
      {:error, conn}
  end

  defp first_upload(params) when is_map(params) do
    case Enum.find_value(params, fn {_k, v} -> match?(%Plug.Upload{}, v) and v end) do
      %Plug.Upload{} = upload -> {:ok, upload}
      _ -> :error
    end
  end

  defp first_upload(_params), do: :error

  defp reject_password(params) do
    case Map.get(params, "password") do
      v when is_binary(v) and v != "" -> {:error, "protected backups are not supported"}
      _ -> :ok
    end
  end

  defp reject_homeassistant(params, message) do
    if Map.get(params, "homeassistant") == true, do: {:error, message}, else: :ok
  end

  defp reject_folders(params) do
    case Map.get(params, "folders") do
      list when is_list(list) and list != [] -> {:error, "folder backup not supported"}
      _ -> :ok
    end
  end

  defp validate_filename(params) do
    case Map.get(params, "filename") do
      nil ->
        :ok

      fname when is_binary(fname) ->
        if Regex.match?(~r/^[^\/]+\.tar$/, fname),
          do: :ok,
          else: {:error, "filename must match ^[^/]+\\.tar$"}

      _other ->
        {:error, "filename must be a string"}
    end
  end

  # `"ALL"` resolves to every currently-installed slug (§A4's
  # `addons:"ALL"|[slug]`); an explicit list is passed through as-is (whether
  # each slug is actually installed is `Backups.create_partial/3`'s concern).
  defp resolve_create_addon_slugs(params) do
    case Map.get(params, "addons") do
      "ALL" ->
        {:ok, Enum.map(State.list(), & &1.config.slug)}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "addons must be a list of slugs"}

      _other ->
        {:error, "addons is required (\"ALL\" or a list of slugs)"}
    end
  end

  # Partial restore's `addons` is always an explicit list (no `"ALL"`, §A4).
  defp require_addons_list(params) do
    case Map.get(params, "addons") do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "addons must be a list of slugs"}

      _other ->
        {:error, "addons is required and must be a list of slugs"}
    end
  end

  # uuid4hex-shaped job id (32 lowercase hex chars) — mirrors
  # `Vagus.Discovery`'s own uuid minting, not a validated RFC 4122 v4 (the
  # wire only cares about the shape/uniqueness, never parses it back).
  defp new_job_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

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

  # Resolve the slug an info request may read: the supervisor (Core) may read
  # any slug; an add-on may read `self` or its own slug, nothing else. The
  # supervisor slug comes from the URL, so validate it before it's interpolated
  # into a container ref (`addon_<slug>`) or the `options.json` path — a `/` or
  # `..` must never shape a Docker ref or traverse the data root.
  defp resolve_info_slug(slug, :supervisor) do
    if valid_slug?(slug), do: {:ok, slug}, else: {:error, :forbidden}
  end

  defp resolve_info_slug("self", {:addon, %{slug: own}}), do: {:ok, own}
  defp resolve_info_slug(own, {:addon, %{slug: own}}), do: {:ok, own}
  defp resolve_info_slug(_slug, {:addon, _}), do: {:error, :forbidden}
  defp resolve_info_slug(_slug, _caller), do: {:error, :forbidden}

  # Add-on slugs are `RE_SLUG` (`[A-Za-z0-9._-]`); additionally forbid `..` so
  # the value is safe both as a Docker ref suffix and a path component.
  defp valid_slug?(slug) do
    Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, slug) and not String.contains?(slug, "..")
  end

  # -- addon self-config helper ----------------------------------------------

  # Reads the effective options `Manager.start` wrote to the add-on's
  # `/data/options.json` (data root from `config :vagus, :addon_data_root`).
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
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
