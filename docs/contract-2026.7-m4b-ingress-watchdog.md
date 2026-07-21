# Supervisor API Contract — M4b Ingress + Watchdog surface (addendum)

Extends `docs/contract-2026.7.md` and `docs/contract-2026.7-m4-addendum.md` with
the wire contract needed to run the **ESPHome add-on's ingress panel** end to
end, and the **watchdog** (container-event + application-probe) behavior.

Pinned 2026-07-21 from real source via the `ha-github-search` MCP (repos
`supervisor`, `core`, `esphome`). Every non-obvious claim cites `repo:path:line`
or `repo:path:symbol` for large files. Uncertain claims are marked `[VERIFY]`.

**Read `docs/contract-2026.7-m4-addendum.md` §A0 first.** Its findings still
apply verbatim here: the indexed `supervisor` is dev-HEAD
(`SUPERVISOR_VERSION = "9999.09.9.dev9999"`, `supervisor/const.py:14`), mid
`addon`→`app` rename (module `supervisor/apps/`, class `App`/`AppModel`,
`DockerApp`), and split V1 (`/addons/*`, legacy `addon` key, default) / V2
(`/apps/*`, `app` key, off by default) APIs. **Target V1** — same rule applies
here. One correction/refinement discovered while pinning this surface: **the
single-app `info` payload is NOT re-keyed between V1 and V2** — only the
list-endpoint wrapper key differs (`addons` vs `apps`, `supervisor/api/apps.py:
_register_apps` routes both `/addons/{app}/info` and `/apps/{app}/info` to the
same `info_data()` builder, `supervisor/api/__init__.py:614-632`,`689`). Field
names inside the info dict (`ingress_port`, `ingress_url`, `watchdog`, …) are
identical in both API versions.

---

## B1. Ingress session lifecycle

### B1.1 `POST /ingress/session` — Core-only

`supervisor/api/ingress.py:113-124` `create_session`, decorated
`@require_home_assistant` (`api/utils.py:95-103`): the wrapper checks
`request[REQUEST_FROM] != coresys.homeassistant` and raises `HTTPUnauthorized`
otherwise — **only a request authenticated as Core's own Supervisor token**
may create a session. This is on top of the normal `token_validation`
middleware (`api/middleware/security.py`), which the create/validate-session
paths do NOT bypass (only the per-request proxy path `/ingress/{token}/.*`
is in the middleware's `no_security_check` list — see B2).

Optional request body `SCHEMA_INGRESS_CREATE_SESSION_DATA`
(`api/ingress.py:44-48`): `{"session_data_user_id": <str>}`. If present,
Supervisor resolves the HA user via `sys_homeassistant.list_users()`
(`api/ingress.py:229-236 _find_user_by_id`) and, if found, attaches
`IngressSessionData(user)` to the session.

Session token: `secrets.token_hex(64)` → **128 hex chars**
(`supervisor/ingress.py:127`). TTL: `utcnow() + timedelta(minutes=15)`
(`ingress.py:128`). Response: `{"session": "<token>"}` (`ATTR_SESSION`).

Persistence — `ingress.json` (`FILE_HASSIO_INGRESS`, `const.py:38`), schema
`SCHEMA_INGRESS_CONFIG` (`supervisor/validate.py:278-286`):
```json
{
  "session": { "<128-hex-token>": <expiry-unix-float> },
  "session_data": { "<token>": { "user": { "id": "...", "username": "...", "name": "..." } } },
  "ports": { "<app-slug>": <int> }
}
```
Token key pattern in schema: `token = vol.Match(r"^[0-9a-f]{32,256}$")`
(`supervisor/validate.py:106`).

### B1.2 `POST /ingress/validate_session` — Core-only, and **renews**

`api/ingress.py:126-133`, also `@require_home_assistant`. Body
`VALIDATE_SESSION_DATA = {"session": str}` (`api/ingress.py:41-42`). Calls
`sys_ingress.validate_session(token)`; 401 if invalid. Returns `None` (200,
empty `data`) on success.

**`Ingress.validate_session`** (`supervisor/ingress.py:139-156`) is a
**sliding-window renewal**, not a fixed-TTL check: on every successful call it
sets `self.sessions[session] = (valid_until + timedelta(minutes=15)).timestamp()`
— i.e. it extends validity by another 15 minutes from *now*, not from
creation. Malformed/overflowed timestamps are tolerantly reset to a fresh
15-minute window rather than treated as invalid (`ingress.py:148-151`).

**Crucially, every proxied ingress request also calls `validate_session`**
(`api/ingress.py:143-147`, inside `handler()`), so the 15-minute window renews
on every single page/asset/WS request through the panel — a session only
expires after **15 minutes of the panel being completely idle**, not 15
minutes after creation. Expired sessions are purged lazily on
`Ingress.load()`/`reload()` (`_cleanup_sessions`, `ingress.py:87-110`), which
runs at Supervisor startup and every `RUN_RELOAD_INGRESS` tick (930s,
`misc/tasks.py:43`,`87`).

### B1.3 The `ingress_session` cookie

Name: `COOKIE_INGRESS = "ingress_session"` (`supervisor/api/const.py:13`).
Read via `request.cookies.get(COOKIE_INGRESS, "")` in
`APIIngress.handler` (`api/ingress.py:146`). **Supervisor never sets this
cookie** — grep of `api/ingress.py` shows no `set_cookie`/`Set-Cookie` call
anywhere; Supervisor only *reads* it. `[VERIFY]`: the cookie must be set by
Core or the frontend after a session is created (the frontend calls
`POST /ingress/session` via Core's `hassio` WS/REST proxy, then presumably
sets the cookie itself before loading the iframe) — this addendum did not
locate the cookie-setting code (not in the indexed `supervisor`/`core`
Python; likely frontend TypeScript, not indexed here).

### B1.4 The proxy path bypasses the token middleware entirely

`api/middleware/security.py`'s `no_security_check` regex (V1:
`~line 155-165`) includes `/ingress/[-_A-Za-z0-9]+/.*` — the actual
`/ingress/{token}/{path}` proxy route **skips `token_validation` completely**
(sets `request[REQUEST_FROM] = None`, `security.py` `token_validation`
early-return). Authentication for actual proxied traffic is **100% the
`ingress_session` cookie check** inside `APIIngress.handler`
(`api/ingress.py:141-148`), not the `X-Supervisor-Token`/`Authorization`
header used by every other endpoint. `/ingress/session`,
`/ingress/validate_session`, and `/ingress/panels` are NOT in that bypass
list and go through normal token validation (Core's token specifically for
the first two, via `@require_home_assistant`).

---

## B2. Request path chain, headers, streaming, WebSocket relay

Chain: browser → Core `GET/POST/.../ANY /api/hassio_ingress/{token}/{path:.*}`
→ Supervisor `ANY /ingress/{token}/{path:.*}` → add-on
`http://{container_ip}:{ingress_port}/{path}`.

### B2.1 Core side (`homeassistant/components/hassio/ingress.py`)

`HassIOIngress` view, `url = "/api/hassio_ingress/{token}/{path:.*}"`,
**`requires_auth = False`** (line 64-67) — Core's own auth is bypassed for
this route entirely; ingress has its own session mechanism (B1).

`{token}` in the URL is literally `App.ingress_token`
(`supervisor/apps/app.py:561-563`) — the per-add-on ingress token, distinct
from `access_token`/`supervisor_token`. Core learns it from the info API's
`ingress_entry`/`ingress_url` fields (`/api/hassio_ingress/{ingress_token}/`,
`apps/app.py:566-570`,`634-639`) and never generates or validates it itself.

`_create_url` (core `ingress.py:79-89`): builds
`http://{SUPERVISOR_HOST}/ingress/{token}/{quote(path)}` and rejects (400) any
resolved path that escapes the `/ingress/{token}/` prefix (path-traversal
guard via `URL.join` + a `startswith` check).

`_init_header` (core `ingress.py:218-243`) — strips
`CONTENT_LENGTH/CONTENT_ENCODING/TRANSFER_ENCODING/ACCEPT_ENCODING/
SEC_WEBSOCKET_*` from the inbound browser request, then injects:
- **`X-Hass-Source: core.ingress`** (`X_HASS_SOURCE` const)
- **`X-Ingress-Path: /api/hassio_ingress/{token}`** (`X_INGRESS_PATH` const) —
  the base path the add-on's web app must prefix onto its own
  relative asset/link URLs.
- **`X-Forwarded-For`**: original value (if any) + `, {client_peer_ip}`.
- **`X-Forwarded-Host`**: original header, else `request.host`.
- **`X-Forwarded-Proto`**: original header, else `request.scheme`.
- **Core does NOT set `X-Remote-User-*` headers** — those are added
  downstream, by Supervisor, not copied through by Core.

### B2.2 Supervisor side (`supervisor/api/ingress.py` `APIIngress`)

1. Validate `ingress_session` cookie (B1.3/B1.4); 401 if invalid.
2. Resolve `App` from `token` via `sys_ingress.get(token)`
   (`ingress.py:39-45`) — a `dict[ingress_token → slug]` rebuilt by
   `_update_token_list()` (`ingress.py:118-126`) whenever `Ingress.load()`/
   `reload()` runs. `503 HTTPServiceUnavailable` if the token maps to
   nothing (`api/ingress.py:83-90`).
3. `session_data = sys_ingress.get_session_data(session)` — the
   `IngressSessionData` (HA user) attached at session-create time, `None` if
   the session was created without `session_data_user_id`.
4. `_init_header` (`api/ingress.py:305-334`): strips
   `CONTENT_LENGTH/CONTENT_ENCODING/TRANSFER_ENCODING/SEC_WEBSOCKET_*/
   X-Supervisor-Token/X-Hassio-Key/X-Remote-User-*` from the **inbound**
   (Core-forwarded) headers, then re-injects:
   - **`X-Remote-User-Id`** always (if `session_data`); **`X-Remote-User-Name`**
     only if `session_data.user.username` set; **`X-Remote-User-Display-Name`**
     only if `session_data.user.name` set (`api/ingress.py:327-331`).
   - **`X-Forwarded-For`** re-appended again with Supervisor's own peer view
     (Core's IP, since Core is Supervisor's direct TCP client) — by the time
     the add-on sees it, it's a comma-chain: `<original>, <core-ip>`.
   - All Core-set headers not in the strip list (`X-Hass-Source`,
     `X-Ingress-Path`, `X-Forwarded-Host`, `X-Forwarded-Proto`, original
     browser headers Core passed through) survive unmodified.
   - **`Host` is NOT in either strip list at either hop** — passed through as
     whatever Core sent (Core's own public `Host`, not the add-on's
     `ip:port`). `[VERIFY]`: whether aiohttp's `ClientSession.request()`
     honors an explicit `Host` header already present vs. deriving it from
     the target URL — needs on-device confirmation the add-on's own HTTP
     server doesn't reject the mismatched Host.
5. Target: **`http://{app.ip_address}:{app.ingress_port}/{path}`**
   (`api/ingress.py:93-94 _create_url`) — bare internal container IP:port,
   no TLS, GET query string appended verbatim.
6. POST body: `request.content` (raw stream passthrough) **only if**
   `method == "POST" and app.ingress_stream`; otherwise (all other methods,
   or POST without `ingress_stream`) Supervisor buffers the full body via
   `await request.read()` first (`api/ingress.py:200-210`).
7. Response: bodies with `Content-Length < 4_194_000` (~4 MB) are read fully
   and returned as `web.Response`; otherwise (or `Content-Length` absent,
   e.g. chunked) `web.StreamResponse` is used, `X-Accel-Buffering: no` set,
   body relayed via `result.content.iter_chunks()`. Empty-body statuses
   (204/304/1xx, HEAD) short-circuit to a headers-only `web.Response`
   (`must_be_empty_body`, a local reimplementation of aiohttp's own helper,
   `api/ingress.py:53-70`).

### B2.3 WebSocket relay — full two/three-hop relay, not a raw tunnel

Both Core's and Supervisor's ingress handlers implement **an identical
pattern**: detect upgrade (`Connection` contains `upgrade`, case-insensitive,
+ `Upgrade: websocket` exact, case-insensitive — `_is_websocket`, both files),
then **terminate the incoming WS themselves** and **open an independent
outgoing WS client connection** downstream:

- `ws_server = web.WebSocketResponse(protocols=req_protocols, autoclose=False,
  autoping=False, max_msg_size=16 MiB)`, `await ws_server.prepare(request)`.
- `ws_client = await self.sys_websession.ws_connect(url, headers=...,
  protocols=req_protocols, autoclose=False, autoping=False,
  max_msg_size=16 MiB)`.
- Both directions pumped concurrently:
  `asyncio.wait([_websocket_forward(server,client), _websocket_forward(client,server)],
  return_when=FIRST_COMPLETED)` — the handler returns as soon as **either**
  direction ends.
- `TimeoutError` from the whole block is caught and logged (10s implicit via
  aiohttp connect default — no explicit connect timeout override found for
  the WS path specifically, unlike the HTTP path's `ClientTimeout(total=None)`).

So a WS session is **browser↔Core, Core↔Supervisor, Supervisor↔add-on — three
independent WS sessions relayed**, not one pass-through TCP stream.
`Sec-WebSocket-Protocol` is renegotiated at each hop from the same
`req_protocols` list; the GET query string is preserved on each hop's connect
URL.

`_websocket_forward` (identical logic in `core/.../ingress.py` and
`supervisor/api/ingress.py`): `TEXT→send_str`, `BINARY→send_bytes`,
`PING→ping(data)` (relayed, not auto-answered), `PONG→pong(data)`; if the
destination is already `closed`, echoes `close(code=ws_to.close_code,
message=msg.extra)` back to the source — close propagates by chasing
whichever side closed first. `RuntimeError` (both) /
`ConnectionResetError` (core only) are caught and logged, not raised.

---

## B3. Add-on config knobs + dynamic port allocation

### B3.1 Schema (`supervisor/apps/validate.py` `_SCHEMA_APP_CONFIG`)

- `ingress` (bool, default `False`)
- `ingress_port` (default `8099`, `vol.Any(network_port, vol.Equal(0))` — a
  literal 1-65535 **or exactly `0`** for dynamic assignment)
- `ingress_entry` (str, optional — a path segment appended to the ingress
  entry URL, e.g. a default landing page)
- `ingress_stream` (bool, default `False`)
- `panel_icon` (str, default `"mdi:puzzle"`)
- `panel_title` (str, optional — defaults to the app's `name`)
- `panel_admin` (bool, default `True`)

Persisted (not config, `SCHEMA_APP_USER`, `apps/validate.py` ~line 545-560):
- `ingress_token` (default factory `secrets.token_urlsafe()`) — set once at
  first install, stable across restarts/updates (unlike `access_token`,
  which is regenerated every start, `apps/app.py:1303`).
- `ingress_panel` (bool, default `False`) — the user-facing sidebar toggle,
  independent of the config-time `ingress` capability flag.

### B3.2 Dynamic ports

Range: `INGRESS_DYNAMIC_PORT_MIN = 62000`, `_MAX = 65500`
(`supervisor/const.py:61-62`).

`Ingress.get_dynamic_port(slug)` (`supervisor/ingress.py:163-176`): if not
already assigned, picks `random.randint(MIN, MAX)`, retrying while the
candidate is already assigned to another app **or**
`check_port(sys_docker.network.gateway, port)` says something is already
listening there — i.e. it actively probes the docker gateway IP, not just an
in-memory set. Once picked, persisted forever to `ingress.json`'s
`ports: {slug: port}` map (`ingress.py:174-176`) until
`del_dynamic_port(slug)` (called from `App.uninstall()`,
`apps/app.py` uninstall flow).

Triggered from `App._check_ingress_port()` (`apps/app.py:909-916`) — called
at `load()`, and after `install()`/`update()`/`rebuild()`/`restore()`
(`apps/app.py:290`,`1077`,`1137`,`1691`). Reading `App.ingress_port` while
still `0` (i.e. before `_check_ingress_port()` resolves it) **raises
`RuntimeError`** (`apps/app.py:672-679`) — info must never be served for an
app whose dynamic port hasn't settled yet.

Config-time guard (`_warn_app_config`, `apps/validate.py:257-283`): an app
declaring `ingress_port: 0` that also maps a host `ports:` entry inside
62000-65500 is **rejected** (`vol.Invalid`, not just a warning) — prevents a
collision that would expose the ingress endpoint directly on the host,
bypassing the session-cookie check entirely.

The add-on itself must discover its assigned dynamic port at runtime — there
is no way to hardcode it in the container. The mechanism is
`bashio::addon.ingress_port`, which reads back the resolved `ingress_port`
from `GET /addons/self/info` (confirmed live in the ESPHome add-on, §B5).

### B3.3 `ingress_stream`

Changes exactly one thing (`api/ingress.py` `_handle_request`): whether POST
bodies are streamed (`request.content`) vs buffered (`await request.read()`)
before forwarding. Does not affect GET, other methods, or response-side
streaming (which is decided independently by `Content-Length` size,
regardless of `ingress_stream`).

### B3.4 V1 info payload fields (`api/apps.py info_data`)

Same dict for V1/V2 (§ intro): `ingress` (bool, `with_ingress`),
`ingress_entry`, `ingress_url`, `ingress_port`, `ingress_panel`, `webui`,
`watchdog` (bool). `ingress_url` = `/api/hassio_ingress/{ingress_token}/{ingress_entry?}`
(`apps/app.py:634-639`); `ingress_entry` = `/api/hassio_ingress/{ingress_token}`
(no trailing content, `apps/app.py:566-570`) — these are the two fields Core
uses to build the sidebar iframe `src`.

---

## B4. Panel registration

### B4.1 `GET /ingress/panels`

`api/ingress.py:99-108`. Response:
```json
{"panels": {"<slug>": {"title": "...", "icon": "...", "admin": true, "enable": true}}}
```
one entry per **installed app with `with_ingress` true**
(`sys_ingress.apps`, `ingress.py:66-73`) — `enable` reflects the current
`ingress_panel` toggle (present even when `false`, i.e. this lists all
ingress-capable apps, not just currently-enabled panels).

### B4.2 Push to Core

`Ingress.update_hass_panel(app)` (`ingress.py:178-193`): `POST` (if
`app.ingress_panel`) or `DELETE` `api/hassio_push/panel/{slug}` on Core.
Called from `POST /addons/{slug}/options` when the body sets
`ingress_panel` (`api/apps.py options()`, `ATTR_INGRESS_PANEL in body`
branch), and forced off (`ingress_panel = False`) + pushed on
`App.uninstall()`.

### B4.3 Core side (`homeassistant/components/hassio/addon_panel.py`)

`HassIOAddonPanel`, `url = "/api/hassio_push/panel/{addon}"`,
`@require_admin` on both POST and DELETE. **POST re-fetches the full panel
list from Supervisor** via `client.ingress.panels()` (aiohasupervisor) rather
than trusting the (empty) POST body — the same anti-injection re-fetch
pattern used by discovery (see M4 addendum §A3.2). Only if that slug's
`enable` is true does it call:
```python
frontend.async_register_built_in_panel(
    hass, "app", frontend_url_path=addon,
    sidebar_title=data.title, sidebar_icon=data.icon,
    require_admin=data.admin, config={"addon": addon},
)
```
DELETE calls `frontend.async_remove_panel(hass, addon)` directly (no
re-fetch). On `EVENT_HOMEASSISTANT_START`, Core replays registration for
every already-enabled panel (`addon_panel.py:26-36`) — panels survive a Core
restart without Supervisor re-pushing.

**Frontend requirement**: a built-in panel component literally named
`"app"` must exist in Core's frontend bundle — this is the panel *type*
(shared by all add-ons), not the add-on slug (`frontend_url_path` is the
slug, used as the sidebar URL segment/route). `[VERIFY]`: this addendum did
not open the frontend repo's panel-component registry to confirm which
component renders under type `"app"` (expected: an iframe pointed at the
add-on's `ingress_url`) — not indexed deeply enough to pin further.

### B4.4 `POST /addons/{slug}/options` `ingress_panel` handling

`api/apps.py options()`: `SCHEMA_OPTIONS` includes
`vol.Optional(ATTR_INGRESS_PANEL): vol.Boolean()`. If present:
`app.ingress_panel = body[ATTR_INGRESS_PANEL]` then
`await self.sys_ingress.update_hass_panel(app)` — the push to Core happens
synchronously inside the options-handler request, not deferred to a
scheduler tick.

---

## B5. ESPHome add-on specifics

The add-on is built from the **`esphome` repo itself**
(`docker/Dockerfile:57-73`, target `base-ha-addon`), not a separate
"community add-ons" repo — same codebase as the standalone Docker image,
differentiated by which base image layer is used
(`ghcr.io/esphome/docker-base:debian-ha-addon-*`).

**`[VERIFY GAP — CLOSED 2026-07-21, P5-T1]`**: the manifest lives in the
separate **`esphome/home-assistant-addon`** repo (branch `main`, one add-on
per top-level dir: `esphome/`, `esphome-beta/`, `esphome-dev/`). The real
`esphome/config.yaml` (version 2026.7.1), captured verbatim during the
P5-T1 gate:

```yaml
---
url: https://esphome.io/
arch: [amd64, aarch64]
hassio_api: true
auth_api: true
host_network: true
ingress: true
ingress_port: 0
panel_icon: mdi:esphome
uart: true
ports:
  6052/tcp: null
map: [config:rw]
discovery: [esphome]
schema:
  home_assistant_dashboard_integration: bool?
  default_compile_process_limit: int(1,)?
  leave_front_door_open: bool?
backup_exclude: ['*/*/']
init: false
startup: services
name: ESPHome Device Builder
panel_title: ESPHome Builder
version: 2026.7.1
slug: esphome
description: Build your own smart home devices using ESPHome, no programming
  experience required
image: ghcr.io/esphome/esphome-hassio
```

Confirms the inferences below: `ingress_port: 0` (dynamic) — and notably
`host_network: true`, so the ingress proxy target is `127.0.0.1:<port>`,
not a bridge IP. No `ingress_stream`, no `ingress_entry`, no `panel_admin`
(defaults apply). Everything below was inferred from the s6-overlay rootfs
scripts (`docker/ha-addon-rootfs/`) before the manifest was located.

- `etc/s6-overlay/s6-rc.d/esphome/run:65`: launches
  `esphome-device-builder --ha-addon --ingress-port
  "$(bashio::addon.ingress_port)"` — the dashboard binds directly to
  whatever port Supervisor assigned as `ingress_port`. This is strong
  evidence `config.yaml` declares `ingress_port: 0` (dynamic) and the add-on
  discovers its port via bashio rather than using a fixed container port.
- `etc/s6-overlay/s6-rc.d/discovery/run`: waits for the dashboard
  (`bashio::net.wait_for "$port" "127.0.0.1" 300`) then POSTs MQTT-adjacent
  discovery: `bashio::discovery "esphome" {host: "127.0.0.1", port: "^<port>"}`
  — skippable via `home_assistant_dashboard_integration: false`. The `^`
  prefix on the port value is an ESPHome/HA discovery-payload convention
  (force-string, don't int-coerce), unrelated to any Supervisor grammar.
- `ingress_stream`: no ESPHome-specific reference found. `[VERIFY]` whether
  the dashboard needs streaming POST (e.g. firmware/config uploads) — no
  special-case code suggests it relies on default buffered-POST, but large
  binary uploads through the ~4 MB in-memory buffer path is a plausible
  memory/latency concern worth checking once the real `config.yaml` is
  located.
- WebSocket use by the dashboard: `[VERIFY]` — not confirmed by source read
  in the indexed repo (the dashboard logic lives in the separate
  `esphome-device-builder` PyPI package, pinned at `1.6.8`,
  `docker/Dockerfile:22`, not indexed). Publicly known to use WS for live
  compile/log streaming; the generic Core/Supervisor WS relay (§B2.3) should
  be sufficient without ESPHome-specific handling.
- `leave_front_door_open` config bool → `DISABLE_HA_AUTHENTICATION=true` env;
  combined with a manually-mapped host port 6052
  (`--ha-addon-allow-public` gated on `bashio::addon.port 6052` having a
  value) opens unauthenticated direct-LAN access **alongside** ingress. This
  is the add-on's own opt-in dual-mode design (ingress-only by default, plus
  optional unauthenticated LAN access via its own `ports:` config), not a
  general Supervisor mechanism.

---

## B6. Watchdog — container-event path

### B6.1 Event source

`BusEvent.DOCKER_CONTAINER_STATE_CHANGE` (`const.py:554`), fired by
`DockerMonitor._run()` (`supervisor/docker/monitor.py:100-143`), which
subscribes to raw aiodocker events and maps docker Actions →
`ContainerState` (`docker/const.py:54-61`: `FAILED, HEALTHY, RUNNING,
STOPPED, UNHEALTHY, UNKNOWN`):

| docker Action | → ContainerState | exit_code |
|---|---|---|
| `start` | `RUNNING` | — |
| `die`, exitCode ≠ 0 | `FAILED` | the exit code |
| `die`, exitCode == 0 | `STOPPED` | `None` |
| `health_status: healthy` | `HEALTHY` | — |
| `health_status: unhealthy` | `UNHEALTHY` | — |

Only containers whose docker `Attributes` carry `LABEL_MANAGED =
"supervisor_managed"`, or whose name was pre-registered via
`watch_container()` (pre-label containers), are processed — unrelated host
containers are filtered at the monitor level (`monitor.py:105-110`).

### B6.2 Two independent listeners per app

`App.load()` registers both on the same bus event
(`apps/app.py:281-286`): `container_state_changed` (always — updates cached
`AppState`, fires the `ADDON` WS event to Core, resolves boot-failed/
port-conflict/device-access issues) and `watchdog_container` (restart
logic). Both fire on every event unconditionally.

### B6.3 `watchdog_container` guards (`apps/app.py:1844-1858`)

```python
if not self.watchdog or self._manual_stop:
    return
if event.state in [ContainerState.FAILED, ContainerState.STOPPED, ContainerState.UNHEALTHY]:
    await self._restart_after_problem(event.state, event.exit_code)
```

**Two independent kill-switches**:
- `self.watchdog` — the persisted `watchdog:` bool
  (`POST /addons/{slug}/options {"watchdog": true}`).
- `self._manual_stop` — an in-memory flag. Set `True` by `App.stop()`
  (`apps/app.py:1348`, including via `restart()`'s stop-then-start).
  Cleared `False` when a `RUNNING` event arrives for the container
  (`container_state_changed`, `apps/app.py:1822-1823`). **Also initialized
  at `load()` from a host-reboot check**: `self._manual_stop =
  (await sys_hardware.helper.last_boot() != sys_config.last_boot)`
  (`apps/app.py:275-277`) — **on a host reboot, `_manual_stop` starts
  `True`**, so the watchdog does NOT auto-restart an app that was stopped
  before the reboot; it only re-arms once the container is explicitly
  started again (e.g. by `boot: auto` at Supervisor startup, or a user
  action).

Triggering states: `FAILED`, `STOPPED`, `UNHEALTHY` — **not** `HEALTHY` or
plain `RUNNING`.

### B6.4 `_restart_after_problem` (`apps/app.py`, throttled `@Job`)

Job decorator: `throttle=JobThrottle.GROUP_RATE_LIMIT`,
`throttle_period=WATCHDOG_THROTTLE_PERIOD` (30 min),
`throttle_max_calls=WATCHDOG_THROTTLE_MAX_CALLS` (10) — a **global per-app
rate limit** independent of the per-attempt backoff below
(`apps/const.py:37-38`).

Loop: `while instance.current_state() == state` (re-checks live docker
state each iteration) `and not self.in_progress` (skips while another job —
manual start/update — is running):
- `FAILED`, first attempt only: force-remove the dead container
  (`instance.stop(remove_container=True)`) before `start()`.
- `STOPPED`/`UNHEALTHY`: `restart()` (stop+start).
- `AppPortConflict` → log + **break immediately**, no more retries (a port
  conflict won't self-resolve).
- Other `AppsError` → `attempts += 1`, capture to Sentry, continue looping.
- Max attempts: **5** (`WATCHDOG_MAX_ATTEMPTS`, `apps/const.py:36`) — on
  reaching it, log CRITICAL and give up.
- Backoff: **exponential**,
  `WATCHDOG_RETRY_SECONDS * 2^(attempts-1)` = 10s, 20s, 40s, 80s, 160s
  (`WATCHDOG_RETRY_SECONDS = 10`, `apps/const.py:35`) — not a fixed
  interval.

`EXIT_CODE_SIGTERM_DEFAULT = 128 + signal.SIGTERM = 143`
(`docker/const.py:32`): a specific diagnostic WARNING (not an error) is
logged in `container_state_changed` when an app dies with exactly this
code — it ignored SIGTERM and was killed by Docker's default handler. Purely
informational, does not change watchdog behavior.

### B6.5 Independent from the application-level probe

The periodic scheduler task `_watchdog_app_application` (§B7) is an
**entirely separate code path** from the container-event watchdog above —
different trigger (poll vs. bus event), different failure-counter state
(`Tasks._cache` dict vs. the per-app Job's own throttle bucket), different
backoff model (two-strikes-flat vs. five-attempt-exponential). Both can be
active simultaneously for the same app: container-events catch
crashes/OOM-kills instantly; the application probe catches hangs where the
container is still `RUNNING`/healthy but not actually serving requests.

### B6.6 `boot:` interaction

No direct coupling found between `boot:` config and watchdog gating —
`boot: manual`/`manual_only` only affects whether Supervisor auto-starts the
app at Supervisor startup; no `if self.boot == ...` guard exists in
`watchdog_container`/`_restart_after_problem`. `[VERIFY]`: not exhaustively
proven absent, but nothing found suggesting `boot:` blocks watchdog restarts
once an app IS running.

---

## B7. Watchdog application probe — URL grammar + cadence

### B7.1 Config-time grammar (`apps/validate.py` `_SCHEMA_APP_CONFIG`)

```python
ATTR_WATCHDOG: vol.Match(r"^(?:https?|\[PROTO:\w+\]|tcp):\/\/\[HOST\]:(\[PORT:\d+\]|\d+).*$")
ATTR_WEBUI:    vol.Match(r"^(?:https?|\[PROTO:\w+\]):\/\/\[HOST\]:\[PORT:\d+\].*$")
```

- `watchdog:` accepts `tcp://`, `http(s)://`, or a config-templated
  `[PROTO:optionname]://` prefix; port is a literal integer **or** the
  bracketed `[PORT:xxxx]` form (xxxx = the container port referenced).
- `webui:` omits `tcp://` (it's a display URL, not something Supervisor
  connects to) and **requires** the bracketed `[PORT:xxxx]` form — no bare
  literal alternative.

### B7.2 Runtime parse (`apps/app.py`)

```python
RE_WATCHDOG = re.compile(
    r"^(?:(?P<s_prefix>https?|tcp)|\[PROTO:(?P<t_proto>\w+)\])"
    r":\/\/\[HOST\]:(?:\[PORT:)?(?P<t_port>\d+)\]?(?P<s_suffix>.*)$"
)
RE_WEBUI = re.compile(
    r"^(?:(?P<s_prefix>https?)|\[PROTO:(?P<t_proto>\w+)\])"
    r":\/\/\[HOST\]:\[PORT:(?P<t_port>\d+)\](?P<s_suffix>.*)$"
)
```
`[HOST]` is a fixed literal in both grammars, matched but never substituted
via lookup — the two probes treat it completely differently:

- **watchdog**: fully resolved server-side. `watchdog_application()`
  (`apps/app.py`) reconstructs `f"{proto}://{self.ip_address}:{port}{s_suffix}"`
  using the app's actual container IP, discarding `[HOST]` text entirely.
- **webui**: `[HOST]` is left **intact** in the returned string
  (`f"{proto}://[HOST]:{port}{s_suffix}"`, `webui` property) — the
  frontend/browser is expected to substitute `[HOST]` with its own current
  hostname, since a webui link is navigated to directly by the user's
  browser, bypassing Supervisor (unlike ingress/watchdog, which always go
  through Supervisor).

Port resolution asymmetry: watchdog special-cases `host_network` — if
`self.host_network and self.ports`, look up the host-mapped port for
`f"{t_port}/tcp"` (fallback to `t_port`); otherwise (bridge network) uses
`t_port` directly since Supervisor reaches the container by its own bridge
IP. `webui`'s port lookup is unconditional (`self.ports.get(f"{t_port}/tcp",
t_port)`, no host_network branch) — `[VERIFY]`: inferred reasoning is that a
webui link is always resolved from the *browser's* perspective (no bridge
access, so always needs the host-mapped port regardless of network mode),
but no comment in source states this explicitly.

Protocol selection: if `t_proto` (`[PROTO:optionname]`) present,
`proto = "https" if self.options.get(t_proto) else "http"` — the add-on's
own `options.json` value for that option name (typically a boolean like
`ssl`) picks http vs https at probe time. Otherwise the literal `s_prefix`
(`https`/`http`/`tcp`) from config is used as-is.

### B7.3 Probe execution

- **TCP**: `check_port(ip_address, port)` — raw TCP connect test, no data
  exchanged.
- **HTTP(S)**: `sys_websession.get(url, timeout=WATCHDOG_TIMEOUT, ssl=False)`,
  `WATCHDOG_TIMEOUT = ClientTimeout(total=10)` (10s hard timeout).
  `ssl=False` **disables certificate verification** even for `https://`
  probes (self-signed certs fine). Healthy = `status < 300` (2xx/1xx count;
  **3xx redirects count as unhealthy**). `TimeoutError, aiohttp.ClientError`
  (a valid PEP 758 multi-except, not a Py2 bug — see M4 addendum §A0) are
  caught → `False`; any other exception propagates uncaught.
- No `watchdog:` configured → `watchdog_application()` returns `True`
  unconditionally (app-level probing is opt-in).

### B7.4 Cadence and restart policy (`supervisor/misc/tasks.py`)

`RUN_WATCHDOG_APP_APPLICATION = 120` (seconds, `tasks.py:50`) — every 2
minutes, `_watchdog_app_application()` iterates every installed app with
`watchdog == True and state == AppState.STARTED` (STARTUP/STOPPED/
ERROR/UNKNOWN are exempt — a container mid-healthcheck-startup is not
probed).

- Skips if `app.in_progress` (another job running) or
  `await app.watchdog_application()` returns `True`.
- **Two-strikes-then-restart**: first failure logs WARNING and caches
  `retry_scan = 1`, returns (no restart yet). Only on the **second
  consecutive** failing tick does it call `await (await app.restart())` —
  an app-level hang takes **~120-240s** to trigger a restart, vs. the
  container-event watchdog's near-instant reaction to a crash/OOM-kill.
- No exponential backoff or max-attempt cap at this layer: each 120s tick
  either restarts (resetting the counter to 0) or increments the counter to
  1 — no attempt-5-gives-up logic like B6.4.
- This probe's failure counter (`Tasks._cache[app.slug]`, a plain dict on
  the singleton `Tasks` instance) is **completely separate** in-memory state
  from the container-event watchdog's throttle/attempts (a per-app Job
  throttle bucket) — the two watchdogs never share counters.

`webui:` shares the grammar (B7.1/B7.2) but has **no periodic probe
anywhere** in Supervisor — it exists purely so Core/frontend can render an
"Open Web UI" link; no runtime consumer beyond the `App.webui` property
exposed in the info API was found.

Separate observer-plugin watchdog (`_watchdog_observer_application`, every
180s = `RUN_WATCHDOG_OBSERVER_APPLICATION`) and Home Assistant Core's own API
watchdog (`_watchdog_homeassistant_api`, every 120s, with a 2-strike +
5-reanimation-attempt + safe-mode-fallback ladder) exist in the same file
but are **not** the app watchdog — out of scope for M4b except as a
reminder the same `misc/tasks.py` module hosts multiple unrelated watchdog
loops with different cadences and retry ladders; don't conflate them.

---

## B8. Watchdog V1 wire

`POST /addons/{slug}/options` body `SCHEMA_OPTIONS`
(`api/apps.py:120-131`): `vol.Optional(ATTR_WATCHDOG): vol.Boolean()`.
Handler: `if ATTR_WATCHDOG in body: app.watchdog = body[ATTR_WATCHDOG]`.

`App.watchdog` setter (`apps/app.py:505-514`): persists to
`persist[ATTR_WATCHDOG]` in `apps.json`'s user section — **except** if
`self.startup == AppStartup.ONCE`, in which case a `True` value is
**silently ignored** (logs a warning) — one-shot add-ons (e.g. migration
containers) can never have watchdog enabled regardless of what's POSTed.

Info response field: `watchdog: app.watchdog` (bool,
`api/apps.py info_data`, `ATTR_WATCHDOG`) — always the persisted user
setting; no config.yaml default exists for `watchdog:` as a boolean toggle
(only the URL-template `watchdog:` string field is config; the boolean
enable/disable is purely a persisted per-install setting, default `False`,
`SCHEMA_APP_USER`).

No V1-vs-V2 field-name difference for `watchdog` (same key both versions,
consistent with the intro's finding that info payloads aren't re-keyed).
Note `watchdog` and `ingress_panel` are set via the **exact same** POST
endpoint + body schema (`SCHEMA_OPTIONS`) — implementing one without the
other in the emulator would be an easy oversight since they share a handler.

---

## B9. Consolidated gaps → must verify empirically (§A7 equivalent)

1. **Who sets the `ingress_session` cookie** — not found in indexed
   `supervisor`/`core` Python; likely frontend TypeScript (not indexed).
   Must confirm the exact flow (probably: frontend calls
   `POST /ingress/session` through Core's hassio WS command, then sets the
   cookie on the iframe's parent document) before implementing the Vagus
   panel-loading flow. (B1.3)
2. **`Host` header pass-through at the Supervisor→add-on hop** — Supervisor
   doesn't strip or rewrite `Host`, so the add-on receives Core's original
   public `Host` value, not `container_ip:port`. Verify on-device that a
   plain aiohttp/cowboy/Plug server serving the add-on doesn't reject or
   mis-route on this mismatched Host. (B2.2 step 4)
3. **ESPHome's actual `config.yaml`** is not in the indexed `esphome` repo —
   locate the real manifest (separate repo) before hardcoding assumed
   `ingress_port: 0`, `ingress_stream`, etc. All ESPHome specifics here are
   inferred from s6-overlay scripts only. (B5)
4. **ESPHome dashboard WebSocket usage** — plausible but unconfirmed by
   source (lives in the un-indexed `esphome-device-builder` PyPI package).
   Confirm empirically once the ESPHome ingress panel is actually loaded
   through the emulator. (B5)
5. **Frontend `"app"` panel component** — not traced into the frontend repo;
   confirm what actually renders (expected: an iframe at `ingress_url`) and
   whether it does anything beyond that (e.g. handling `X-Ingress-Path`
   client-side for relative asset rewriting). (B4.3)
6. **`webui:` port-lookup asymmetry vs. `watchdog:`** (host_network branch
   present for watchdog, absent for webui) — plausible reasoning given in
   B7.2 but not confirmed by a source comment; low risk since Vagus likely
   implements watchdog probing but not webui link rendering, but flag if
   webui is ever surfaced. (B7.2)
7. **`boot:` × watchdog interaction** — no coupling found, but not proven
   exhaustively absent; if Vagus sees a `boot: manual` app get
   watchdog-restarted unexpectedly (or vice versa not restarted when it
   should), re-check this. (B6.6)
8. **Version pin**: everything above is dev-HEAD
   (`9999.09.9.dev9999`, see M4 addendum §A0) — re-verify field names/regexes
   against the exact Supervisor release the device targets before shipping,
   especially the `RE_WATCHDOG`/`RE_WEBUI` regexes and the
   `INGRESS_DYNAMIC_PORT_MIN/MAX` range, which look like recent additions
   (dynamic ingress ports are a newer feature per the `_warn_app_config`
   guard's framing).
