# Supervisor API Contract — M4 Add-on / Container Surface (addendum)

Extends `docs/contract-2026.7.md` (which pins the coordinator/WS/token surface at
Core 2026.7.2 / Supervisor 2026.07.3 / aiohasupervisor 0.5.0) with the surface
**Milestone 4** needs: add-on install/start lifecycle + container parameters,
the options schema DSL, the `/services`+`/discovery`+`/auth` MQTT path, the
backup format, the logs endpoints, and DNS/network wiring.

Pinned 2026-07-21 from real source via the `ha-github-search` MCP (repos
`supervisor`, `core`, `addons`, `frontend`). Every non-obvious claim cites
`repo:path:line`; where a large file had no per-line offsets the cite is
`file` + symbol.

---

## A0. READ FIRST — version drift + a syntax non-bug

**The indexed `supervisor` is a dev/fork HEAD, ahead of stock 2026.07.x.** Two
independent signals:

- `supervisor/const.py:14` → `SUPERVISOR_VERSION = "9999.09.9.dev9999"` (a dev
  placeholder, not a release tag).
- The codebase is **mid-migration `addon` → `app`**: the module is
  `supervisor/apps/` (not `addons/`); the model class is `App`/`AppModel`
  (`supervisor/apps/app.py`, `apps/model.py`); the Docker wrapper is `DockerApp`
  in `supervisor/docker/app.py` (the old `docker/addon.py` and
  `addons/addon.py` are gone); the persist file is `apps.json`
  (`FILE_HASSIO_APPS = /data/apps.json`, `const.py:31`). Deprecation comments
  cite "as of 2026.05"/"2026.07".
- There is a **V1/V2 API split** (`AppVersion` enum, `api/const.py:79`): V2 is a
  `/v2` sub-app gated behind the `SUPERVISOR_V2_API` feature flag
  (`api/__init__.py:100-104`, **off by default**). V2 routes use `/apps/*` and
  the `app` JSON key; V1 routes use `/addons/*` / `/store/addons/*` and keep the
  legacy **`addon`** key (v1 handlers `data[ATTR_ADDON] = data.pop(ATTR_APP)`).

**Consequence for the emulator:** target the **V1 wire contract** (default when
the flag is off) — that is what bashio, the Mosquitto add-on, and Core's hassio
client actually hit, and it uses the `addon` key and `/addons/*` paths. Treat the
field-name details below as newer-than-2026.07.3; re-verify against the exact
release the device targets before shipping.

**Syntax non-bug (do not "fix"):** the source contains `except IndexError,
KeyError:` (`apps/options.py`), `except TimeoutError, aiohttp.ClientError:`,
`except DockerError, AppNotSupportedError:` (`apps/app.py`), and
`except KeyError, TypeError, ValueError:` (`docker/app.py:113`). These are
**valid Python 3.14 (PEP 758)** unparenthesized multi-type `except` clauses —
they catch *all listed types*. They are NOT Python-2 bugs and NOT
"seeded"/index artifacts. Three of the six research agents misfired on this;
the behavioral contract is "catch every listed exception type."

---

## A1. Add-on install + start lifecycle + container params

### A1.1 Endpoints (V1 — target these)

Route table `supervisor/api/__init__.py`; handlers `api/store.py`, `api/apps.py`.
Envelope per `api/utils.py`: OK `{"result":"ok","data":{…}}` (`utils.py:186`,
`None`→`{}`); error `{"result":"error","message":str,…}` HTTP 400 default
(`utils.py:142`). Auth header `X-Supervisor-Token` (legacy `X-Hassio-Key`, or
`Authorization: Bearer`) (`const.py:112-113`).

| Purpose | V1 path + method | Handler |
|---|---|---|
| Store info | `GET /store` | `store.store_info_v1` (`store.py:203`) |
| Store add-on list | `GET /store/addons` | `store.apps_list_v1` (`store.py:230`) |
| Store reload | `POST /store/reload` (+ `POST /addons/reload`) | `store.reload` → `sys_store.reload()` (`store.py:187`) |
| Store add-on info | `GET /store/addons/{slug}[/{version}]` | `store.apps_app_info` |
| **Install** | `POST /store/addons/{slug}/install[/{version}]` (+ legacy `POST /addons/{slug}/install`) | `store.apps_app_install` (`store.py:236`) |
| Update | `POST /store/addons/{slug}/update[/{version}]` | `store.apps_app_update` |
| **Uninstall** | `POST /addons/{slug}/uninstall` | `apps.uninstall` |
| **Start / Stop / Restart / Rebuild** | `POST /addons/{slug}/{start,stop,restart,rebuild}` | `apps.*` |
| **Set options** | `POST /addons/{slug}/options` | `apps.options` |
| System options / validate / effective config | `POST /addons/{slug}/{sys_options,options/validate}`, `GET /addons/{slug}/options/config` | `apps.*` |
| Security (protection) | `POST /addons/{slug}/security` `{protected: bool}` | `apps.security` |
| Info / stats / logs / stdin | `GET /addons/{slug}/{info,stats,logs}`, `POST …/stdin` | `apps.*` |
| Repos | `POST /store/repositories`, `DELETE /store/repositories/{repository}` | `store.*` |

Request bodies: Install/Update `{background: bool=false}` (+`backup: bool` on
update) (`store.py:64,74`); `background:true` + not-yet-done → `{"job_id":<uuid>}`
(`store.py:243`). Options `SCHEMA_OPTIONS` (`apps.py:123`):
`{boot, network(port-map|null), auto_update, audio_output, audio_input,
ingress_panel, watchdog, options(dict|null)}` — persisted, validated against the
add-on's own schema, does **not** restart. Uninstall `{remove_config: bool=false}`.
Rebuild `{force: bool=false}`.

### A1.2 Install flow

`AppManager.install(slug)` (`apps/manager.py:216`, `@Job APP_UPDATE_CONDITIONS`,
queued) → validate not-installed + `store.validate_availability()` →
`App(coresys, slug).install()` (`apps/app.py:924`):
1. `sys_apps.data.install(store)` — copy store config into persisted system data.
2. `mkdir path_data = <config.path_apps_data>/<slug>` = `apps/data/<slug>`
   (`app.py:753-756`; `config.py:42 APPS_DATA=apps/data`).
3. `install_apparmor()`.
4. `instance.install(latest_version, image, arch)`.

`DockerApp.install()` (`docker/app.py:692`): if `need_build` (⇔ **no `image:`
key** in config, `model.py:need_build`) → local `_build()` via builder image
`docker:<engine-ver>-cli`. Else `DockerInterface.install()` (`interface.py:270`):
**pull** `image:version`, `platform = MAP_ARCH[arch]` where
`MAP_ARCH = {AARCH64:"linux/arm64", AMD64:"linux/amd64"}` (`interface.py:60`).

Image/tag (`AppModel._image`): with `image:` → `config["image"].format(arch=arch)`
(e.g. `homeassistant/{arch}-addon-mosquitto` → `homeassistant/amd64-addon-mosquitto`),
tag = `config["version"]`; local build → `f"{repository}/{arch}-addon-{slug}"`.
`arch = sys_arch.match(config["arch"])` (aarch64|amd64).

Data-root layout (host root e.g. `/mnt/data/supervisor`, mapped into containers):
`apps/data/<slug>`→`/data`, `app_configs/<slug>`→`/config`, `ssl`→`/ssl`,
`share`→`/share`, `media`→`/media`, `backup`→`/backup`, `homeassistant`→
`/homeassistant` (`config.py:37-59`, `docker/const.py:191-203`).

### A1.3 Start flow

`App.start()` (`apps/app.py:1287`):
1. already-running → return wait task.
2. **`persist["access_token"] = secrets.token_hex(56)`** (112 hex chars) →
   `save_persist()` (`app.py:1303`) — the per-add-on Supervisor token,
   **regenerated on every start**.
3. `write_options()` → validate against schema → write `<path_data>/options.json`
   = `/data/options.json` in-container (§A2).
4. `write_pulse()` if audio; `mkdir path_config` if app_config used.
5. `instance.run()`.

### A1.4 Container run parameters (`DockerApp.run` → `manager._create_container_config`)

| Param | Value / rule |
|---|---|
| image:tag | `app.image : str(app.version)` |
| name | `f"addon_{slug}"` (e.g. `addon_core_mosquitto`) |
| hostname | `None` if uts_mode else `slug.replace("_","-")` (`core-mosquitto`) (`model.py:182`) |
| Domainname | `local.hass.io` (when hostname set + dns on) |
| network | `network_mode="host"` iff `host_network`; else attach `hassio` bridge, `Aliases=[hostname]`, dynamic IPv4, detach default bridge |
| DNS | `Dns=["172.30.32.3"]`, `DnsSearch=["local.hass.io"]`, `DnsOptions=["timeout:10"]` |
| extra_hosts | `{"supervisor":172.30.32.2, "hassio":172.30.32.2}` |
| environment | config `environment:` + `TZ` + **`SUPERVISOR_TOKEN`** + **`HASSIO_TOKEN`** (both = access_token) (`docker/const.py:180-184`) |
| Init | `config init:` (`app.default_init`) |
| OpenStdin | `with_stdin` |
| detach | `True` |
| PidMode | `"host"` iff **`not protected and host_pid`** |
| UtsMode | `"host"` iff `host_uts` |
| ports | `None` if host_network; else `{container:host}` → `PortBindings`+`ExposedPorts` (default `/tcp`) |
| DeviceCgroupRules | device policy groups; full-access rule iff **`not protected and with_full_access`** |
| CapAdd | `set(config privileged:)` + `SYS_MODULE`(kernel_modules) + `SYS_NICE`(realtime) — **NOT** protection-gated |
| Ulimits | rtprio 90/99 + memlock 128MB if realtime; + config `ulimits:` |
| CPURealtimeRuntime | `190000` iff realtime + host supports |
| SecurityOpt | **always `["seccomp=unconfined"]`** (`interface.py:security_opt`); + `apparmor=unconfined` if unavailable/`apparmor:disable`, or `apparmor=<slug>` if a profile exists, else nothing. **`no-new-privileges` is NOT set.** |
| Privileged | **`False`** — never set; add-on `privileged:` → `CapAdd`, not Docker privileged |
| Tmpfs | `/tmp` iff `tmpfs:true`; `/dev/shm` iff `not host_ipc` |
| OomScoreAdj | **`200`** (hardcoded) |
| Labels | `{"supervisor_managed": ""}` |
| RestartPolicy | **none** — Supervisor manages start/stop |
| CID file | bind host `<cid_files>/<name>.cid` → `/run/cid` ro |

Mounts (`DockerApp.mounts`, each `{Type:"bind",Source,Target,ReadOnly,BindOptions?}`):
always `/dev`→`/dev` ro + `<extern_data>`→`/data` rw; `map:`-driven
`config`→`/config`|`/homeassistant`, `addon_config`→`/config`, `ssl`→`/ssl`,
`share`→`/share` (rslave), `media`→`/media` (rslave), `backup`→`/backup`;
conditional `/run/docker.sock` ro iff `not protected and access_docker_api`,
`/run/dbus` ro (host_dbus), `/run/udev` ro (udev), `/lib/modules` ro
(kernel_modules), devicetree, gpio, pulse/asound (audio), journald ro.

### A1.5 Protection mode (`app.protected`, default **True**)

Only three things are gated (all disabled while protected): **docker socket
mount** (`not protected and access_docker_api`), **full hardware cgroup access**
(`not protected and with_full_access`), **host PID** (`not protected and
host_pid`). Set via `POST /addons/{slug}/security {protected}`. NOT gated:
`privileged:` caps, `host_network`, `host_ipc`, `host_uts`, `host_dbus`,
apparmor.

### A1.6 The `:container | :native | :microvm` backend seam

`App.instance` is a `DockerInterface` (`docker/interface.py`). The backend
behaviour must implement: `install(version,image,latest,arch)`, `run`, `start`,
`stop(remove_container)`, `remove(remove_image)`, `attach(version)`, `update`,
`check_image`, `cleanup`, `import_image`/`export_image`, `is_running`,
`current_state()→ContainerState`, `stats()→DockerStats`, `logs`,
`execute_command`/`run_inside`, `write_stdin`. The `App` model holds
backend-agnostic config+state; `DockerApp` is the only Docker-specific layer.
State enums: `ContainerState{failed,healthy,running,stopped,unhealthy,unknown}`
+ `DOCKER_CONTAINER_STATE_CHANGE` bus event; `AppState{startup,started,stopped,
unknown,error}`.

---

## A2. Add-on options schema DSL + options.json

### A2.1 The element regex (`apps/options.py:31`, `RE_SCHEMA_ELEMENT`)

```
^(?:|bool|email|url|port
  |device(?:\((?P<filter>subsystem=[a-z]+)\))?
  |str(?:\((?P<s_min>\d+)?,(?P<s_max>\d+)?\))?
  |password(?:\((?P<p_min>\d+)?,(?P<p_max>\d+)?\))?
  |int(?:\((?P<i_min>-?\d+)?,(?P<i_max>-?\d+)?\))?
  |float(?:\((?P<f_min>-?\d*\.?\d+)?,(?P<f_max>-?\d*\.?\d+)?\))?
  |match\((?P<match>.*)\)
  |list\((?P<list>.+)\))\??$
```

Structural meta-schema (`apps/validate.py:143`, `SCHEMA_ELEMENT`):
`vol.Any(vol.Match(RE_SCHEMA_ELEMENT), [vol.Any(scalar, {str: vol.Self})],
{str: vol.Self})`. A **list may not directly contain another list** (only a
scalar or a dict); dict nesting is unbounded.

### A2.2 Token → validation (`AppOptions._single_validate`, voluptuous)

| Token | Validation |
|---|---|
| `str`, `str(min,max)` | `vol.All(str, vol.Length(min,max))` |
| `password`, `password(min,max)` | as `str`; also `pwned.add(sha1(value))` |
| `int`, `int(min,max)` | `vol.All(vol.Coerce(int), vol.Range(min,max))` (neg ok) |
| `float`, `float(min,max)` | `vol.All(vol.Coerce(float), vol.Range)` (neg, decimals) |
| `bool` | `vol.Boolean()` (`1/true/yes/on`) |
| `email` / `url` | `vol.Email()` / `vol.Url()` |
| `port` | `network_port = vol.All(vol.Coerce(int), vol.Range(1,65535))` (`validate.py:67`) |
| `match(RE)` | `vol.Match(RE)(str(value))` (prefix match) |
| `list(a\|b\|c)` | `vol.In(split("\|"))(str(value))` (value stringified) |
| `device[(subsystem=x)]` | `sys_hardware.get_by_path`; adds to `devices` set; optional udev-subsystem filter |
| trailing `?` | optional — absence allowed; does not change value validation |
| `[element]` | value must be `list`; each item vs `element[0]` |
| `{k: element}` | value must be `dict`; unknown sub-keys **dropped w/ warning**; recurses |

Errors: unknown top-level/nested key → warn + **silently dropped**; `None` for a
present key → `vol.Invalid("Missing required option")`; unknown token →
`vol.Invalid("Unknown type")`; missing key allowed **only if** its schema token
(or the single list element) is a `str` ending in `?`; `!secret name` resolved
from `sys_homeassistant.secrets` (unknown → Invalid).

### A2.3 options.json compute + write

Effective options = `deepmerge.Merger(type_strategies=[(dict,["merge"])],
fallback=["override"], type_conflict=["override"]).merge(config-default options,
user options)` — dicts merge recursively, **lists/scalars overridden by the user
layer**, user wins on conflict (`App.options`, `apps/app.py`). Then
`write_options()` (`app.py:866`): `secrets.reload()` → `schema.validate(options)`
→ `write_json_file(path_options, options)`. If `schema: false`, validation is
skipped and merged options are written verbatim.

File = `<path_data>/options.json` → **`/data/options.json`** in-container; format
`orjson.dumps(OPT_INDENT_2|OPT_NON_STR_KEYS)` (2-space JSON, UTF-8), written
atomically then `chmod 0o600` (`utils/json.py:50`). **Regenerated on every
start**, before the container launches.

### A2.4 config.yaml fields that matter for start (`_SCHEMA_APP_CONFIG`, `apps/validate.py:439-542`)

`name`(req), `version`(req), `slug`(req, `RE_SLUG=[-_.A-Za-z0-9]+`),
`arch`(In aarch64,amd64), `startup`(default `application`:
initialize|system|services|application|once), `boot`(auto|manual|manual_only),
`init`(bool, default True), `ingress`/`ingress_port`(default 8099),
`ports`(`{docker_port: network_port|null}`), `watchdog`(Match
`^(?:https?|\[PROTO:\w+\]|tcp)://\[HOST\]:(\[PORT:\d+\]|\d+).*$`), `map`(list of
`{type, read_only=True, path?}`), `hassio_api`+`hassio_role`(In default,
homeassistant, backup, manager, admin), `homeassistant_api`, `auth_api`,
`docker_api`, `services`(`[Match ^(mqtt|mysql):(provide|want|need)$]`),
`discovery`(`[str]`), `host_network`/`host_dbus`/`host_pid`/`host_ipc`/`host_uts`,
`privileged`(`[Capabilities]`), `full_access`, `image`(absent ⇒ local build),
`options`(dict, defaults layer), `schema`(`{str: SCHEMA_ELEMENT}` or `false`),
`apparmor`(default True), `backup`(hot/cold)+`backup_pre`/`backup_post`/
`backup_exclude`, `timeout`(10-300, def 10), plus udev/tmpfs/gpio/usb/uart/
kernel_modules/realtime/audio/video/stdin/journald.

---

## A3. Services / discovery / auth (the MQTT path) — V1 wire

### A3.1 `/services/mqtt` (`api/services.py`, `services/modules/mqtt.py`)

- `GET /services/{service}` (`get_service_v1`), `POST /services/{service}`
  (`set_service`), `DELETE /services/{service}` (`del_service`),
  `GET /services` → `{services:[{slug,available,providers}]}`.
- Access (`_check_access`): caller's `services_role[service]` truthy; write/delete
  requires it to equal `PROVIDE_SERVICE`.
- **POST body** `SCHEMA_SERVICE_MQTT` (`mqtt.py:27-37`): `host`(req str),
  `port`(req `network_port`), `username`?(str), `password`?(str), `ssl`?(bool,
  default False), `protocol`?(str in `["3.1","3.1.1"]`, default `"3.1.1"`).
  Second POST while provided → `ServiceAlreadyProvidedError`.
- **GET response** = stored `{host,port,username,password,ssl,protocol}` **plus
  `addon: <provider slug>`** (V1 renames `app`→`addon`; V2 keeps `app`). Error
  `"Service not enabled"` if none posted yet.

### A3.2 `/discovery` (`api/discovery.py`, `discovery/__init__.py`)

- `GET /discovery` + `GET /discovery/{uuid}` (`@require_home_assistant`),
  `POST /discovery`, `DELETE /discovery/{uuid}` (owner only).
- **POST body** `SCHEMA_DISCOVERY`: `{service(req str), config(req dict)}`. Caller
  must declare `service` in its own `discovery:` list, else 403. The provider
  slug is taken from the authenticated caller, **not** the body. **Response
  `{"uuid": <hex>}`** (`uuid4().hex`).
- **GET single** (V1) → `{addon, service, uuid, config}`. **GET list** →
  `{discovery:[…], services:{<svc>:[slug,…]}}`; only messages whose app is
  installed and `STARTED`.
- **Forward to Core** (`Discovery._push_discovery`): on POST/DELETE, Supervisor
  calls Core `POST|DELETE api/hassio_push/discovery/{uuid}` with the message
  **minus `config`**, `app` renamed to `addon` — only when `check_api_state()`.
- **Core side** (`core: homeassistant/components/hassio/discovery.py`,
  `/api/hassio_push/discovery/{uuid}`, `@require_admin`): **ignores the pushed
  body**, re-fetches the full record via `supervisor_client.discovery.get(uuid)`
  (anti-injection), reads `.addon/.service/.config/.uuid`, injects
  `config["addon"]=<addon name>`, then `discovery_flow.async_create_flow(
  service=<service>, source=hassio, HassioServiceInfo(config,name,slug,uuid))`.
  So the config-flow domain **is the service string** (`"mqtt"`), and mqtt's
  `async_step_hassio` consumes `config[host/port/username/password/ssl/protocol]`.

### A3.3 `/auth` (`api/auth.py`, `supervisor/auth.py`)

- `GET/POST /auth`, `POST /auth/reset`, `DELETE /auth/cache`, `GET /auth/list`.
  Caller must be an app with `access_auth_api` true, else 403.
- Three credential channels (in order): **Basic** header; **JSON** (`username`
  or alias `user` + `password`); **form** (`application/x-www-form-urlencoded`).
  Success → `true` (200); failure → `401` + `WWW-Authenticate: Basic realm=
  "Home Assistant Authentication"`.
- Backend `check_login`: local sha256 cache (19-round rehash), then if HA running
  `POST core api/hassio_auth {username,password,addon=<slug>}` (200 ⇒ true).

### A3.4 Mosquitto add-on runtime (`addons/mosquitto/`, v7.1.0)

`config.yaml`: `auth_api:true`, `discovery:[mqtt]`, `services:[mqtt:provide]`,
ports `1883/1884/8883/8884`, `startup:system`, `watchdog:tcp://[HOST]:1883`,
`init:false`, `map:[ssl,share]`, `image:homeassistant/{arch}-addon-mosquitto`.
`cont-init.d/mosquitto.sh` generates two 64-char passwords into
`/data/system_user.json` (`homeassistant`, `addons` users). The
`services.d/mosquitto/discovery` script, after `net.wait_for 1883`:
1. `bashio::discovery mqtt "$cfg"` → **POST `/discovery`** service=mqtt,
   `config={host=<hostname>,port=1883,ssl=false,protocol="3.1.1",
   username="homeassistant",password=<discovery_pw>}`.
2. `bashio::services.delete mqtt` → **DELETE `/services/mqtt`** (failure tolerated).
3. `bashio::services.publish mqtt "$cfg"` → **POST `/services/mqtt`** same fields,
   `username="addons"`, `password=<service_pw>`.
An in-container NGINX at `127.0.0.1:80` bridges external MQTT-client auth:
`/authentication` → `proxy_pass http://supervisor/auth` (+ `X-Supervisor-Token`);
`/superuser` and `/acl` → `200`. The `files` backend serves the system users +
configured `logins[]`; only unknown external clients hit `/auth`.

---

## A4. Backup format + lifecycle

**Outer** = plain **uncompressed** tar (`.tar`, store-only), members `./`-prefixed,
written via `securetar.SecureTarArchive`. `create_version` = 3 when Core ≥
`2026.3.0` else 2 (selects inner-encryption header). Members: `./backup.json`
(plaintext JSON, always), `./homeassistant.tar[.gz]`, `./<slug>.tar[.gz]` per
add-on, `./<folder>.tar[.gz]` (`name.replace("/","_")`; folders share, addons,
ssl, media), `./supervisor.tar[.gz]` (mounts+registries, if any). `.tar.gz` iff
`compressed` (default true).

`backup.json` (`backups/validate.py SCHEMA_BACKUP`, `extra=ALLOW_EXTRA`):
required `slug,type(full|partial),name,date(ISO8601)`; `version`(1|2, **new=2**),
`supervisor_version`, `compressed`(def true), `protected`(def false),
`homeassistant`(nullable `{version(req),size,exclude_database}`), `folders`([]),
`addons`([{slug,name,version,size}] — **key is `addons`** on disk), `repositories`,
`extra`. (`crypto` removed on load.)

Inner add-on tar (`arcname="."`): `addon.json` `{user,system,version,state}`,
`data/`, optional `config/`, optional `apparmor.txt`, optional `image.tar`
(local builds). Core tar: `homeassistant.json` + `data/` (with excludes; DB
excluded when `exclude_database`). On restore only
`audio_input,audio_output,port,ssl,refresh_token,watchdog` are re-applied.

**Encryption is per-inner-tar** (outer tar + `backup.json` always plaintext);
empty password = none. **securetar crypto internals (cipher, KDF, v2↔v3 byte
layout) are NOT indexed** — external dep `securetar==2026.4.1`; must be read
directly for byte-for-byte encrypted interop (see A7).

Hot/cold (`apps/const.py AppBackupMode`, default HOT): `begin_backup` — not
running → skip; COLD → stop; else run `backup_pre`. `end_backup` — COLD →
start; else `backup_post`. Core hot freeze is WS `BACKUP_START`/`BACKUP_END`,
not a stop.

**Restore-while-running** (`backups/manager.py`): full restore tears down Core +
all apps first (`replace=True`). **Partial restore stops Core only if
`homeassistant=true` is in the request**; a partial restore of folders/add-ons
alone does **not** stop Core (each restored add-on is individually
stopped/recreated). Blocked if `backup.supervisor_version > current`.

Endpoints (`api/backups.py`): `GET /backups`, `GET /backups/info`,
`POST /backups/{options,reload,freeze,thaw}`, `POST /backups/new/{full,partial}`
(→`{job_id,slug}`), `POST /backups/new/upload`, `DELETE /backups/{slug}`,
`GET /backups/{slug}/info`, `POST /backups/{slug}/restore/{full,partial}`
(→`{job_id}`), `GET /backups/{slug}/download` (`application/tar`). Partial
bodies use `addons:"ALL"|[slug]` + `folders` + `homeassistant`. `filename` must
match `^[^\/]+\.tar$`.

---

## A5. Logs endpoints + format

All log routes share `APIHost.advanced_logs` (`api/host.py:200-311`); per-route
vars are a syslog `identifier` and `default_verbose`. **Response is always
`Content-Type: text/plain`, chunked, one formatted entry per line
(`line + "\n"`, UTF-8)** — NOT journal-export, NOT JSON. Required response
headers: **`X-First-Cursor: <cursor>`** and **`X-Accel-Buffering: no`** before the
first byte.

- Verbose line: `YYYY-MM-DD HH:MM:SS.mmm <hostname> <identifier>[<pid>]: <message>`.
  Plain line: just `<message>` (ANSI preserved unless `no_colors`).
- Verbose routes: `/host/logs`, `/host/logs/boots/{bootid}`, `/supervisor/logs`,
  `/audio|dns|multicast/logs`. Plain routes: `/core/logs`, `/homeassistant/logs`,
  `/addons/{slug}/logs`, `.../identifiers/{id}`.
- Each family also has `/logs/follow`, `/logs/latest` (forces `no_colors`),
  `/logs/boots/{bootid}[/follow]`.
- Params: `?lines=N` (default 100, floor 2), `?verbose`, `?no_colors`,
  `Range: entries=<cursor>:<skip>:<count>` (journal-gatewayd syntax). `Accept`
  must be one of `text/plain`, `text/x-log`, `*/*` (else 400); `text/x-log` ⇒
  verbose. `bootid` = integer offset (`0`=current, `-1`=previous, positive from
  oldest) or a literal boot id.
- JSON side-endpoints: `GET /host/logs/boots` →
  `{"boots":{"0":<id>,"-1":<id>,…}}`; `GET /host/logs/identifiers` →
  `{"identifiers":[…]}`.
- `/supervisor/logs` degrades to `"\n".join(docker_logs)` plain text if no
  journal gateway.

**Frontend tolerance** (`frontend` `data/hassio/supervisor.ts` +
`panels/config/logs/error-log-card.ts`): sends only a `Range` header (no
`Accept`), splits the body on `\n`, renders ANSI via `ha-ansi-to-html`, and reads
`X-First-Cursor` for scroll-back — an **unchanged** `X-First-Cursor` signals
end-of-history. It expects plain UTF-8 lines; it never parses journal-export or
JSON log bodies. The boots selector appears only when `/host/logs/boots` returns
> 1 boot. Streaming requires Core ≥ 2024.11 (older Core uses the legacy
single-shot plain-text GET).

---

## A6. DNS + network wiring (resolves the long-standing `[VERIFY]`)

**`hassio` bridge** (`const.py`, `docker/network.py:181-209`): IPv4
`172.30.32.0/23`, dynamic add-on range `172.30.33.0/24`, IPv6 ULA
`fd0c:ac1e:2100::/48`. Fixed IPs: gateway `.32.1`, **supervisor `172.30.32.2`**,
**dns (CoreDNS) `172.30.32.3`**, audio `.4`, cli `.5`, observer `.6`. Add-ons get
dynamic IPs from `.33.0/24`.

**CoreDNS plugin** (`plugins/dns.py`, `docker/dns.py`): container `hassio_dns` at
`172.30.32.3` (run with `dns=False`). Serves a hosts file (each name also with a
`.local.hass.io` suffix): `172.30.32.2`→`hassio,supervisor`; gateway
`172.30.32.1`→`homeassistant,home-assistant`; `.3`→`dns`; `.6`→`observer`;
`127.0.0.1`→`localhost`. Add-on records `<slug-with-dashes>` are added/removed
dynamically on start/stop. Forwarding priority: manual `servers` → `locals`
(host/NM DNS) → fallback (CloudFlare DoT).

**How host-network Core resolves `supervisor` — THREE mechanisms, DNS is not the
primary one** (`docker/homeassistant.py:200-224`, Core is `network_mode="host"`):
1. **`/etc/hosts` via Docker `ExtraHosts` (`--add-host`) — authoritative.**
   `extra_hosts={"supervisor":172.30.32.2,"observer":172.30.32.6}` →
   `HostConfig.ExtraHosts` → written to the container's `/etc/hosts`, which is a
   per-container bind-mount independent of the network namespace, so it works in
   host mode and nsswitch consults it before DNS.
2. **`/etc/resolv.conf` via `--dns` → CoreDNS** (`Dns=["172.30.32.3"]`,
   `DnsSearch=["local.hass.io"]`, `DnsOptions=["timeout:10"]`) for add-on names,
   `homeassistant`, and upstream DNS. Docker materializes a private resolv.conf
   even for host-network containers (also a bind-mount).
3. **Raw env** `SUPERVISOR=172.30.32.2` and `HASSIO=172.30.32.2` — the client can
   use the IP directly with no lookup.

Bridged add-ons get `extra_hosts={"supervisor":172.30.32.2,"hassio":172.30.32.2}`
in `/etc/hosts` + resolv.conf → CoreDNS. Add-on hostname = `slug.replace("_","-")`.
Core reaches a bridged add-on either at `127.0.0.1:<published-port>` or by
resolving the add-on hostname via CoreDNS (Core shares the host routing table
that reaches the `hassio` bridge).

---

## A7. Consolidated gaps → must verify empirically before/while building M4

1. **Docker honoring `--dns`/`--add-host` for host-network containers** is moby
   behavior, not asserted in Supervisor source. Our substrate re-implements the
   runtime (balena-engine), so **verify on-device that a host-network container
   gets a private `/etc/hosts` + `/etc/resolv.conf`.** This is the single
   riskiest assumption for Core↔emulator naming. (A6)
2. **securetar crypto internals** (cipher, KDF, IV, `create_version` 2 vs 3 byte
   layout) — read `securetar==2026.4.1` directly before claiming encrypted-backup
   interop. First cut should emit **unprotected** backups. (A4)
3. **`FolderMapping.read_only` default** for the string map form (`map:[ssl,
   share]`) — whether Mosquitto's `/ssl`,`/share` mount ro or rw by default. (A1.4)
4. **Absolute host data-root** (`/mnt/data/supervisor` vs our `/data`) and the
   `addons/data`↔`apps/data` migration — resolve for our Nerves `/data` layout. (A1.2)
5. **bashio** endpoint/method mapping and **go-auth** `/authentication` wire
   format (form vs JSON) are inferred, not read (both un-indexed). Supervisor
   `/auth` tolerates Basic/JSON/form and reads only `username|user`+`password`,
   so exactness is low-risk, but confirm if issues arise. (A3.4)
6. **Token→app grant computation** (`services_role`, `access_auth_api`,
   `discovery` from `config.yaml`) not opened — assumed granted from config. (A3)
7. **Version pin**: everything above is dev-HEAD (`9999.09.9.dev9999`). Re-verify
   field names against the exact Supervisor release the device targets. (A0)
