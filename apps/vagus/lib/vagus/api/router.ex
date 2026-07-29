defmodule Vagus.API.Router do
  @moduledoc """
  The Supervisor-API emulator's HTTP surface.

  Pipeline order: body parsing, then `Vagus.API.Auth` (every request,
  including ones that end up 404ing, must authenticate — with one exemption
  that `Vagus.API.Auth` decides for itself, see below), then routing. Every response — success, honest no-op,
  honest error, the catch-all 404, or an exception raised anywhere in the
  pipeline (`use Plug.ErrorHandler`, `handle_errors/2` below) — goes out
  through `Vagus.API.Envelope` so a bare/default Plug response never leaks
  through unwrapped, except the four store-asset routes, which are
  intentionally raw (`image/png`/`text/plain`/`application/octet-stream`
  bytes, not a JSON envelope — that's the upstream wire shape).

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
  alias Vagus.Addon.{Manager, OptionsSchema, Ports, State, Store, StoreView, Update}
  alias Vagus.Addon.Store.Assets
  alias Vagus.API.{Envelope, StaticData}
  alias Vagus.Backend
  alias Vagus.Backups
  alias Vagus.Core.{Health, Lifecycle, TokenStore, Versions}
  alias Vagus.Discovery
  alias Vagus.Mqtt.Broker
  alias Vagus.Runtime.{Docker, Logs, Stats}
  alias Vagus.Services

  alias Vagus.API.Models.{
    AccessPoint,
    AccessPointList,
    AddonsList,
    AvailableUpdates,
    CoreStats,
    DatadiskList,
    HardwareInfo,
    HomeAssistantInfo,
    HostDisksUsage,
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

  # `Vagus.API.Auth` authenticates every request, with exactly one exemption
  # that it decides for itself: GET of an add-on's icon/logo. That carve-out
  # lives in `Vagus.API.Auth.unauthenticated?/1` — deliberately NOT in a
  # pre-auth plug here setting a flag for Auth to honor, because a flag is a
  # channel any plug could write, and B1's lesson is that a pre-auth plug
  # doing more than it must is where this router got burned before. Nothing
  # in this module can cause a request to skip authentication.
  #
  # The exemption is upstream contract, not a choice: Core's proxy forwards
  # those GETs with NO Authorization header at all (`PATHS_NO_AUTH` in
  # `homeassistant/components/hassio/http.py` — when it matches, the branch
  # short-circuits before the header is set, for admins too), and Supervisor
  # skips its own middleware for them (`no_security_check` splices in
  # `_V1_FRONTEND_PATHS`, i.e. `|/(store/)?addons/<RE_SLUG>/(logo|icon)` —
  # reading its literal alternatives alone will mislead you). Requiring a
  # token here adds no security, since the proxy has none to attach; it just
  # permanently breaks every add-on's icon in the frontend.
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

  # Function plug (see the comment above its position in the pipeline). Only
  # a GET against exactly `["addons", slug, "icon"|"logo"]` or `["store",
  # "addons", slug, "icon"|"logo"]` sets the bypass; everything else — a
  # different method on the same path, changelog/documentation, any other
  # route — falls through untouched to `Vagus.API.Auth`.

  # -- Main coordinator (5 min) + one-time setup GETs -----------------------

  get "/info" do
    Envelope.send_ok(conn, RootInfo.build!(StaticData.root_info()))
  end

  get "/supervisor/info" do
    Envelope.send_ok(conn, SupervisorInfo.build!(StaticData.supervisor_info()))
  end

  # `version`/`version_latest`/`update_available` come from `Vagus.Core.Versions`
  # (CL-P3-T2) — real state seeded by boot adoption / kept current by
  # `update/2` — and `watchdog` from the persisted `Vagus.Core.TokenStore`
  # option (CW-P0-T3, so a `POST core/options {"watchdog": bool}` toggle
  # round-trips honestly); every other field is still `StaticData.core_info/0`'s
  # Phase 2 static value. `HomeAssistantInfo` declares both `version` and
  # `version_latest` nullable, so a not-yet-adopted/offline `nil` from
  # `Versions` is a valid response, not a fallback case.
  get "/core/info" do
    server = core_versions_server()

    attrs =
      Map.merge(StaticData.core_info(), %{
        version: Versions.installed(server),
        version_latest: Versions.latest(server),
        update_available: Versions.update_available?(server),
        watchdog: TokenStore.get_watchdog()
      })

    Envelope.send_ok(conn, HomeAssistantInfo.build!(attrs))
  end

  get "/os/info" do
    Envelope.send_ok(conn, OSInfo.build!(Backend.os().info()))
  end

  # Storage page's Move-data-disk dialog (CW survey P1) — honestly empty,
  # see the model's moduledoc. supervisor_only: upstream allows
  # `/os/(?!datadisk/wipe).+` to manager-role+ only, same tier note as
  # /host/disks/default/usage above.
  get "/os/datadisk/list" do
    supervisor_only(conn, fn ->
      Envelope.send_ok(conn, DatadiskList.build!(%{devices: [], disks: []}))
    end)
  end

  get "/host/info" do
    Envelope.send_ok(conn, HostInfo.build!(Backend.host().info()))
  end

  # Storage page breakdown chart + backup-settings UI (CW survey P1).
  # `max_depth` query param defaults to 1 like upstream; a non-integer
  # value falls back rather than erroring (upstream behavior).
  # supervisor_only: upstream's security middleware allows this path to
  # manager-role add-ons and Core only (`/host/.+` is NOT in the
  # default-role table) — Vagus's v1 equivalent of that tier is the
  # supervisor gate, same call the /backups routes made.
  get "/host/disks/default/usage" do
    conn = fetch_query_params(conn)

    # Clamped: the frontend asks for 3; deeper nesting only inflates the
    # JSON (sizes are full-recursive regardless — see DiskBreakdown).
    max_depth =
      case Integer.parse(Map.get(conn.query_params, "max_depth", "1")) do
        {depth, _rest} when depth > 0 -> min(depth, 8)
        _other -> 1
      end

    supervisor_only(conn, fn ->
      Envelope.send_ok(
        conn,
        HostDisksUsage.build!(Backend.Host.DiskBreakdown.usage(max_depth: max_depth))
      )
    end)
  end

  # Settings → Hardware → "All hardware" dialog (CW survey P1). Plain
  # token auth, NO supervisor gate: upstream's default-role pattern
  # (`/.+/info`) admits any API-enabled add-on here — parity, not an
  # oversight.
  get "/hardware/info" do
    Envelope.send_ok(conn, HardwareInfo.build!(Backend.Host.Hardware.info()))
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
      {:ok, entry} ->
        installed = installed_entry(slug)

        Envelope.send_ok(
          conn,
          StoreView.detail(
            slug,
            entry,
            installed?(installed),
            installed_version(installed),
            long_description(slug)
          )
        )

      :error ->
        Envelope.send_error(conn, "Addon #{slug} does not exist in the store", 404)
    end
  end

  # -- Store assets: icon/logo/changelog/documentation (P2-A P4) ------------
  #
  # icon/logo are unauthenticated (see `Vagus.API.Auth.unauthenticated?/1` —
  # plug pipeline) and mirror upstream's exact absent-asset shape — 400 +
  # `application/octet-stream`, not a JSON envelope and not a 404. Neither
  # handler touches `conn.assigns.caller`: the pre-auth plug never resolves
  # one, so reading it here would crash instead of deny.
  #
  # changelog/documentation stay behind normal auth (`supervisor_only/2`) but
  # are ALWAYS 200, even when absent — upstream's own comment is "Frontend
  # can't handle error response here, need to return 200 and error as text
  # for now". Matching each shape exactly is the point: a "consistent"
  # implementation would break one of the two frontends.
  #
  # Both the `/store/addons/...` and legacy `/addons/...` forms resolve the
  # same way: installed add-ons are recorded under the STORE slug
  # (`handle_install` rewrites `config.slug` before persisting), so whichever
  # form the request uses, `slug` is already a store slug and `Store.get/1`
  # is the exact lookup — no scanning, no repo guessing.
  get("/store/addons/:slug/icon", do: send_image_asset(conn, slug, :icon))
  get("/store/addons/:slug/logo", do: send_image_asset(conn, slug, :logo))
  get("/addons/:slug/icon", do: send_image_asset(conn, slug, :icon))
  get("/addons/:slug/logo", do: send_image_asset(conn, slug, :logo))

  get("/store/addons/:slug/changelog", do: send_text_asset(conn, slug, :changelog))
  get("/store/addons/:slug/documentation", do: send_text_asset(conn, slug, :documentation))
  get("/addons/:slug/changelog", do: send_text_asset(conn, slug, :changelog))
  get("/addons/:slug/documentation", do: send_text_asset(conn, slug, :documentation))

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
      options = live_options(entry)

      settings =
        entry
        |> info_settings()
        |> Map.put(:long_description, long_description(resolved))

      Envelope.send_ok(conn, Vagus.Addon.Info.render(config, state, options, settings))
    else
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
      _ -> uninstalled_addon_info(conn, slug)
    end
  end

  # V1's legacy store fallback. `GET /addons/{slug}/info` is the ONLY call the
  # frontend makes when you open an add-on page — from the store listing too
  # (`_addonTapped` navigates to `/config/app/{slug}/info?store=true`, and
  # `ha-config-app-dashboard._loadAddon` fetches this endpoint and shows an
  # error screen if it fails). Upstream serves that by registering a shim on
  # the V1 route only (`api/__init__.py::apps_app_info`): installed add-ons get
  # the normal info, `APIAppNotInstalled` falls through to the store's detail
  # payload with `state` and `options` grafted on, and a slug in neither still
  # 404s. The V2 `/apps/{slug}/info` route keeps the strict behaviour.
  #
  # Without this an uninstalled store add-on's page is an "Error loading app"
  # screen — every card in the store is unclickable.
  #
  # No new exposure for a default-role add-on caller: `options` here is the
  # store config's *defaults* out of `config.yaml`, not another add-on's saved
  # user options (those live in `State` and only the installed branch reads
  # them).
  defp uninstalled_addon_info(conn, slug) do
    case Store.get(slug) do
      {:ok, %{config: config} = entry} ->
        detail =
          slug
          |> StoreView.detail(entry, false, nil, long_description(slug))
          |> Map.merge(%{"state" => "unknown", "options" => config.options})

        Envelope.send_ok(conn, detail)

      :error ->
        Envelope.send_error(conn, "Add-on #{slug} does not exist", 404)
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

        # Upstream answers `app.schema.validate(app.options)` — the same live
        # merge, validated — not a file read, so an add-on calling
        # `bashio::config` sees an option saved while it was running rather
        # than the snapshot it booted with.
        case Vagus.Addon.State.get(caller_slug) do
          {:ok, %{config: config} = entry} ->
            case OptionsSchema.validate(config.schema, live_options(entry)) do
              {:ok, options} ->
                Envelope.send_ok(conn, options)

              {:error, _reason} ->
                Envelope.send_error(conn, "Invalid configuration data for the app", 400)
            end

          :error ->
            Envelope.send_error(conn, "Invalid configuration data for the app", 400)
        end

      true ->
        Envelope.send_error(conn, "Self is not an App", 400)
    end
  end

  # -- Addon lifecycle (M4-P3-T1; §A1.1) -------------------------------------
  #
  # Install/update are supervisor-only (Core drives them from the frontend's
  # addon dashboard) — a non-supervisor caller gets a 403 from
  # `Vagus.API.Tiers` before any `Manager`/`Store` call. Upstream would admit
  # `ROLE_MANAGER`; stricter is fine and these keep the tier they shipped
  # with.
  #
  # start/stop/restart/uninstall/options additionally admit the literal slug
  # `self`, matching upstream's `api_bypass` (`security.py` L97) — an add-on
  # may manage *itself*, never another. See `lifecycle_action/3`.

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

  # `POST .../update` can run for minutes — pulling an add-on image on a slow
  # device, then stopping/recreating the container. Synchronous v1, exactly
  # like `POST /core/update` above: there is no jobs API, so `background:
  # true` is refused rather than faked, and Bandit's configured 900s
  # `read_timeout` (`Vagus.API.Supervisor`) is what bounds how long a caller
  # can wait — nothing in this router does.
  post "/store/addons/:slug/update" do
    handle_update(conn, slug)
  end

  # Upstream registers this route and its handler never reads the version
  # segment — it always updates to whatever the store currently advertises.
  # Matching the quirk beats inventing pinned-version semantics no client
  # sends; the segment is accepted and ignored on purpose, not by oversight.
  post "/store/addons/:slug/update/:version" do
    handle_update(conn, slug)
  end

  # Legacy alias, same as the install routes above.
  post "/addons/:slug/update" do
    handle_update(conn, slug)
  end

  post "/addons/:slug/start" do
    lifecycle_action(conn, slug, &Manager.start_slug/1)
  end

  post "/addons/:slug/stop" do
    lifecycle_action(conn, slug, &Manager.stop/1)
  end

  post "/addons/:slug/restart" do
    lifecycle_action(conn, slug, &Manager.restart/1)
  end

  # `{"remove_config": bool}` is accepted (Core's `AddonsOptions`/uninstall
  # payload) and ignored — this emulator has no separate "keep config"
  # retention to honor; `Manager.uninstall/2` always purges the data dir.
  post "/addons/:slug/uninstall" do
    lifecycle_action(conn, slug, &Manager.uninstall/1)
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

  # The frontend's config page calls this **before** every save and aborts on
  # anything other than `valid: true`, so without it the Save button fails
  # for every add-on — `supervisor-app-config.ts::_saveTapped` awaits
  # `validateHassioAddonOption` and throws its message before it ever POSTs
  # the options.
  #
  # Upstream shape (`api/apps.py::options_validate`): the body is the options
  # map **itself**, not `{"options": …}`, and an empty body falls back to the
  # add-on's stored options. Always HTTP 200 — invalid options are a `valid:
  # false` payload, not an error status. `pwned` is always `false` here:
  # upstream's have-i-been-pwned lookup needs an outbound API Vagus doesn't
  # make, and reporting `null` (its "check failed" value) would make Core
  # refuse the save whenever `sys_security.force` is on.
  post "/addons/:slug/options/validate" do
    handle_addon_options_validate(conn, slug)
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
  # X-Accel-Buffering headers. One-shot routes here; live `/follow`
  # streaming in the section below. Sourced from the engine's container
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

  # -- Logs: live `/follow` streaming (§A5) — chunked text/plain, connection
  # held open. Container families ride a per-connection Runtime.Logs.Follow
  # (docker --follow; its tail=N carries the backfill on the SAME stream, so
  # no separate backfill write — no gap, no duplication). The native broker
  # subscribes to its Broker.Logs buffer. Sourceless families stream an
  # honest empty body and close. ---------------------------------------------

  get "/addons/:slug/logs/follow" do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} -> follow_logs(conn, "addon_#{resolved}")
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
    end
  end

  get("/core/logs/follow", do: follow_logs(conn, core_container()))
  get("/supervisor/logs/follow", do: follow_logs(conn, supervisor_container()))
  get("/host/logs/follow", do: follow_logs(conn, nil))

  # /homeassistant/* is the contract's alias of /core/* (§A5).
  get("/homeassistant/logs", do: send_logs(conn, core_container()))
  get("/homeassistant/logs/latest", do: send_logs(conn, core_container(), no_colors: true))
  get("/homeassistant/logs/follow", do: follow_logs(conn, core_container()))

  # audio/dns/multicast: Vagus runs no dedicated plugin containers for these
  # families — every route streams/serves an honest empty body (§A5: a log
  # poll must not error).
  get("/audio/logs", do: send_logs(conn, nil))
  get("/audio/logs/latest", do: send_logs(conn, nil, no_colors: true))
  get("/audio/logs/follow", do: follow_logs(conn, nil))
  get("/dns/logs", do: send_logs(conn, nil))
  get("/dns/logs/latest", do: send_logs(conn, nil, no_colors: true))
  get("/dns/logs/follow", do: follow_logs(conn, nil))
  get("/multicast/logs", do: send_logs(conn, nil))
  get("/multicast/logs/latest", do: send_logs(conn, nil, no_colors: true))
  get("/multicast/logs/follow", do: follow_logs(conn, nil))

  # Boots (§A5): no journald on Nerves, so this device has exactly one boot —
  # bootid `0` (or our literal boot id) serves the current source, any other
  # offset/id is honestly empty. `/host/logs/boots` below reports the single
  # boot consistently.
  get("/host/logs/boots/:bootid", do: send_logs(conn, nil))
  get("/host/logs/boots/:bootid/follow", do: follow_logs(conn, nil))
  get("/core/logs/boots/:bootid", do: send_logs(conn, boot_ref(bootid, core_container())))

  get "/core/logs/boots/:bootid/follow" do
    follow_logs(conn, boot_ref(bootid, core_container()))
  end

  get "/homeassistant/logs/boots/:bootid" do
    send_logs(conn, boot_ref(bootid, core_container()))
  end

  get "/homeassistant/logs/boots/:bootid/follow" do
    follow_logs(conn, boot_ref(bootid, core_container()))
  end

  get "/supervisor/logs/boots/:bootid" do
    send_logs(conn, boot_ref(bootid, supervisor_container()))
  end

  get "/supervisor/logs/boots/:bootid/follow" do
    follow_logs(conn, boot_ref(bootid, supervisor_container()))
  end

  get "/addons/:slug/logs/boots/:bootid" do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} -> send_logs(conn, boot_ref(bootid, "addon_#{resolved}"))
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
    end
  end

  get "/addons/:slug/logs/boots/:bootid/follow" do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} -> follow_logs(conn, boot_ref(bootid, "addon_#{resolved}"))
      {:error, :forbidden} -> Envelope.send_error(conn, "Not authorized for this add-on", 403)
    end
  end

  get("/audio/logs/boots/:bootid", do: send_logs(conn, nil))
  get("/audio/logs/boots/:bootid/follow", do: follow_logs(conn, nil))
  get("/dns/logs/boots/:bootid", do: send_logs(conn, nil))
  get("/dns/logs/boots/:bootid/follow", do: follow_logs(conn, nil))
  get("/multicast/logs/boots/:bootid", do: send_logs(conn, nil))
  get("/multicast/logs/boots/:bootid/follow", do: follow_logs(conn, nil))

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
  # `enable` reflecting its `ingress_panel` toggle. §B1.4 explicitly does NOT
  # put this route in the ingress-proxy's no-security-check bypass — that
  # covers only the per-request proxy path `/ingress/{token}/.*` — so it goes
  # through normal token validation like every other route.
  #
  # It then needs `ROLE_ADMIN`, not merely a valid token (audit A5): upstream
  # lists no `/ingress/…` alternative in any role below admin
  # (`security.py` L129-158), so this falls through to `role_access[admin]`.
  # `Vagus.API.Tiers`' catch-all is that fallthrough, which is why there is no
  # entry for the route in its table and no guard here. The body carries no
  # secrets — `Vagus.Ingress.Panels.list/1` emits title/icon/admin/enable only
  # — but serving every installed add-on an inventory of the others is still a
  # disclosure upstream does not make.
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
  # (M4-P6-T2; §A4).
  #
  # Auth is `Vagus.API.Tiers`' `:backup` requirement for the whole family —
  # upstream's `ROLE_BACKUP` (`security.py` L123-128, `/backups.*`), which
  # `ROLE_MANAGER`/`ROLE_ADMIN` and Core also satisfy. These routes were
  # `supervisor_only/2` until the 2026-07-29 audit (finding A4): a backup
  # add-on declaring `hassio_role: backup` exists precisely to drive them, and
  # refusing it broke assumed behaviour. The two `/…/info` reads grade one
  # step lower still (`role_access[default]`'s `/.+/info`), exactly as
  # upstream does.

  get "/backups" do
    entries = Backups.list() |> Enum.map(&backup_list_entry/1)
    Envelope.send_ok(conn, %{backups: entries})
  end

  get "/backups/info" do
    entries = Backups.list() |> Enum.map(&backup_list_entry/1)
    Envelope.send_ok(conn, %{backups: entries, days_until_stale: 30})
  end

  get "/backups/:slug/info" do
    case Backups.get(slug) do
      {:ok, entry} -> Envelope.send_ok(conn, backup_info(entry))
      :error -> Envelope.send_error(conn, "Backup does not exist", 404)
    end
  end

  post "/backups/new/partial" do
    handle_backup_new_partial(conn, conn.body_params)
  end

  post "/backups/new/upload" do
    handle_backup_upload(conn)
  end

  post "/backups/:slug/restore/partial" do
    handle_backup_restore(conn, slug, conn.body_params)
  end

  get "/backups/:slug/download" do
    handle_backup_download(conn, slug)
  end

  delete "/backups/:slug" do
    case Backups.delete(slug) do
      :ok -> Envelope.send_ok(conn, %{})
      :error -> Envelope.send_error(conn, "Backup does not exist", 404)
    end
  end

  post "/backups/reload" do
    :ok = Backups.reload()
    Envelope.send_ok(conn, %{})
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

  # Unlike `GET|POST /auth`, this is NOT an `auth_api` grant route. Upstream
  # puts `/auth/cache` in `role_access[manager]` (`security.py` L135) and its
  # handler (`api/auth.py::cache`) makes no `access_auth_api` check at all —
  # so Core's own token works and a `hassio_role: default` add-on's does not,
  # whatever its `auth_api` flag says. Vagus had it exactly inverted (audit
  # A6/B2): an `auth_api: true` default-role add-on was admitted and Core was
  # refused with 403, so any Core-side flow clearing the Supervisor auth cache
  # failed. `Vagus.API.Tiers` now carries the whole check — `:manager` — and
  # there is nothing left for the handler to decide.
  delete "/auth/cache" do
    :ok = Vagus.Auth.reset_cache()
    Envelope.send_ok(conn, %{})
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

  # -- Core lifecycle (CL-P3-T1) ----------------------------------------------
  #
  # Every route here is supervisor-only (Core drives start/stop/restart/
  # rebuild/check/update from the frontend's Core dashboard; an add-on never
  # manages Core's lifecycle) — a non-supervisor caller gets a 403 before any
  # `Lifecycle`/`Health` call, via `supervisor_only/2` (same guard as the
  # `/backups...` routes).
  #
  # Every op funnels through `Vagus.Core.Lifecycle`'s single non-blocking
  # `:global.trans` mutex (see that module's moduledoc "Serialization"
  # section) — there is exactly one Core container, so a second lifecycle
  # call arriving while one is already in flight gets `{:error, :busy}` back
  # immediately rather than queueing; `core_lifecycle_error/2` maps that to
  # 409 below. `:core_lifecycle`/`:core_health` are per-request config seams
  # (default `Vagus.Core.Lifecycle`/`Vagus.Core.Health`), resolved the same
  # way `core_container/0` resolves its config value — tests inject a stub
  # module via `Application.put_env/3` instead of a real Docker socket/HTTP
  # probe. `/homeassistant/*` are the contract's alias of `/core/*` (same
  # convention as the logs routes above).
  #
  # `POST /core/update` can run for minutes — pulling a multi-GB Core image
  # on a slow device, then the health gate — this is a synchronous v1 (no
  # `background`/`job_id` job API yet, per the plan's "Locked decisions");
  # Bandit's configured 900s `read_timeout` (`Vagus.API.Supervisor`) is what
  # bounds how long a caller can wait, not anything in this router.

  post "/core/start" do
    core_lifecycle_action(conn, fn -> core_lifecycle().start() end)
  end

  post "/core/stop" do
    core_lifecycle_action(conn, fn -> core_lifecycle().stop() end)
  end

  post "/core/restart" do
    core_lifecycle_action(conn, fn -> core_lifecycle().restart() end)
  end

  post "/core/rebuild" do
    core_lifecycle_action(conn, fn -> core_lifecycle().rebuild() end)
  end

  post "/core/check" do
    core_check_action(conn)
  end

  post "/core/update" do
    core_update_action(conn)
  end

  post "/homeassistant/start" do
    core_lifecycle_action(conn, fn -> core_lifecycle().start() end)
  end

  post "/homeassistant/stop" do
    core_lifecycle_action(conn, fn -> core_lifecycle().stop() end)
  end

  post "/homeassistant/restart" do
    core_lifecycle_action(conn, fn -> core_lifecycle().restart() end)
  end

  post "/homeassistant/rebuild" do
    core_lifecycle_action(conn, fn -> core_lifecycle().rebuild() end)
  end

  post "/homeassistant/check" do
    core_check_action(conn)
  end

  post "/homeassistant/update" do
    core_update_action(conn)
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

  # -- Core lifecycle helpers (CL-P3-T1) --------------------------------------

  # `start`/`stop`/`restart`/`rebuild` all share this shape: no request body,
  # `:ok` -> ok envelope, `{:error, reason}` -> mapped status below.
  defp core_lifecycle_action(conn, fun) do
    supervisor_only(conn, fn ->
      case fun.() do
        :ok -> Envelope.send_ok(conn, %{})
        {:error, reason} -> send_core_lifecycle_error(conn, reason)
      end
    end)
  end

  defp core_check_action(conn) do
    supervisor_only(conn, fn ->
      case core_health().check() do
        :healthy -> Envelope.send_ok(conn, %{})
        :unhealthy -> Envelope.send_error(conn, "Core frontend probe failed", 400)
      end
    end)
  end

  # Body validated BEFORE touching `Lifecycle` — a malformed `version` must
  # never reach the lock/pull machinery. Absent/`nil` -> `update(nil)`
  # (`Lifecycle` resolves that to `Versions.latest/1`).
  defp core_update_action(conn) do
    supervisor_only(conn, fn ->
      case validate_core_update_version(conn.body_params) do
        {:ok, version} ->
          case core_lifecycle().update(version) do
            {:ok, installed} -> Envelope.send_ok(conn, %{version: installed})
            {:error, reason} -> send_core_lifecycle_error(conn, reason)
          end

        {:error, message} ->
          Envelope.send_error(conn, message, 400)
      end
    end)
  end

  @core_version_tag_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @core_version_max_len 128

  defp validate_core_update_version(params) do
    case Map.get(params, "version") do
      nil ->
        {:ok, nil}

      version when is_binary(version) ->
        if valid_core_version_tag?(version) do
          {:ok, version}
        else
          {:error,
           "version must be a docker-tag-shaped string (max #{@core_version_max_len} chars)"}
        end

      _not_a_string ->
        {:error, "version must be a string"}
    end
  end

  defp valid_core_version_tag?(version) do
    byte_size(version) <= @core_version_max_len and Regex.match?(@core_version_tag_re, version)
  end

  # `:busy` (the single-key `:global.trans` mutex, `Lifecycle` moduledoc) is
  # the one lifecycle error that isn't the caller's fault — a fast 409 tells
  # it to retry, rather than the 400 family every other lifecycle error uses.
  defp send_core_lifecycle_error(conn, :busy) do
    Envelope.send_error(conn, "a Core lifecycle operation is already in progress", 409)
  end

  defp send_core_lifecycle_error(conn, reason) do
    Envelope.send_error(conn, core_lifecycle_error_message(reason), 400)
  end

  defp core_lifecycle_error_message(:no_version), do: "No Core version is installed yet"

  defp core_lifecycle_error_message(:version_installed),
    do: "The requested version is already installed"

  defp core_lifecycle_error_message(:health_timeout),
    do: "Core did not become healthy in time"

  defp core_lifecycle_error_message({:pull, reason}),
    do: "Failed to pull the Core image: #{inspect(reason)}"

  defp core_lifecycle_error_message({:health_timeout, :rolled_back}),
    do: "Core update failed its health check; rolled back to the previous version"

  defp core_lifecycle_error_message({:health_timeout, :no_rollback_version}),
    do: "Core update failed its health check and there is no previous version to roll back to"

  defp core_lifecycle_error_message({:rollback_failed, reason}),
    do: "Core update failed its health check and the rollback also failed: #{inspect(reason)}"

  defp core_lifecycle_error_message({:recreate_failed, reason, :rolled_back}),
    do:
      "Failed to start the new Core version (#{inspect(reason)}): rolled back to the previous version"

  defp core_lifecycle_error_message({:recreate_failed, reason, :no_rollback_version}),
    do:
      "Failed to start the new Core version (#{inspect(reason)}): no previous version to roll back to"

  defp core_lifecycle_error_message(reason), do: inspect(reason)

  defp core_lifecycle, do: Application.get_env(:vagus, :core_lifecycle, Lifecycle)
  defp core_health, do: Application.get_env(:vagus, :core_health, Health)
  defp core_versions_server, do: Application.get_env(:vagus, :core_versions_server, Versions)

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

    case logs_accept(conn) do
      :error ->
        Envelope.send_error(conn, "Accept must be text/plain, text/x-log or */*", 400)

      {:ok, accept_verbose?} ->
        lines = log_lines(conn)
        verbose = accept_verbose? or Map.has_key?(conn.query_params, "verbose")

        no_colors =
          Map.has_key?(conn.query_params, "no_colors") or Keyword.get(opts, :no_colors, false)

        body = log_body(ref, lines, no_colors, verbose)

        conn
        |> put_resp_header("x-first-cursor", "0")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_content_type("text/plain")
        |> send_resp(200, body)
        |> halt()
    end
  end

  # §A5: `Accept` (when present) must be text/plain, text/x-log or `*/*`,
  # else 400; text/x-log additionally selects the verbose line format.
  defp logs_accept(conn) do
    case get_req_header(conn, "accept") do
      [] ->
        {:ok, false}

      [accept | _rest] ->
        types =
          accept
          |> String.split(",")
          |> Enum.map(fn t ->
            t |> String.split(";") |> hd() |> String.trim() |> String.downcase()
          end)

        cond do
          "text/x-log" in types -> {:ok, true}
          Enum.any?(types, &(&1 in ["text/plain", "*/*"])) -> {:ok, false}
          true -> :error
        end
    end
  end

  defp log_body(nil, _lines, _no_colors, _verbose), do: ""

  # Native "virtual add-ons" have no container — serve the broker's telemetry log
  # buffer (already text/plain, one entry per line) instead of Docker logs.
  # Verbose for native/broker lines is the plain line with the host/ident
  # prefix (no per-line source timestamp exists — documented approximation).
  defp log_body(ref, lines, no_colors, verbose) do
    if Native.running?(ref) do
      raw = Native.logs(ref, lines: lines)

      if verbose do
        Enum.map_join(raw, "\n", &Logs.verbose_line(&1, log_host(), ref))
      else
        Enum.join(raw, "\n")
      end
    else
      # verbose rides docker's own per-line RFC3339 stamps (timestamps=true).
      case Docker.container_logs(ref, tail: lines, timestamps: verbose) do
        {:ok, raw} -> raw |> Logs.format(no_colors: no_colors) |> maybe_verbose_body(ref, verbose)
        {:error, _reason} -> ""
      end
    end
  end

  defp maybe_verbose_body(text, _ref, false), do: text

  defp maybe_verbose_body(text, ref, true) do
    host = log_host()

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> Logs.verbose_line(line, host, ref)
    end)
  end

  defp log_host do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end

  # bootid `0` (or this device's literal single boot id) is the current
  # boot; any other offset/id has no journal behind it — honest empty.
  defp boot_ref("0", ref), do: ref
  defp boot_ref("vagus", ref), do: ref
  defp boot_ref(_other, _ref), do: nil

  defp log_lines(conn) do
    case Integer.parse(Map.get(conn.query_params, "lines", "100")) do
      {n, _} when n >= 2 -> n
      _ -> 100
    end
  end

  # -- follow (live streaming) helpers ---------------------------------------

  # §A5 `/logs/follow`: required headers, chunked 200, then hold the
  # connection streaming the source until it ends, the client disconnects
  # (`chunk/2 → {:error, _}`, the ingress_proxy pattern), or the idle window
  # elapses. A nil/unavailable source streams an honest empty body and
  # closes — a log poll must not error (matches send_logs/3).
  defp follow_logs(conn, ref, opts \\ []) do
    conn = fetch_query_params(conn)

    case logs_accept(conn) do
      :error ->
        Envelope.send_error(conn, "Accept must be text/plain, text/x-log or */*", 400)

      {:ok, accept_verbose?} ->
        do_follow_logs(conn, ref, accept_verbose?, opts)
    end
  end

  defp do_follow_logs(conn, ref, accept_verbose?, opts) do
    lines = log_lines(conn)
    verbose = accept_verbose? or Map.has_key?(conn.query_params, "verbose")

    fmt = %{
      no_colors:
        Map.has_key?(conn.query_params, "no_colors") or Keyword.get(opts, :no_colors, false),
      verbose: verbose,
      host: log_host(),
      ident: ref || "host",
      buf: ""
    }

    conn =
      conn
      |> put_resp_header("x-first-cursor", "0")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/plain")
      |> send_chunked(200)

    case follow_source(ref, lines, verbose) do
      :none ->
        halt(conn)

      {:native, logs_pid, backfill} ->
        case write_backfill(conn, backfill, fmt) do
          {:ok, conn} ->
            stream_loop(conn, {:native, logs_pid}, fmt)

          {:error, _reason} ->
            teardown({:native, logs_pid})
            halt(conn)
        end

      {:docker, _follow_pid} = source ->
        stream_loop(conn, source, fmt)
    end
  end

  defp follow_source(nil, _lines, _verbose), do: :none

  defp follow_source(ref, lines, verbose) do
    if Native.running?(ref) do
      case Native.logs_server(ref) do
        nil ->
          :none

        logs_pid ->
          # Subscribe BEFORE tailing so no line is lost between backfill and
          # live; both calls hit the SAME pid (not a fresh logs_server
          # lookup — a broker restart between the two would split them
          # across incarnations; Copilot review, PR #6) and serialize
          # through that GenServer, so the worst case is one line appearing
          # in both (preferred over a silent gap).
          :ok = Broker.Logs.subscribe(logs_pid)
          {:native, logs_pid, Broker.Logs.tail(logs_pid, lines)}
      end
    else
      # Linked on purpose: if this request process dies abnormally, the link
      # (plus the owner monitor inside Follow) guarantees the held docker
      # connection dies with it. Backfill rides the docker stream (tail=N);
      # verbose rides docker's per-line stamps (timestamps=true).
      {:ok, pid} =
        Logs.Follow.start_link(owner: self(), ref: ref, tail: lines, timestamps: verbose)

      {:docker, pid}
    end
  end

  defp write_backfill(conn, [], _fmt), do: {:ok, conn}

  defp write_backfill(conn, lines, fmt) do
    chunk(conn, Enum.map_join(lines, "", &render_line(&1, fmt)))
  end

  defp stream_loop(conn, source, fmt) do
    receive do
      {:log_chunk, data} ->
        {out, fmt} = render_stream(data, fmt)
        deliver_chunk(conn, out, source, fmt, _ack? = true)

      {:broker_log, line} ->
        deliver_chunk(conn, render_line(line, fmt), source, fmt, _ack? = false)

      :log_eof ->
        flush_tail(conn, fmt)
    after
      follow_idle_ms() ->
        teardown(source)
        flush_tail(conn, fmt)
    end
  end

  # An all-buffered (verbose partial-line) chunk still needs its ack or the
  # Follow process would stall waiting for one.
  defp deliver_chunk(conn, "", source, fmt, ack?) do
    if ack?, do: Logs.Follow.ack(source_pid(source))
    stream_loop(conn, source, fmt)
  end

  defp deliver_chunk(conn, data, source, fmt, ack?) do
    case chunk(conn, data) do
      {:ok, conn} ->
        if ack?, do: Logs.Follow.ack(source_pid(source))
        stream_loop(conn, source, fmt)

      {:error, _reason} ->
        # The client hung up mid-stream — tear the source down so the held
        # docker connection / broker subscription doesn't leak (risk #2).
        teardown(source)
        halt(conn)
    end
  end

  # Verbose mode may hold a final partial line; write it before closing.
  defp flush_tail(conn, %{buf: ""}), do: halt(conn)

  defp flush_tail(conn, %{buf: buf} = fmt) do
    case chunk(conn, render_line(buf, %{fmt | buf: ""})) do
      {:ok, conn} -> halt(conn)
      {:error, _reason} -> halt(conn)
    end
  end

  defp source_pid({_kind, pid}), do: pid

  defp teardown({:docker, pid}) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  # Best-effort like the docker branch: the broker (and its Logs process)
  # can restart/stop while a follow is open — unsubscribing a dead server
  # exits :noproc, and the subscription died with the server anyway.
  defp teardown({:native, logs_pid}) do
    Broker.Logs.unsubscribe(logs_pid)
  catch
    :exit, _ -> :ok
  end

  # Plain mode passes docker chunks through untouched (bar the ANSI strip —
  # NOTE: an escape split across two chunks can evade it; cosmetic, accepted).
  # Verbose mode line-buffers so the §A5 prefix lands on whole lines even
  # when docker chunks split them; the buffered remainder is capped so a
  # no-newline stream can't balloon memory.
  defp render_stream(data, %{verbose: false} = fmt) do
    {maybe_strip(data, fmt.no_colors), fmt}
  end

  defp render_stream(data, fmt) do
    buffer = fmt.buf <> maybe_strip(data, fmt.no_colors)
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)

    out =
      Enum.map_join(complete, "", fn
        "" -> "\n"
        line -> render_line(line, fmt)
      end)

    if byte_size(rest) > Logs.max_pending() do
      {out <> render_line(rest, fmt), %{fmt | buf: ""}}
    else
      {out, %{fmt | buf: rest}}
    end
  end

  defp render_line(line, %{verbose: true} = fmt) do
    Logs.verbose_line(line, fmt.host, fmt.ident) <> "\n"
  end

  defp render_line(line, _fmt), do: line <> "\n"

  defp maybe_strip(data, true), do: Logs.strip_ansi(data)
  defp maybe_strip(data, false), do: data

  # Test seam: production keeps a quiet-but-healthy follow open for 15 min
  # (aligned with Bandit's read_timeout, api/supervisor.ex); tests shrink it
  # so the otherwise-endless native stream ends deterministically.
  defp follow_idle_ms, do: Application.get_env(:vagus, :follow_idle_ms, 900_000)

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
    |> Enum.map(fn {slug, entry} ->
      installed = installed_entry(slug)
      StoreView.summary(slug, entry, installed?(installed), installed_version(installed))
    end)
  end

  # Store slugs and installed-state slugs share the same namespace
  # (`core_mosquitto` both in the catalog and in `Vagus.Addon.State`).
  # One `State` lookup per slug, not one per question. `GET /store/addons`
  # renders the whole catalog, so asking twice per entry doubles the
  # synchronous GenServer calls on the widest read path in the API.
  defp installed_entry(store_slug) do
    case State.get(store_slug) do
      {:ok, entry} -> entry
      :error -> nil
    end
  end

  defp installed?(nil), do: false
  defp installed?(_entry), do: true

  # The version of the locally installed copy, or nil if it isn't installed.
  #
  # An installed entry's `config` is the one captured at install time —
  # `Vagus.Addon.State` never refreshes it from the store catalog (every
  # `State.put/3` call site outside install/update passes a config that came
  # back out of `State`), so `config.version` is the installed version by
  # construction, with no second field to keep in sync.
  defp installed_version(nil), do: nil
  defp installed_version(%{config: %{version: version}}), do: version

  # What the store currently advertises for an installed add-on: its version
  # and its asset presence flags, in ONE catalog lookup. A detached add-on
  # (installed, but its repository no longer lists it) yields `nil` + `%{}`,
  # which renders as "no update available" and "no assets" rather than as an
  # error.
  defp store_facts(store_slug) do
    case Store.get(store_slug) do
      {:ok, %{config: %{version: version}} = entry} -> {version, Map.get(entry, :assets) || %{}}
      :error -> {nil, %{}}
    end
  end

  # The Repository wire shape (slug/name/source/url/maintainer, all strings).
  defp store_repositories do
    Enum.map(Store.repositories(), &StoreView.repository/1)
  end

  # -- store asset helpers (P2-A P4) ------------------------------------------

  # icon/logo: `image/png` + bytes, or upstream's exact absent shape.
  defp send_image_asset(conn, slug, kind) do
    conn = security_headers(conn, kind)

    with {:ok, id, handle} <- resolve_asset(slug),
         {:ok, binary} <- Assets.get(id, kind, handle) do
      conn |> put_resp_content_type("image/png", nil) |> send_resp(200, binary) |> halt()
    else
      _not_found -> missing_image_asset(conn, kind, slug)
    end
  end

  defp missing_image_asset(conn, kind, slug) do
    conn
    |> put_resp_content_type("application/octet-stream", nil)
    |> send_resp(400, "No #{asset_label(kind)} found for addon #{slug}!")
    |> halt()
  end

  # changelog/documentation: `text/plain`, ALWAYS 200 (see the route
  # comments above for the upstream rationale).
  defp send_text_asset(conn, slug, kind) do
    supervisor_only(conn, fn ->
      conn = security_headers(conn, kind)

      with {:ok, id, handle} <- resolve_asset(slug),
           {:ok, binary} <- Assets.get(id, kind, handle) do
        conn |> put_resp_content_type("text/plain") |> send_resp(200, binary) |> halt()
      else
        _not_found -> missing_text_asset(conn, kind, slug)
      end
    end)
  end

  defp missing_text_asset(conn, kind, slug) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "No #{asset_label(kind)} found for addon #{slug}!")
    |> halt()
  end

  defp asset_label(:icon), do: "icon"
  defp asset_label(:logo), do: "logo"
  defp asset_label(:changelog), do: "changelog"
  defp asset_label(:documentation), do: "documentation"

  # `X-Content-Type-Options: nosniff` on every asset response; icon/logo also
  # get a restrictive CSP. Defence in depth behind `Assets.put/4`'s magic-byte
  # check: `nosniff` alone doesn't help if the declared type is wrong, and the
  # magic-byte check alone doesn't help against a PNG/HTML polyglot that still
  # starts with a valid PNG signature.
  defp security_headers(conn, kind) when kind in [:icon, :logo] do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
  end

  defp security_headers(conn, _kind) do
    put_resp_header(conn, "x-content-type-options", "nosniff")
  end

  # Installed add-ons are recorded under the STORE slug (`handle_install`
  # rewrites `config.slug` before persisting — see `Vagus.Addon.Store`'s
  # moduledoc), so `slug` here is already a store slug regardless of which of
  # the four routes it came in on, and `Store.get/1` is the exact lookup.
  # `Assets.id/1` then derives the `{repo_slug, addon_slug}` pair the asset
  # store is actually keyed on from the resolved catalog entry.
  #
  # A detached add-on (installed, but its repository no longer lists it under
  # this slug) simply isn't in the catalog, so this reports `:error` exactly
  # like a slug that was never installed — matching upstream's `with_icon =
  # False` when `app_store is None`. A bogus/traversal slug never reaches
  # `Assets` at all: it just fails this `Store.get/1` lookup.
  # One `Store` round-trip, not two — these routes take no token, so every
  # request is unauthenticated load on the singleton. See
  # `Vagus.Addon.Store.asset_lookup/2`.
  defp resolve_asset(slug), do: Store.asset_lookup(slug)

  # The add-on's README.md as a string, for the `long_description` the frontend
  # renders as the body of its page. Read per detail request rather than held
  # in the catalog: it is the largest asset an add-on ships, only two routes
  # want it, and in `:disk` mode holding 80 of them resident is exactly what
  # that mode exists to avoid. A missing README (or a detached add-on, which
  # has no store entry to look one up from) is `nil`, same as upstream.
  defp long_description(slug) do
    with {:ok, id, handle} <- resolve_asset(slug),
         {:ok, binary} <- Assets.get(id, :readme, handle) do
      utf8_scrub(binary)
    else
      _absent -> nil
    end
  end

  # A README arrives as whatever bytes a third-party repository tarball
  # carried, and this one goes into a **JSON** response — `Jason.encode!/1`
  # raises on invalid UTF-8, which would turn one add-on's Latin-1 README into
  # a 500 on its store page. The other text assets are served as `text/plain`
  # and never hit an encoder, so this is the only read that needs it.
  #
  # Replace rather than reject: upstream reads the file with
  # `errors="replace"` (`AppModel.long_description`), so a README with a few
  # bad bytes still renders, minus those bytes. Dropping to `nil` would blank
  # a page that upstream shows. One U+FFFD per bad byte, matching Python.
  defp utf8_scrub(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: binary |> scrub_bytes([])
  end

  defp scrub_bytes(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scrub_bytes(<<char::utf8, rest::binary>>, acc),
    do: scrub_bytes(rest, [<<char::utf8>> | acc])

  defp scrub_bytes(<<_bad::8, rest::binary>>, acc), do: scrub_bytes(rest, ["�" | acc])

  # -- addon lifecycle helpers ------------------------------------------------

  # `GET /addons` entry: the same live options `/addons/{slug}/info` reports,
  # rendered through `Vagus.Addon.Info.render/4`.
  defp addon_list_entry(%{config: config, state: state} = entry) do
    Vagus.Addon.Info.render(config, state, live_options(entry), info_settings(entry))
  end

  # What an add-on's options ARE right now: the config's defaults with the
  # user's saved options merged over them (`App.options` upstream, same
  # deepmerge).
  #
  # NOT `/data/options.json`. That file is an *output* — `Manager.start/2`
  # writes it for the container — so reading it back reports whatever the
  # add-on was last started with: the config defaults for an add-on that has
  # never run, and stale values for one whose options changed since. The
  # Configuration page re-renders from this field right after saving, so a
  # save the user just made came back as the default and the form appeared to
  # clear itself.
  defp live_options(%{config: config, user_options: user_options}) do
    OptionsSchema.merge(config.options, user_options || %{})
  end

  # `Vagus.Addon.Info.render/4`'s `settings` param: the State entry's
  # ingress/watchdog fields (minus `config`/`state`/`user_options`), plus the
  # store's current version so `update_available` can be real and its asset
  # flags so the frontend knows to fetch the icon.
  defp info_settings(%{config: config} = entry) do
    {version_latest, assets} = store_facts(config.slug)

    entry
    |> Map.take([:ingress_token, :ingress_port, :ingress_panel, :watchdog])
    |> Map.put(:version_latest, version_latest)
    |> Map.put(:assets, assets)
    |> Map.put(:ports, Map.get(entry, :ports) || %{})
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

  # `POST /store/addons/{slug}/update` (+ the `/update/{version}` and legacy
  # `/addons/...` forms). Body is `{"backup": bool?, "background": bool?}`;
  # unknown keys are ignored, matching the aiohttp tolerance the request
  # parsing already assumes elsewhere in this router.
  defp handle_update(conn, slug) do
    supervisor_only(conn, fn ->
      cond do
        not valid_slug?(slug) ->
          Envelope.send_error(conn, "Addon #{slug} does not exist", 404)

        # Upstream raises APIForbidden when an add-on asks to update itself.
        #
        # NOT REACHABLE, and deliberately kept anyway: `supervisor_only/2`
        # above already rejects every add-on caller, so this cannot fire while
        # that holds. It is also why there is no test for it — an add-on
        # caller gets 403 from `supervisor_only/2` regardless, so such a test
        # would pass with this clause deleted and prove nothing. Kept as an
        # explicit statement of the contract in case this route's auth tier is
        # ever widened.
        self_update?(conn, slug) ->
          # Upstream's own wording, in its V1 "addon" form (dev-HEAD says
          # "App" only because of the in-flight rename):
          # `APIForbidden(f"App {app.slug} can't update itself!")`.
          Envelope.send_error(conn, "Addon #{slug} can't update itself!", 403)

        background?(conn) ->
          Envelope.send_error(
            conn,
            "background updates are not supported; omit \"background\" or send false",
            400
          )

        true ->
          send_update_result(conn, slug, Update.update(slug, backup: backup?(conn)))
      end
    end)
  end

  defp self_update?(conn, slug), do: match?({:addon, %{slug: ^slug}}, conn.assigns.caller)

  defp background?(conn), do: Map.get(conn.body_params, "background") == true
  defp backup?(conn), do: Map.get(conn.body_params, "backup") == true

  defp send_update_result(conn, _slug, {:ok, _result}), do: Envelope.send_ok(conn, %{})

  # Mirrors `send_core_lifecycle_error/2`'s shape: `:busy` is the only 409,
  # "it isn't there" is 404, everything else is a 400 with an honest message.
  defp send_update_result(conn, slug, {:error, reason}) do
    case reason do
      :busy ->
        Envelope.send_error(conn, "an operation is already in progress for #{slug}", 409)

      :not_installed ->
        Envelope.send_error(conn, "Addon #{slug} is not installed", 404)

      :not_in_store ->
        Envelope.send_error(conn, "Addon #{slug} is no longer available in the store", 404)

      other ->
        Envelope.send_error(conn, update_error_message(other), 400)
    end
  end

  defp update_error_message(:no_update_available), do: "No update available for this addon"

  # `reason` is already a human-readable string from `OptionsSchema`
  # (`{:error, String.t()}`), so `inspect/1` would only wrap it in escaped
  # quotes in the API response.
  defp update_error_message({:invalid_options, reason}),
    do: "Options are not valid for the new version: #{reason}"

  defp update_error_message({:pull, reason}),
    do: "Failed to pull the addon image: #{inspect(reason)}"

  defp update_error_message({:stop, reason}),
    do: "Failed to stop the addon before updating: #{inspect(reason)}"

  defp update_error_message({:backup_failed, reason}),
    do: "Pre-update backup failed, addon left untouched: #{inspect(reason)}"

  defp update_error_message({:rolled_back, cause}),
    do: "Update failed (#{inspect(cause)}); the previous version was restored"

  defp update_error_message({:rollback_failed, reason}),
    do: "Update failed AND the rollback failed (#{inspect(reason)}); the addon is stopped"

  defp update_error_message(other), do: inspect(other)

  # Shared caller guard + result mapping for start/stop/restart/uninstall —
  # all four share the same `:ok | {:ok, _} | {:error, :not_found} |
  # {:error, reason}` result shape.
  #
  # `resolve_info_slug/2` rather than `supervisor_only/2` (audit A3): upstream's
  # `api_bypass` is `/addons/self/(?!security|update)[^/]+` (`security.py`
  # L97), so an add-on may start, stop, restart, reconfigure and uninstall
  # **itself** using the literal slug `self`, and `Vagus.API.Tiers` admits
  # exactly that path. Any other slug from an add-on caller is `:supervisor`
  # in the table, so this resolver only ever sees `self` or Core — but it is
  # what maps `self` onto the caller's own slug, and it is the guard if the
  # table is ever widened. Core still reaches any slug.
  defp lifecycle_action(conn, slug, fun) do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} ->
        case fun.(resolved) do
          :ok ->
            Envelope.send_ok(conn, %{})

          {:ok, _} ->
            Envelope.send_ok(conn, %{})

          {:error, :not_found} ->
            Envelope.send_error(conn, "Addon #{resolved} does not exist", 404)

          {:error, reason} ->
            Envelope.send_error(conn, inspect(reason), 400)
        end

      {:error, :forbidden} ->
        Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  # Same `self`-resolution as `lifecycle_action/3` — `/addons/self/options` is
  # one segment, so upstream bypasses it. Note the deliberate asymmetry with
  # `handle_addon_options_validate/2` below, which stays supervisor-only:
  # `/addons/self/options/validate` is *two* segments and so falls outside
  # `[^/]+`. That is upstream's own shape, not an oversight here.
  defp handle_addon_options(conn, slug) do
    case resolve_info_slug(slug, conn.assigns.caller) do
      {:ok, resolved} ->
        case State.get(resolved) do
          :error ->
            Envelope.send_error(conn, "Addon #{resolved} does not exist", 404)

          {:ok, %{config: config}} ->
            apply_addon_options(conn, resolved, config, conn.body_params)
        end

      {:error, :forbidden} ->
        Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  # Same auth and same lookup as `handle_addon_options/2` — this is a dry run
  # of that route, so anything it would reject must be rejected here too.
  defp handle_addon_options_validate(conn, slug) do
    if conn.assigns.caller == :supervisor do
      case State.get(slug) do
        :error ->
          Envelope.send_error(conn, "Addon #{slug} does not exist", 404)

        {:ok, entry} ->
          conn
          |> Envelope.send_ok(validate_options_report(entry, conn.body_params))
      end
    else
      Envelope.send_error(conn, "unauthorized", 403)
    end
  end

  # Deliberately routed through the very same `OptionsSchema.effective/3` call
  # the save path uses (`validate_options_key/2`), so the dry run and the real
  # write can never disagree — a "valid" answer followed by a 400 on save is
  # the one outcome this endpoint exists to prevent.
  defp validate_options_report(%{config: config} = entry, body) do
    options = if is_map(body) and map_size(body) > 0, do: body, else: live_options(entry)

    case OptionsSchema.effective(config.schema, config.options, options) do
      {:ok, _validated} -> %{"valid" => true, "message" => "", "pwned" => false}
      {:error, message} -> %{"valid" => false, "message" => message, "pwned" => false}
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
         {:ok, ingress_panel_action} <- validate_ingress_panel_key(body),
         {:ok, network_action} <- validate_network_key(body, config) do
      apply_options_action(slug, options_action)
      apply_watchdog_action(slug, config, watchdog_action)
      apply_ingress_panel_action(slug, ingress_panel_action)
      apply_network_action(slug, network_action)
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

  # The Network card posts `{"network": {"22/tcp": 2222}}` to this same
  # endpoint. Before this it fell into the accept-and-ignore bucket with the
  # unmodeled SCHEMA_OPTIONS keys, so the UI reported a successful save and
  # the port never moved — worse than a 400, which the frontend would at
  # least have surfaced.
  #
  # `null` resets to the config's defaults by dropping the overrides, matching
  # upstream's setter (`self.persist.pop(ATTR_NETWORK)`); a map is narrowed by
  # `Ports.sanitize/2`, which forgets ports the config doesn't declare and
  # rejects a value that isn't a port.
  defp validate_network_key(body, config) do
    case Map.fetch(body, "network") do
      :error ->
        {:ok, :none}

      {:ok, nil} ->
        {:ok, :reset}

      {:ok, posted} when is_map(posted) ->
        with {:ok, p} <- Ports.sanitize(config, posted), do: {:ok, {:set, p}}

      {:ok, _other} ->
        {:error, "network must be an object or null"}
    end
  end

  defp apply_network_action(_slug, :none), do: :ok
  defp apply_network_action(slug, :reset), do: State.put_setting(slug, :ports, %{})
  defp apply_network_action(slug, {:set, ports}), do: State.put_setting(slug, :ports, ports)

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

  # Shared supervisor-only-caller guard for the `/core...`/`/homeassistant...`
  # lifecycle routes and the store install/update routes — Core drives its own
  # lifecycle and the addon dashboard from the frontend, an add-on never
  # manages either.
  #
  # Redundant with `Vagus.API.Tiers`' `:supervisor` requirement for the same
  # paths, and deliberately kept: the table is a coarse pre-filter over
  # `path_info`, this is the handler asserting its own contract. Belt and
  # braces is the right posture for the routes that stop and rebuild Core.
  # (The `/backups...` routes no longer use it — see audit A4.)
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
  # `Plug.Parsers` — by the time this runs, `Vagus.API.Auth` has authenticated
  # the caller AND graded it against `Vagus.API.Tiers`, so the
  # 256MB/disk-spooling multipart parse only ever happens for a caller that
  # cleared the `/backups.*` requirement. The body is still unread at this
  # point (the router-wide parser passed it through, `pass: ["*/*"]`), so
  # `parse_multipart/1` is reading it for the first time.
  #
  # That requirement is `:backup`, NOT supervisor-only — it was the latter
  # until the 2026-07-29 audit's A4, and an earlier version of this comment
  # still claimed `supervisor_only/2` gated the route. It does not. A
  # `hassio_role: backup` add-on reaches here, which is upstream's own tier
  # and deliberate, so the spool is bounded by `Backups.acquire_upload_slot/1`
  # instead: one in-flight upload at a time, rather than N × 256MB of
  # concurrent disk spooling on a 1GB device. The size limit itself is phase
  # 4's to revisit against a real HAOS backup.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp handle_backup_upload(conn) do
    case Backups.acquire_upload_slot() do
      :ok ->
        try do
          do_backup_upload(conn)
        after
          Backups.release_upload_slot()
        end

      :busy ->
        Envelope.send_error(conn, "another backup upload is already in progress", 429)
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp do_backup_upload(conn) do
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
  # with the message minus `config` (`app`→`addon`). Shared with the native
  # broker's provider via `Vagus.Discovery.Push` — see that module for the
  # `no_refresh_token`/best-effort semantics.
  defp push_discovery(method, message), do: Vagus.Discovery.Push.push(method, message)

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
