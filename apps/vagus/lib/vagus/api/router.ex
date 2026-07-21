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

  # Fetched by hassio's discovery setup at every Core boot (observed on
  # device 2026-07-20: 404 here logs "Can't read discover info: not found").
  # Raw-dict path — `data["discovery"]` is a list of add-on service
  # discovery messages; honestly empty with no add-ons.
  get "/discovery" do
    Envelope.send_ok(conn, %{discovery: []})
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
end
