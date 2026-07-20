# Supervisor API Contract — pinned at Core 2026.7.2 / Supervisor 2026.07.3 / aiohasupervisor 0.5.0

Sources (exact refs used):
- `home-assistant/core` @ tag `2026.7.2`
- `home-assistant/supervisor` @ tag `2026.07.3`
- `home-assistant-libs/python-supervisor-client` @ tag `0.5.0` — this is the actual repo for the
  PyPI package `aiohasupervisor` (confirmed via PyPI JSON metadata `project_urls["Source Code"]`
  for `aiohasupervisor==0.5.0`; there is **no** `home-assistant/aiohasupervisor` repo). The
  version `0.5.0` was determined from
  `homeassistant/components/hassio/manifest.json` at core `2026.7.2`:
  `"requirements": ["aiohasupervisor==0.5.0"]`.

All GitHub paths below are relative to these repo roots at these exact refs unless stated
otherwise.

---

## 1. SUPERVISOR env + base URL (the port question)

**Answer: `SUPERVISOR=<host>:<port>` works. Core does NOT assume port 80 and does NOT parse
host/port separately for URL construction — it uses the raw env var value verbatim,
string-interpolated directly after `http://`.**

Evidence — `homeassistant/components/hassio/__init__.py` (`async_setup`):
```python
host = os.environ["SUPERVISOR"]
websession = async_get_clientsession(hass)
hass.data[DATA_COMPONENT] = HassIO(hass.loop, websession, host)
```

`homeassistant/components/hassio/handler.py` (`HassIO.__init__`):
```python
def __init__(self, loop, websession, ip: str) -> None:
    self.loop = loop
    self.websession = websession
    self._ip = ip
    base_url = f"http://{ip}"
    self._base_url = URL(base_url)
```
and `send_command`:
```python
joined_url = self._base_url.with_path(command)
```
This same `base_url` (`str(hassio.base_url)`) is also passed as `api_host` to
`aiohasupervisor.SupervisorClient` (`handler.py`, `get_supervisor_client`), so the REST-model
client and the raw `send_command` path share one base URL derived the same way.

`homeassistant/components/hassio/http.py` (`HassIOView._handle`, the `/api/hassio/{path}` proxy)
constructs the upstream URL independently but identically:
```python
client = await self._websession.request(
    method=request.method,
    url=f"http://{self._host}/{quote(path)}",
    ...
)
```

Corroborating evidence that the env var is host:port (not host only) —
`homeassistant/components/hassio/auth.py` (`HassIOBaseAuth._check_access`) splits off just the
host part for an IP-equality check, implying the full value routinely carries a port:
```python
hassio_ip = os.environ["SUPERVISOR"].split(":")[0]
```

Inside `aiohasupervisor` itself, `_SupervisorClient._request`
(`aiohasupervisor/client.py`) does:
```python
url = URL(self.api_host).joinpath(uri)
```
`api_host` is exactly the string passed to `SupervisorClient(str(hassio.base_url), ...)`, i.e.
`"http://<SUPERVISOR-env-value>"`. No default port, no host/port split, no scheme guessing.

**Conclusion for the emulator:** bind on whatever host:port pair the `SUPERVISOR` env var of the
Core container names, verbatim. There is no fallback to port 80 anywhere in this call path.

---

## 2. Envelope

Confirmed `{"result": "ok", "data": {...}}` / `{"result": "error", "message": ...}`, with two
optional extra keys on error.

`supervisor/api/utils.py`:
```python
def api_return_ok(data=None) -> web.Response:
    return web.json_response({JSON_RESULT: RESULT_OK, JSON_DATA: data or {}}, dumps=json_dumps)
```
```python
def api_return_error(error=None, message=None, error_type=None, status=400, *, headers=None, job_id=None):
    ...
    result: dict[str, Any] = {JSON_RESULT: RESULT_ERROR, JSON_MESSAGE: message}
    if job_id:
        result[JSON_JOB_ID] = job_id
    if error and error.error_key:
        result[JSON_ERROR_KEY] = error.error_key
    if error and error.extra_fields:
        result[JSON_EXTRA_FIELDS] = error.extra_fields
    return web.json_response(result, status=status, dumps=json_dumps, headers=headers)
```
`api_process` decorator wraps every handler: dict/list return → `api_return_ok(data=answer)`;
`APIError`/`HassioError` → `api_return_error(...)`; bare `bool` False → error with no message;
anything else → bare ok.

Mirrored client-side in `aiohasupervisor/models/base.py`:
```python
@dataclass(frozen=True, slots=True)
class Response(DataClassORJSONMixin):
    result: ResultType          # "ok" | "error"
    data: Any | None = None
    message: str | None = None
    job_id: str | None = None
    error_key: str | None = None
    extra_fields: dict[str, Any] | None = None
```
So the full error envelope is `{"result": "error", "message": str, "job_id"?: str,
"error_key"?: str, "extra_fields"?: dict}` — `job_id`/`error_key`/`extra_fields` are omitted
(not present as null) when not applicable, not just null.

`extract_supervisor_token` (`supervisor/api/utils.py`) accepts the token from any of three
places, in priority order: header `X-Supervisor-Token`, legacy header `X-Hassio-Key`, or
`Authorization: Bearer <token>`.

---

## 3. Green surface (endpoints polled + intervals)

Poll intervals — `homeassistant/components/hassio/const.py`:
```python
HASSIO_MAIN_UPDATE_INTERVAL = timedelta(minutes=5)
HASSIO_ADDON_UPDATE_INTERVAL = timedelta(minutes=15)
HASSIO_STATS_UPDATE_INTERVAL = timedelta(seconds=60)
```
There is no separate jobs/issues polling interval — job data is refreshed inline with the main
coordinator's cycle (`self.jobs.refresh_data(is_first_update)` inside
`HassioMainDataUpdateCoordinator._async_update_data`) and thereafter kept current purely by
`supervisor/event` WS pushes (`job` events); issues are refreshed the same way, driven by
`supervisor_update`/`info`-style WS events rather than their own timer.

**Config-entry setup (`async_setup_entry`, `homeassistant/components/hassio/__init__.py`), in
order:**
1. `GET supervisor/ping` (`supervisor_client.supervisor.ping()`) — must succeed or
   `ConfigEntryNotReady`.
2. If not onboarded yet: `POST supervisor/update` (`supervisor_client.supervisor.update()`) —
   opportunistic Supervisor self-update before Core proceeds.
3. Main coordinator first refresh (see below).
4. Addon coordinator first refresh.
5. Stats coordinator first refresh.
6. `POST homeassistant/options` (`supervisor_client.homeassistant.set_options(...)`) and
   `POST supervisor/options` (`push_config`, timezone/country) fired concurrently via
   `asyncio.gather`.

**`HassioMainDataUpdateCoordinator._async_update_data`** (every 5 min, `coordinator.py`):
```python
await asyncio.gather(
    client.info(),                 # GET info
    client.homeassistant.info(),   # GET core/info
    client.supervisor.info(),      # GET supervisor/info
    client.os.info(),              # GET os/info
    client.host.info(),            # GET host/info
    client.store.info(),           # GET store        <-- NOT "/store/info"
    client.network.info(),         # GET network/info
)
mounts_info = await client.mounts.info()  # GET mounts  <-- NOT "/mounts/info"
await self.jobs.refresh_data(is_first_update)  # GET jobs/info
```
On **non-scheduled** refreshes only (`_async_refresh` override), it additionally calls
`POST reload_updates` (`supervisor_client.reload_updates()`) before the above.

**`HassioAddOnDataUpdateCoordinator._async_update_data`** (every 15 min):
```python
installed_addons = await client.addons.list()          # GET addons
# then for all addons on first update, or only subscribed-entity addons afterward:
info = await client.addons.addon_info(slug)            # GET addons/{slug}/info
```
On non-scheduled refreshes it also calls `POST store/reload`
(`supervisor_client.store.reload()`) first.

**`HassioStatsDataUpdateCoordinator._async_update_data`** (every 60 s, only for containers with a
subscribed stats entity):
```python
client.homeassistant.stats()   # GET core/stats
client.supervisor.stats()      # GET supervisor/stats
client.addons.addon_stats(slug)  # GET addons/{slug}/stats
```

**Not called anywhere in the hassio integration in this version:** `GET available_updates`
(`SupervisorClient.available_updates()` exists in aiohasupervisor but is unused by
`hassio/coordinator.py`/`__init__.py`; it may still be invoked ad hoc via the
`supervisor/api` WS passthrough from the frontend). `GET resolution/info` is likewise not polled
by the coordinator directly — it is populated by `SupervisorIssues.async_update()`
(`issues.py`), called once at entry setup (`issues.setup()`) and thereafter kept in sync purely
by WS events (`health_changed`, `supported_changed`, `issue_changed`, `issue_removed`,
`supervisor_update`/`info`), i.e. not on a timer either. `resolution/info` field mapping is
confirmed in `issues.py` (`ResolutionInfo` deserialized via aiohasupervisor,
`self.unhealthy_reasons = set(data.unhealthy)`, `self.unsupported_reasons =
set(data.unsupported)`, `data.issues` iterated).

**Endpoint path corrections vs. common assumption:** the store endpoint is `GET store`
(not `/store/info`), and mounts is `GET mounts` (not `/mounts/info`) — confirmed directly in
`aiohasupervisor/store.py` (`self._client.get("store")`) and `aiohasupervisor/mounts.py`
(`self._client.get("mounts")`).

---

## 4. WS: `supervisor/event` (type, schema, auth, valid `update_key` values)

Constants — `homeassistant/components/hassio/const.py`:
```python
WS_TYPE_API = "supervisor/api"
WS_TYPE_EVENT = "supervisor/event"
WS_TYPE_SUBSCRIBE = "supervisor/subscribe"
ATTR_WS_EVENT = "event"
ATTR_UPDATE_KEY = "update_key"
EVENT_SUPERVISOR_EVENT = "supervisor_event"     # internal HA dispatcher signal name
EVENT_SUPERVISOR_UPDATE = "supervisor_update"   # value of msg["data"]["event"]
EVENT_HEALTH_CHANGED = "health_changed"
EVENT_SUPPORTED_CHANGED = "supported_changed"
EVENT_ISSUE_CHANGED = "issue_changed"
EVENT_ISSUE_REMOVED = "issue_removed"
EVENT_JOB = "job"
UPDATE_KEY_SUPERVISOR = "supervisor"
STARTUP_COMPLETE = "complete"
```

Schema and auth — `homeassistant/components/hassio/websocket_api.py`:
```python
SCHEMA_WEBSOCKET_EVENT = vol.Schema(
    {vol.Required(ATTR_WS_EVENT): cv.string},
    extra=vol.ALLOW_EXTRA,
)

@websocket_api.ws_require_user(only_supervisor=True)
@websocket_api.websocket_command({
    vol.Required(WS_TYPE): WS_TYPE_EVENT,          # "supervisor/event"
    vol.Required(ATTR_DATA): SCHEMA_WEBSOCKET_EVENT,
})
def websocket_supervisor_event(hass, connection, msg):
    connection.send_result(msg[WS_ID])
    async_dispatcher_send(hass, EVENT_SUPERVISOR_EVENT, msg[ATTR_DATA])
```
So the only hard requirement on `data` is a string key `event`; everything else is
`ALLOW_EXTRA`. Real payloads add `update_key`/`data` (for `supervisor_update`), or an
event-specific `data` sub-object (for `job`, `issue_changed`, etc.) — see below.

`only_supervisor=True` is enforced in `homeassistant/components/websocket_api/decorators.py`
(`ws_require_user`):
```python
if only_supervisor and connection.user.name != HASSIO_USER_NAME:
    output_error("only_supervisor", "Only allowed as Supervisor")
    return None
```
`HASSIO_USER_NAME = "Supervisor"` (`homeassistant/const.py`). This means the WS connection must
be authenticated as the Supervisor's own system user (i.e., the long-lived access token derived
from the same refresh token Core handed to the Supervisor user during onboarding — see §5), not
merely any admin token.

There is a separate, unrelated `WS_TYPE_SUBSCRIBE = "supervisor/subscribe"` command
(`websocket_subscribe`, `require_admin`) that lets **frontend/admin** clients subscribe to the
same internal dispatcher signal (`EVENT_SUPERVISOR_EVENT`) — it is a read-only fan-out, not
something the Supervisor calls.

### Valid `event` (i.e. `ATTR_WS_EVENT`) values Core's Python code actively branches on
| value | consumer | data shape acted on |
|---|---|---|
| `supervisor_update` | `coordinator.py`, `jobs.py`, `issues.py` | `{"update_key": ..., "data": {"startup": "complete", ...}}` — only reacted to when `update_key == "supervisor"` **and** `data.startup == "complete"`; triggers a coordinator refresh / job refresh / issue refresh |
| `health_changed` | `issues.py` | `{"healthy": bool, "unhealthy_reasons": [...]}` |
| `supported_changed` | `issues.py` | `{"supported": bool, "unsupported_reasons": [...]}` |
| `issue_changed` | `issues.py` | full `Issue` dict (`aiohasupervisor.models.Issue.from_dict`) |
| `issue_removed` | `issues.py` | full `Issue` dict |
| `job` | `jobs.py` | full job dict (`aiohasupervisor.models.jobs.Job.from_dict(data | {"child_jobs": []})`) — note Core injects an empty `child_jobs` list itself; the wire payload for a single `job` event does **not** include `child_jobs` |

`websocket_api.py`'s generic `websocket_supervisor_event` handler just forwards whatever `data`
dict it receives to the internal dispatcher (`EVENT_SUPERVISOR_EVENT`) unconditionally — the
table above is what the three *subscribers* of that dispatcher signal (main coordinator, jobs
tracker, issues tracker) each individually pattern-match on. Anything else is silently ignored
by backend Python code (though the raw dict is also forwarded live to any frontend WS
subscriber via `supervisor/subscribe`).

### `update_key` values actually emitted by Supervisor 2026.07.3

Core only explicitly branches on `update_key == "supervisor"` (`UPDATE_KEY_SUPERVISOR`,
gating the post-restart coordinator/job/issue refresh). Grepping Supervisor's own emission call
sites (`self.sys_homeassistant.websocket.supervisor_update_event(key, data)`) shows the actual
key vocabulary in the wild:

| file | key | data |
|---|---|---|
| `supervisor/core.py:93` | `"info"` | `{"state": <CoreState>}` — sent on every Supervisor state change (except during startup/close) |
| `supervisor/core.py:313` | `"supervisor"` | `{"startup": "complete"}` — sent once Supervisor reaches `RUNNING` |
| `supervisor/supervisor.py:91` | `"network"` | `{"supervisor_internet": <bool>}` |
| `supervisor/host/network.py:69` | `"network"` | `{"host_internet": <bool>}` |
| `supervisor/updater.py:349` | one or more of `"supervisor"`, `"core"`, `"os"` (conditionally, only if HAOS) | none (bare `supervisor_update_event(event)` with no data arg) — sent after `Updater.reload()` fetches new version info |

**No addon-specific `update_key` (e.g. `"addon:<slug>"`) exists.** Per-addon install/update
progress is communicated exclusively through `job` events matched by **job name** (not
`update_key`) — see `homeassistant/components/hassio/update.py`, which subscribes to jobs named
`"addon_manager_update"` (filtered further by `reference=<slug>`), `"supervisor_update"`, and
`"home_assistant_core_update"` via `SupervisorJobs.subscribe(JobSubscription(...))`.

`aiohasupervisor`'s own `WSEvent` vocabulary as defined in `supervisor/homeassistant/const.py`
(Supervisor side, for its own type-checking of what it sends) is broader than what Core reacts
to:
```python
class WSEvent(StrEnum):
    ADDON = "addon"
    HEALTH_CHANGED = "health_changed"
    ISSUE_CHANGED = "issue_changed"
    ISSUE_REMOVED = "issue_removed"
    JOB = "job"
    SUPERVISOR_UPDATE = "supervisor_update"
    SUPPORTED_CHANGED = "supported_changed"
```
`WSEvent.ADDON = "addon"` is defined but was not found emitted from any `supervisor_update_event`
/ `supervisor_event_custom` call site reachable from the files grep found, and Core's hassio
component has no matching branch for `event == "addon"` — **UNCONFIRMED** whether/where this is
still emitted elsewhere in the Supervisor codebase; treat it as reserved/legacy rather than part
of the live contract.

---

## 5. Token handshake

### `POST /homeassistant/options` fields Core actually sends

`homeassistant/components/hassio/__init__.py` (`update_hass_api`, called once at entry setup
and whenever needed):
```python
options = HomeAssistantOptions(
    ssl=hass.config.api.use_ssl,
    port=hass.config.api.port,
    refresh_token=refresh_token.token,
)
await supervisor_client.homeassistant.set_options(options)
```
This posts to `core/options` (aiohasupervisor `HomeAssistantClient.set_options`,
`aiohasupervisor/homeassistant.py`: `self._client.post("core/options", json=options.to_dict())`)
— **note the wire path is `core/options`, not `homeassistant/options`**; "homeassistant" is only
the Python attribute name (`supervisor_client.homeassistant`), not the URL segment (mirroring
`core/info`, `core/stats` for the same sub-client).

Only `ssl`, `port`, and `refresh_token` are ever populated by Core in this call; all other
`HomeAssistantOptions` fields (`boot`, `image`, `watchdog`, `audio_input`, `audio_output`,
`backups_exclude_database`, `duplicate_log_file`) are left at their defaults and — because
`Options`/`Request` models use `omit_default=True` — are omitted from the JSON body entirely,
not sent as `null`.

The refresh token itself: Core gets-or-creates one for the Supervisor system user
(`__init__.py`, `async_setup_entry`):
```python
user = hass.data[DATA_HASSIO_SUPERVISOR_USER]
if user.refresh_tokens:
    refresh_token = list(user.refresh_tokens.values())[0]
else:
    refresh_token = await hass.auth.async_create_refresh_token(user)
```
Critically, `async_create_refresh_token(user)` is called **with no `client_id` argument** —
so this refresh token's `client_id` attribute is `None`. This matters for §5b below.

### Auth exchange: `client_id` at `POST /auth/token` with `grant_type=refresh_token`

**Supervisor does NOT send `client_id` at all.** `supervisor/homeassistant/api.py`
(`_ensure_access_token`):
```python
async with self.sys_websession.post(
    f"{self.sys_homeassistant.api_url}/auth/token",
    timeout=aiohttp.ClientTimeout(total=30),
    data={
        "grant_type": "refresh_token",
        "refresh_token": self.sys_homeassistant.refresh_token,
    },
    ssl=False,
) as resp:
    ...
    tokens = await resp.json()
    self._access_token = tokens["access_token"]
    self._access_token_expires = datetime.now(tz=UTC) + timedelta(seconds=tokens["expires_in"])
```
Only two form fields: `grant_type`, `refresh_token`. No `client_id`, no `Content-Type` override
(aiohttp sends this as `application/x-www-form-urlencoded` since `data=` is a plain dict), no
custom headers.

Core's `/auth/token` handler (`homeassistant/components/auth/__init__.py`,
`_async_handle_refresh_token`) treats `client_id` as **optional but must match**:
```python
client_id = data.get("client_id")
if client_id is not None and not indieauth.verify_client_id(client_id):
    return self.json({"error": "invalid_request", ...}, status_code=400)
...
refresh_token = hass.auth.async_get_refresh_token_by_token(token)
if refresh_token is None:
    return self.json({"error": "invalid_grant"}, status_code=400)
if refresh_token.client_id != client_id:
    return self.json({"error": "invalid_request", ...}, status_code=400)
```
Since the Supervisor's refresh token was created with `client_id=None` (§5 above) and the
Supervisor's exchange request also omits `client_id` (`data.get("client_id")` → `None`), the
equality check `refresh_token.client_id != client_id` passes (`None != None` is `False`). **This
is a matched pair by construction, not a coincidence** — if either side changed (Core started
creating the token with a client_id, or Supervisor started sending one that didn't match), the
exchange would start failing with `invalid_request`.

Success response fields Supervisor reads: `tokens["access_token"]`, `tokens["expires_in"]`
(seconds, converted to an absolute expiry). Core's success response also includes `token_type:
"Bearer"` but Supervisor doesn't read it (implicitly assumed Bearer everywhere it authenticates
back to Core).

For the Elixir emulator (playing the Supervisor role calling into a *real* Core, or playing
Core's `/auth/token` for a *real* Supervisor client): the emulator must omit `client_id` when
acting as Supervisor, and must accept a request with no `client_id` field as valid when acting
as Core's token endpoint for this specific refresh token.

---

## 6. Models

Mashumaro rule used throughout aiohasupervisor: dataclass fields with **no default value**
are required keys in the wire JSON (missing key ⇒ `mashumaro` raises `MissingField` inside
`SupervisorError`-wrapping code, i.e. a `SupervisorResponseError` bubbles up eventually via
`is_json`/`from_dict` failure) regardless of whether the *type* is `X | None`. A `X | None` type
with no default only means the *value* may be JSON `null`; the *key* is still mandatory. Fields
with an explicit default (`= None`, `= False`, `= DEFAULT` sentinel, etc.) are optional on the
wire; a missing key deserializes to that default. None of these response models set
`forbid_extra_keys`, so **unknown extra wire keys are silently ignored**, not rejected.

Legend: **Req** = required key on the wire (no default in the dataclass). **Null** = value may
be JSON `null` per the type hint.

### 10. `RootInfo` — `GET info` (`aiohasupervisor/models/root.py`)
| field | type | Null | Req |
|---|---|---|---|
| supervisor | str | N | Y |
| homeassistant | str \| None | Y | Y |
| hassos | str \| None | Y | Y |
| docker | str | N | Y |
| hostname | str \| None | Y | Y |
| operating_system | str \| None | Y | Y |
| features | list[HostFeature \| str] | N | Y |
| machine | str \| None | Y | Y |
| machine_id | str \| None | Y | Y |
| arch | str | N | Y |
| state | SupervisorState (enum: initialize/setup/startup/running/freeze/shutdown/stopping/close) | N | Y |
| supported_arch | list[str] | N | Y |
| supported | bool | N | Y |
| channel | UpdateChannel (stable/beta/dev) | N | Y |
| logging | LogLevel (debug/info/warning/error/critical) | N | Y |
| timezone | str | N | Y |

### 11. `SupervisorInfo` — `GET supervisor/info` (`aiohasupervisor/models/supervisor.py`)
| field | type | Null | Req |
|---|---|---|---|
| version | str | N | Y |
| version_latest | str \| None | Y | Y |
| update_available | bool | N | Y |
| channel | UpdateChannel | N | Y |
| arch | str \| None | Y | Y |
| supported | bool | N | Y |
| healthy | bool | N | Y |
| ip_address | IPv4Address | N | Y |
| timezone | str \| None | Y | Y |
| logging | LogLevel | N | Y |
| debug | bool | N | Y |
| debug_block | bool | N | Y |
| diagnostics | bool \| None | Y | Y |
| auto_update | bool | N | Y |
| country | str \| None | Y | Y |
| detect_blocking_io | bool | N | Y |
| feature_flags | dict[FeatureFlag \| str, bool] | N | Y |

`SupervisorOptions` (accepted by `POST supervisor/options`, all optional/omit-default):
`channel`, `timezone`, `logging`, `debug`, `debug_block`, `diagnostics`, `content_trust`,
`force_security`, `auto_update`, `country`, `detect_blocking_io`, `feature_flags` — all
`= None` defaults.

### 12. `HomeAssistantInfo` — `GET core/info` (`aiohasupervisor/models/homeassistant.py`)
| field | type | Null | Req |
|---|---|---|---|
| version | str \| None | Y | Y |
| version_latest | str \| None | Y | Y |
| update_available | bool | N | Y |
| machine | str \| None | Y | Y |
| ip_address | IPv4Address | N | Y |
| arch | str \| None | Y | Y |
| image | str | N | Y |
| boot | bool | N | Y |
| port | int | N | Y |
| ssl | bool | N | Y |
| watchdog | bool | N | Y |
| audio_input | str \| None | Y | Y |
| audio_output | str \| None | Y | Y |
| backups_exclude_database | bool | N | Y |
| duplicate_log_file | bool | N | Y |

### 13. `OSInfo` — `GET os/info` (+ `BootSlot`) (`aiohasupervisor/models/os.py`)
| field | type | Null | Req |
|---|---|---|---|
| version | str \| None | Y | Y |
| version_latest | str \| None | Y | Y |
| update_available | bool | N | Y |
| board | str \| None | Y | Y |
| boot | str \| None | Y | Y |
| data_disk | str \| None | Y | Y |
| boot_slots | dict[str, BootSlot] | N | Y |

`BootSlot` inner model:
| field | type | Null | Req |
|---|---|---|---|
| state | str | N | Y |
| status | RaucState \| None (good/bad/active) | Y | Y |
| version | str \| None | Y | Y |

### 14. `HostInfo` — `GET host/info` (`aiohasupervisor/models/host.py`)
| field | type | Null | Req |
|---|---|---|---|
| agent_version | str \| None | Y | Y |
| apparmor_version | str \| None | Y | Y |
| chassis | str \| None | Y | Y |
| virtualization | str \| None | Y | Y |
| cpe | str \| None | Y | Y |
| deployment | str \| None | Y | Y |
| disk_free | float | N | Y |
| disk_total | float | N | Y |
| disk_used | float | N | Y |
| disk_life_time | float \| None | Y | Y |
| features | list[HostFeature] | N | Y |
| hostname | str \| None | Y | Y |
| llmnr_hostname | str \| None | Y | Y |
| kernel | str \| None | Y | Y |
| operating_system | str \| None | Y | Y |
| timezone | str \| None | Y | Y |
| dt_utc | datetime \| None | Y | Y |
| dt_synchronized | bool \| None | Y | Y |
| use_ntp | bool \| None | Y | Y |
| startup_time | float \| None | Y | Y |
| boot_timestamp | int \| None | Y | Y |
| broadcast_llmnr | bool \| None | Y | Y |
| broadcast_mdns | bool \| None | Y | Y |

`HostFeature` enum (explicitly documented in source as an *incomplete* list — unknown values
parse through as bare strings): disk, haos, hostname, journal, mount, network, os_agent, reboot,
resolved, services, shutdown, timedate.

### 15. `NetworkInfo` (`aiohasupervisor/models/network.py`) — `GET network/info`
| field | type | Null | Req |
|---|---|---|---|
| interfaces | list[NetworkInterface] | N | Y |
| docker | DockerNetwork | N | Y |
| host_internet | bool \| None | Y | Y |
| supervisor_internet | bool | N | Y |

`NetworkInterface`:
| field | type | Null | Req |
|---|---|---|---|
| interface | str | N | Y |
| type | InterfaceType (ethernet/wireless/vlan) | N | Y |
| enabled | bool | N | Y |
| connected | bool | N | Y |
| primary | bool | N | Y |
| mac | str | N | Y |
| ipv4 | IPv4 \| None | Y | Y |
| ipv6 | IPv6 \| None | Y | Y |
| wifi | Wifi \| None | Y | Y |
| vlan | Vlan \| None | Y | Y |
| mdns | MulticastDnsMode \| None (default/off/resolve/announce) | Y | Y |
| llmnr | MulticastDnsMode \| None | Y | Y |

`IPv4` (extends `IpBase`: `method: InterfaceMethod` [disabled/static/auto], `ready: bool | None`):
| field | type | Null | Req |
|---|---|---|---|
| method | InterfaceMethod | N | Y |
| ready | bool \| None | Y | Y |
| address | list[IPv4Interface] | N | Y |
| nameservers | list[IPv4Address] | N | Y |
| gateway | IPv4Address \| None | Y | Y |
| route_metric | int \| None | Y | Y |

`IPv6` (extends `IpBase`, adds):
| field | type | Null | Req |
|---|---|---|---|
| method | InterfaceMethod | N | Y |
| ready | bool \| None | Y | Y |
| address | list[IPv6Interface] | N | Y |
| nameservers | list[IPv6Address] | N | Y |
| gateway | IPv6Address \| None | Y | Y |
| route_metric | int \| None | Y | Y |
| addr_gen_mode | InterfaceAddrGenMode (eui64/stable-privacy/default-or-eui64/default) | N | Y |
| ip6_privacy | InterfaceIp6Privacy (default/disabled/enabled-prefer-public/enabled) | N | Y |

`Wifi`:
| field | type | Null | Req |
|---|---|---|---|
| mode | WifiMode (infrastructure/mesh/adhoc/ap) | N | Y |
| auth | AuthMethod (open/wep/wpa-psk) | N | Y |
| ssid | str | N | Y |
| signal | int \| None | Y | Y |

`Vlan`: `id: int` (Req), `parent: str | None` (Req, nullable).

`AccessPoint` (`GET network/interface/{interface}/accesspoints`, wrapped in `AccessPointList`):
| field | type | Null | Req |
|---|---|---|---|
| mode | WifiMode | N | Y |
| ssid | str | N | Y |
| frequency | int | N | Y |
| signal | int | N | Y |
| mac | str | N | Y |

`DockerNetwork`:
| field | type | Null | Req |
|---|---|---|---|
| interface | str | N | Y |
| address | IPv4Network | N | Y |
| gateway | IPv4Address | N | Y |
| dns | IPv4Address | N | Y |

### 16. `ResolutionInfo` (+ `Issue`/`Suggestion`/`Check`) — `GET resolution/info` (`aiohasupervisor/models/resolution.py`)
`ResolutionInfo` extends `SuggestionsList` (adds `suggestions`):
| field | type | Null | Req |
|---|---|---|---|
| suggestions | list[Suggestion] | N | Y |
| unsupported | list[UnsupportedReason \| str] | N | Y |
| unhealthy | list[UnhealthyReason \| str] | N | Y |
| issues | list[Issue] | N | Y |
| checks | list[Check] | N | Y |

`Suggestion`:
| field | type | Null | Req |
|---|---|---|---|
| type | SuggestionType \| str | N | Y |
| context | ContextType (addon/core/dns_server/mount/os/plugin/supervisor/store/system) | N | Y |
| reference | str \| None | Y | Y |
| uuid | UUID | N | Y |
| auto | bool | N | Y |

`Issue`:
| field | type | Null | Req |
|---|---|---|---|
| type | IssueType \| str | N | Y |
| context | ContextType | N | Y |
| reference | str \| None | Y | Y |
| uuid | UUID | N | Y |

`Check`:
| field | type | Null | Req |
|---|---|---|---|
| enabled | bool | N | Y |
| slug | CheckType \| str | N | Y |

`SuggestionType`, `IssueType`, `UnsupportedReason`, `UnhealthyReason`, `CheckType` are all
explicitly documented as *incomplete* enums — new Supervisor releases add values regularly and
unknown ones are still accepted, deserialized as plain strings (the `X | str` union pattern).

### 17. `JobsInfo` + `Job` — `GET jobs/info` (`aiohasupervisor/models/jobs.py`)
`JobsInfo`:
| field | type | Null | Req |
|---|---|---|---|
| ignore_conditions | list[JobCondition \| str] | N | Y |
| jobs | list[Job] | N | Y |

`Job` (recursive):
| field | type | Null | Req |
|---|---|---|---|
| name | str \| None | Y | Y |
| reference | str \| None | Y | Y |
| uuid | UUID | N | Y |
| progress | float | N | Y |
| stage | str \| None | Y | Y |
| done | bool \| None | Y | Y |
| errors | list[JobError] | N | Y |
| created | datetime | N | Y |
| child_jobs | list[Job] | N | Y |
| extra | dict[str, Any] \| None | Y | Y |

`JobError` (aiohasupervisor's view — **narrower** than what Supervisor actually puts on the
wire, see §8):
| field | type | Null | Req |
|---|---|---|---|
| type | str | N | Y |
| message | str | N | Y |
| stage | str \| None | Y | Y |

`JobCondition` enum (also documented incomplete): auto_update, free_space, frozen, haos,
healthy, host_network, internet_host, internet_system, mount_available, os_agent,
plugins_updated, running, supervisor_updated.

### 18. `AddonsList` / installed addon summary — `GET addons` (`aiohasupervisor/models/addons.py`)
`AddonsList`: `addons: list[InstalledAddon]` (Req).

`InstalledAddon` = `AddonInfoBaseFields` + `AddonInfoStoreExtInstalledBaseFields` + `state`:
| field | type | Null | Req |
|---|---|---|---|
| advanced | bool (deprecated since Supervisor 2026.03; always `False`) | N | Y |
| available | bool | N | Y |
| build | bool | N | Y |
| description | str | N | Y |
| homeassistant | str \| None | Y | Y |
| icon | bool | N | Y |
| logo | bool | N | Y |
| name | str | N | Y |
| repository | str | N | Y |
| slug | str | N | Y |
| stage | AddonStage (stable/experimental/deprecated) | N | Y |
| update_available | bool | N | Y |
| url | str \| None | Y | Y |
| version_latest | str | N | Y |
| version | str \| None | Y | Y |
| detached | bool | N | Y |
| state | AddonState (startup/started/stopped/unknown/error) | N | Y |

`InstalledAddonComplete` (`GET addons/{slug}/info`) — all of `InstalledAddon` plus
`AddonInfoStoreBaseFields` (`arch: list[CpuArch]`, `documentation: bool`),
`AddonInfoStoreExtFields` (`apparmor`, `auth_api`, `docker_api`, `full_access`,
`homeassistant_api`, `host_network`, `host_pid`, `ingress`, `long_description`, `rating`,
`signed`, plus **wire-aliased** `supervisor_api` ⟵ `hassio_api` and `supervisor_role` ⟵
`hassio_role` — these two Python attribute names differ from their JSON keys), plus 30+
additional fields: `hostname`, `dns`, `protected`, `boot`, `boot_config`, `options`, `schema`,
`machine`, `network`, `network_description`, `host_ipc`, `host_uts`, `host_dbus`, `privileged`,
`changelog`, `stdin`, `gpio`, `usb`, `uart`, `kernel_modules`, `devicetree`, `udev`, `video`,
`audio`, `startup`, `services`, `discovery`, `translations`, `webui`, `ingress_entry`,
`ingress_url`, `ingress_port`, `ingress_panel`, `audio_input`, `audio_output`, `auto_update`,
`ip_address`, `watchdog`, `devices`, `system_managed`, `system_managed_config_entry` — all
required-on-wire (no defaults in the source), several nullable. See
`aiohasupervisor_models/addons.py` in the research scratch dir for exact types if the Elixir
struct needs the full 45-field enumeration; the two aliased fields are the one gotcha worth
flagging twice: **wire key `hassio_api` → struct field `supervisor_api`; wire key
`hassio_role` → struct field `supervisor_role`.**

### 19. `CoreStats` / stats models — `GET core/stats`, `GET supervisor/stats`, `GET addons/{slug}/stats`
All three reuse one shape, `ContainerStats` (`aiohasupervisor/models/base.py`), via empty
subclasses `HomeAssistantStats(ContainerStats)`, `SupervisorStats(ContainerStats)`,
`AddonsStats(ContainerStats)` — no additional fields on any of them.
| field | type | Null | Req |
|---|---|---|---|
| cpu_percent | float | N | Y |
| memory_usage | int | N | Y |
| memory_limit | int | N | Y |
| memory_percent | float | N | Y |
| network_rx | int | N | Y |
| network_tx | int | N | Y |
| blk_read | int | N | Y |
| blk_write | int | N | Y |

### 20. `StoreInfo` (`GET store`), `MountsInfo` (`GET mounts`)
`StoreInfo` extends `StoreAddonsList` (adds `repositories`):
| field | type | Null | Req |
|---|---|---|---|
| addons | list[StoreAddon] | N | Y |
| repositories | list[Repository] | N | Y |

`StoreAddon` = `AddonInfoBaseFields` + `AddonInfoStoreBaseFields` + `installed: bool` (same base
fields as `InstalledAddon` §18, minus `detached`/`state`, plus `arch`, `documentation`,
`installed`).

`Repository`:
| field | type | Null | Req |
|---|---|---|---|
| slug | str | N | Y |
| name | str | N | Y |
| source | str | N | Y |
| url | str | N | Y |
| maintainer | str | N | Y |

`MountsInfo`:
| field | type | Null | Req |
|---|---|---|---|
| default_backup_mount | str \| None | Y | Y |
| mounts | list[CIFSMountResponse \| NFSMountResponse] | N | Y |

`CIFSMountResponse`/`NFSMountResponse` combine `Mount` (`usage: MountUsage`
[backup/media/share], `server: str`, `port: int | None = None`), `MountResponse` (`name: str`,
`read_only: bool`, `state: MountState | None` [active/activating/deactivating/failed/inactive/
maintenance/reloading], `user_path: PurePath | None`), and either `CIFSMount` (`share: str`,
`version: MountCifsVersion | None = None`) + `type: Literal["cifs"]`, or `NFSMount`
(`path: PurePath`) + `type: Literal["nfs"]`.

### 21. `AvailableUpdates` / `AvailableUpdate` — `GET available_updates` (`aiohasupervisor/models/root.py`)
`AvailableUpdates`: `available_updates: list[AvailableUpdate]` (Req). Note: unlike most
`ResponseData` wrappers, the client method `SupervisorClient.available_updates()` unwraps this
itself and returns `list[AvailableUpdate]` directly, not the wrapper object.

`AvailableUpdate`:
| field | type | Null | Req |
|---|---|---|---|
| update_type | UpdateType (addon/core/os/supervisor) | N | Y |
| panel_path | str | N | Y |
| version_latest | str | N | Y |
| name | str \| None | Y | N (default `None`) |
| icon | str \| None | Y | N (default `None`) |

### 22. `HomeAssistantOptions` — accepted fields of `POST core/options` (URL is `core/options`, not `homeassistant/options`)
All fields optional (`Options` base, `omit_default=True` — a field left at its default is
dropped from the outgoing JSON entirely):
| field | type | default |
|---|---|---|
| boot | bool \| None | `None` |
| image | str \| None | `DEFAULT` sentinel (distinct from `None`; lets caller explicitly send `null` to clear the image override, vs. omitting the key entirely) |
| port | int \| None | `None` |
| ssl | bool \| None | `None` |
| watchdog | bool \| None | `None` |
| refresh_token | str \| None | `DEFAULT` sentinel |
| audio_input | str \| None | `DEFAULT` sentinel |
| audio_output | str \| None | `DEFAULT` sentinel |
| backups_exclude_database | bool \| None | `None` |
| duplicate_log_file | bool \| None | `None` |

Core only ever populates `ssl`, `port`, `refresh_token` (§5). The `Options.__post_init__`
validator raises `ValueError` if *no* field has a value at all (`to_dict()` empty) — i.e. the
model refuses to serialize to `{}`.

### Raw-dict vs. aiohasupervisor-model parsing in Core

Core parses **all** of the polled main/addon/stats endpoints above (§3) through aiohasupervisor
models — `coordinator.py` imports and type-annotates against `HomeAssistantInfo`,
`SupervisorInfo`, `HostInfo`, `OSInfo`, `StoreInfo`, `NetworkInfo`, `CIFSMountResponse`,
`NFSMountResponse`, `InstalledAddon`, `InstalledAddonComplete`, `AddonsStats`,
`HomeAssistantStats`, `SupervisorStats`, `RootInfo`. `issues.py` parses `ResolutionInfo` and
individual `Issue` dicts the same way.

The one remaining **raw-dict** path is the generic WS pass-through,
`websocket_supervisor_api` (`websocket_api.py`), which lets the frontend call *any* Supervisor
endpoint/method via `{"type": "supervisor/api", "endpoint": ..., "method": ..., "data": ...,
"params": ...}` and forwards the response envelope's `data` key back to the frontend verbatim
(via the legacy `HassIO.send_command`, which just does `response.json()` — no model
deserialization at all). Core does read two specific keys out of that raw dict itself: it strips
`options` from add-on info responses for non-admin users
(`data.pop("options", None)` gated on `WS_ADDONS_INFO_ENDPOINT` matching
`/addons/{slug}/info`), and it special-cases `command == "/ingress/session"` by injecting
`payload["user_id"] = connection.user.id` before forwarding the request. The legacy REST proxy
`HassIOView` (`http.py`, `/api/hassio/{path}`) is pure byte-stream passthrough and never parses
JSON at all — it only inspects the request `path` string (for auth-scoping regexes) and a
handful of headers.

---

## 7. `SupervisorJob.as_dict()` — `supervisor/jobs/__init__.py`

```python
def as_dict(self) -> dict[str, Any]:
    return {
        "name": self.name,
        "reference": self.reference,
        "uuid": self.uuid,
        "progress": round(self.progress, 1),
        "stage": self.stage,
        "done": self.done,
        "parent_id": self.parent_id,
        "errors": [err.as_dict() for err in self.errors],
        "created": self.created.isoformat(),
        "extra": self.extra,
    }
```
`SupervisorJobError.as_dict()`:
```python
{
    "type": self.type_.__name__,
    "message": self.message,
    "stage": self.stage,
    "error_key": self.error_key,
    "extra_fields": self.extra_fields,
}
```

This raw dict is used in two different shapes on the wire, per `supervisor/api/jobs.py`
(`_list_jobs`):
- **`GET jobs/info`** (`{"ignore_conditions": [...], "jobs": [...]}`) and **`GET
  jobs/{uuid}`**: each job dict is `as_dict()` **minus `parent_id`, plus an injected
  `child_jobs: [...]`** (nested recursively, oldest-inserted-child order; the whole job list is
  organized into a parent/child tree and `parent_id` is dropped because the tree structure
  already encodes it).
- **`job` WS event** (`supervisor/homeassistant/websocket.py` →
  `homeassistant/components/hassio/jobs.py`): the payload is the flat `as_dict()` **including
  `parent_id`, with no `child_jobs` key at all** — Core's `jobs.py` manually unions in
  `{"child_jobs": []}` before calling `aiohasupervisor.models.jobs.Job.from_dict(...)`, purely
  so the shared `Job` dataclass (which requires the key) can deserialize a single flat event.

**Field mismatch to flag for the emulator:** `SupervisorJobError.as_dict()` puts 5 keys on the
wire (`type`, `message`, `stage`, `error_key`, `extra_fields`), but aiohasupervisor's `JobError`
model (§17) only declares 3 (`type`, `message`, `stage`). Since none of these dataclasses set
`forbid_extra_keys`, `error_key`/`extra_fields` are present in the real JSON but silently dropped
by the Python client on deserialization — an Elixir client mirroring aiohasupervisor's
*documented* model would lose that data, whereas an emulator mirroring the *wire format* should
still emit all 5 keys (real clients such as frontend JS may read `error_key`/`extra_fields`
directly off the JSON without going through aiohasupervisor at all).

---

## 8. Unconfirmed items

- **`WSEvent.ADDON = "addon"`** (defined in `supervisor/homeassistant/const.py`) — no emission
  call site was found via GitHub code search across the pinned Supervisor tag's tree structure
  actually fetched (`core.py`, `updater.py`, `supervisor.py`, `host/network.py`,
  `homeassistant/websocket.py`); Core's hassio component has no handler for it either. It may be
  emitted from a file not covered by the `supervisor_update_event`/`supervisor_event`/
  `supervisor_event_custom` grep (e.g. addon manager code paths not directly searched), or it may
  be vestigial. **Marked UNCONFIRMED** — do not rely on it being part of the live contract; if
  the emulator needs addon-lifecycle push events, use `job` events (name-matched) instead, which
  are fully confirmed.
- **Full 45-field enumeration of `InstalledAddonComplete`** is listed by name in §18 with types
  described qualitatively rather than transcribed field-by-field into a table (would roughly
  double this document's length for a model whose extra fields beyond `InstalledAddon` are
  mostly self-descriptive container/addon config knobs). The exact source is captured verbatim
  in the research scratch copy of `aiohasupervisor/models/addons.py`
  (`InstalledAddonComplete`, lines 211–261 at tag `0.5.0`) if a 1:1 Elixir struct transcription is
  needed — recommend a follow-up pass reads that class directly rather than relying on this
  doc's prose summary.
- **`DiskUsage`** (`aiohasupervisor/models/host.py`, backing `GET host/disks/default/usage` or
  similar) was read but not requested by the task's question list and is omitted here — flagging
  its existence in case host disk-usage entities are in scope for the emulator later.
- Whether the Supervisor's own WS *server* (accepting Core's `supervisor/api` /
  `supervisor/subscribe` calls) enforces anything beyond what's in `websocket_api.py` on the
  Core side was not investigated — this doc only covers what Core sends/expects, per the task's
  framing that Core's parsing is the strictness spec.
