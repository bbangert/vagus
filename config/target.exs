import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
#
# `PLUG_TMPDIR` moves `Plug.Upload`'s spool off `/tmp` onto the ext4 data
# partition. `/tmp` here is a tmpfs sized at 10% of RAM (**96MB** on the
# rpi3, measured 2026-07-30), so a backup upload spooling there is bounded by
# RAM, not disk — `POST /backups/new/upload` died around 96MB and the
# route's own multipart limit was meaningless. It must be set as an OS env
# var at boot rather than from `Vagus.Application`: `Plug.Upload.Supervisor`
# reads these vars in `init/1` when the `:plug` application starts, which
# precedes ours. `env:` is a `:keep` switch in `Nerves.Erlinit`, so this
# ADDS a line — the system's own `--env` entries (`LANG`, `ERL_INETRC`,
# `ERL_CRASH_DUMP`) are preserved. `/root` is where erlinit mounts the
# writable partition (`/data` is a symlink to it), and `Plug.Upload`
# `mkdir_p`s the subdirectory itself.
config :nerves, :erlinit, update_clock: true, env: "PLUG_TMPDIR=/root/tmp"

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

# Sourced from the NERVES_AUTHORIZED_KEYS env var (newline-separated
# authorized_keys lines) when set — CI release builds have no ~/.ssh, so
# release.yml injects the operator's public keys from a repo Actions
# variable; the keys baked into a CI build MUST match the local-build
# keys or an OTA would strip SSH access to the fleet. Local builds keep
# the conventional ~/.ssh glob.
authorized_keys =
  case System.get_env("NERVES_AUTHORIZED_KEYS") do
    nil ->
      System.user_home!()
      |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)

    env_keys ->
      String.split(env_keys, "\n", trim: true)
  end

if authorized_keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh and NERVES_AUTHORIZED_KEYS is unset
    or empty. An ssh authorized key is needed to log into the Nerves device
    and update firmware on it using ssh.
    See your project's config/target.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: authorized_keys

# `ssh_subsystem_fwup`'s DEFAULT success_callback is
# `{Nerves.Runtime, :reboot, []}`, so every OTA `mix upload` reboot would
# bypass the graceful-stop facade and keep corrupting Core's .storage (issue
# #39). Verified mechanism: `SSHSubsystemFwup.init/1` merges
# `Application.get_all_env(:ssh_subsystem_fwup)` over its defaults
# (deps/ssh_subsystem_fwup/lib/ssh_subsystem_fwup.ex init/1), and
# nerves_ssh's default subsystem spec only carries `devpath`, so this
# app-env key reaches the subsystem on target.
config :ssh_subsystem_fwup, success_callback: {Vagus.Host.Shutdown, :ota_reboot, []}

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
#
# Only `regulatory_domain` is shared. The interface list is board-specific
# (the Q6A has no USB gadget controller, so no `usb0`) and is set ONLY in
# `config/<target>.exs`, imported at the bottom of this file — there is
# deliberately no shared `:config` default here.
#
# If you ever add one, note that `:config` is a list of `{binary, map}`
# tuples, not a keyword list, so Elixir's Config deep-merge would not apply:
# the per-target value would replace it wholesale rather than merging. Each
# board listing every interface it wants is the intended design either way.
config :vintage_net, regulatory_domain: "00"

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    }

    # No `epmd` entry: `Vagus.Dist` advertises nothing. The node name, cookie
    # and port range come back from `enable/0`, over the SSH session that
    # called it.
  ]

# Supervisor-API emulator (P2-T1/T2). Core's SUPERVISOR env var carries
# host:port verbatim (docs/contract-2026.7.md §1) and real Supervisor
# installs bind port 80 — but Core 2026.8 wildcard-binds :80 itself on a
# supervised install, and two sockets cannot share it. So the listener
# moves to the hassio bridge anchor on an internal port, and port 80 on
# that address is served by `Vagus.Network.Nat`'s DNAT instead, keeping
# `http://supervisor/` (port 80 hardwired in the add-on contract) intact.
#
# :api_bind_ip is what actually frees the port: without it Bandit binds the
# wildcard, and a wildcard :8888 would leave Core's :80 free but re-expose
# the API on the LAN. The address only exists once the hassio bridge is up
# — see `Vagus.API.Listener` for the retry that covers the boot race.
config :vagus, :api_port, 8888
config :vagus, :api_bind_ip, "172.30.32.2"

# DNAT management for the port-80 add-on contract above
# (`Vagus.Network.Nat`). Target-only: :host/:test have neither a
# 172.30.32.2 nor an `iptables-legacy`.
config :vagus, :supervisor_nat, true
config :vagus, :token_path, "/data/vagus/token"

# Add-on state persistence + boot reconciliation (M4-P8-T1). `/data` is a
# symlink to `/root` — fine for plain `File.read!/write!/rename` IO like
# this, same as `:token_path` above; only a runc container *rootfs* path
# (see `:addon_data_root` below) needs the real, non-symlinked `/root/...`
# form.
config :vagus, :addon_state_path, "/data/vagus/addons.json"
config :vagus, :addon_boot_start, true

# Boot-time Core adoption (CL-P1-T2) — see config/host.exs's :core_versions_path
# comment for why these config-gated boot-reconciliation modules stay off on
# :host/:test; only target enables the poll-then-adopt GenServer.
config :vagus, :core_boot, true

# Core watchdog pair (CW-P2-T2): API probe + crash-loop event half
# (`Vagus.Core.Watchdog.Supervisor` returns :ignore when unset — same
# target-only convention as :core_boot above; there is no real Core
# container to watch on :host/:test). Runtime on/off lives separately in
# the persisted TokenStore `watchdog` option (POST /core/options).
config :vagus, :core_watchdog, true

# First-boot provisioning (issue #40): auto-expand /data + auto-install/
# start HA Core — see `Vagus.Provisioner` for the 4Kn/ordering rationale.
# Same target-only `:ignore` convention as :core_boot/:core_watchdog above.
config :vagus, :first_boot_provision, true

# Real /os/update (build-order #4): GitHub-releases OTA firmware updates
# (`Vagus.OS.Updater` — :ignore when unset, same target-only convention
# as :core_boot/:core_watchdog/:first_boot_provision above; there is no
# firmware to update on :host/:test).
config :vagus, :os_updater, true

# Core-facing token handshake (P3-T1/T2) — see config/host.exs for the
# rationale, identical on target.
config :vagus, :core_token_path, "/data/vagus/core_token.json"

# On-device, every 2026.8+ Core is reached over the unix socket
# (`Vagus.Core.Transport`, socket-first), regardless of which TCP port it
# bound — so this URL never carries traffic to a port-80 Core. It only
# matters as a fallback to pre-2026.8 Cores, which predate
# `SUPERVISOR_DEFAULT_PORT` and always bind 8123 — hence the fixed port.
config :vagus, :core_base_url, "http://localhost:8123"

# Installed/latest HA Core version state (CL-P2-T1) — see config/host.exs
# for the rationale, identical on target.
config :vagus, :core_versions_path, "/data/vagus/core.json"

# Persisted POST supervisor/options fields (audit E5) — see config/host.exs
# for the rationale, identical on target.
config :vagus, :supervisor_options_path, "/data/vagus/supervisor_options.json"

# Device-managed SSH access keypair (`Vagus.SSHAccess`). A DETS file, not
# JSON, but the same `/data` writable-path convention as the keys above;
# the private key is stored unencrypted, so the file is held at mode 0600
# and no key is generated until that is proven.
config :vagus, :ssh_access_path, "/data/ssh_access.dets"

# One-shot marker for `Vagus.Core.PortMigration` (core-socket-port80 Phase
# B): the rewrite of the 8123 Core persisted for itself in
# `<config>/.storage/http` back when the Supervisor API still held port 80.
# Target-only on purpose — an unset key disables the module outright, which
# is exactly right for host dev and the test suite, where the engine volume
# this reads through does not exist. Same `/data` writable-path convention as
# the keys above; the file's existence is the whole signal, its one line of
# content is for device forensics only.
config :vagus, :core_port_migration_marker, "/data/vagus/core_port_migration"

# Persisted runtime-added store repositories (issue #5 / D4). Same
# file-backed-JSON pattern as :supervisor_options_path above — a JSON list
# of the source strings a user posted to `POST /store/repositories`, layered
# after the config-declared :store_repositories on boot.
config :vagus, :store_repositories_path, "/data/vagus/store_repositories.json"

# Add-on runtime (M4). The balena-engine daemon's control socket
# (`Vagus.Engine.Manager`'s `--host`); `Vagus.Runtime.Docker` talks to it.
config :vagus, :docker_socket, "/run/balena-engine.sock"

# The HA Core container's name on the engine — the source behind the
# /core (and /homeassistant alias) logs + stats routes. Was never set
# before vagus-follow-logs, which made every /core/logs response an
# "honest empty" (found during the P4-T2 device gate); matches the
# canonical run recipe in memory (vagus-device-and-toolchain).
config :vagus, :core_container, "homeassistant"

# Add-on data/bind-source root. Use the REAL mount path (`/root`), not the
# `/data` symlink — the same runc symlink hazard that blocked the engine
# data-root (see Vagus.Engine.Manager) applies to bind sources.
config :vagus, :addon_data_root, "/root/vagus/addons"

# Ingress source address (found during the Q6A phase-4 gate, 2026-07-27).
# Vagus runs on the host, so without this its connections to add-ons take
# the hassio bridge's primary address (172.30.32.1, the gateway). In HAOS
# the Supervisor is a container holding .2, and add-ons that filter on
# client IP expect to see .2 — `core_configurator` rejected ingress with
# `Client IP not within allowed networks` / 420 and banned .1, which Core
# reported as a 502. Target-only: on :host/:test no .2 is bound and the
# bind would fail :eaddrnotavail, so those configs leave this unset.
config :vagus, :ingress_source_ip, "172.30.32.2"

# Restrict who may talk to the Supervisor API (`Vagus.API.SourceGuard`).
# Defence in depth behind the :api_bind_ip isolation above, not the primary
# control: 172.30.32.2 is bound in the host netns, so packets to it are
# delivered locally and any LAN host that routes 172.30.32.0/23 via the board
# still reaches the listener and the DNAT'd :80 — and an unparseable
# :api_bind_ip degrades to the wildcard by design. Target-only: on :host/:test
# everything arrives from 127.0.0.1 and the guard would be a no-op anyway.
config :vagus, :api_source_guard, true

# Fill the add-on store's catalog once after boot
# (`Vagus.Addon.Store.Refresher`). Without it the catalog stays empty until
# something calls `POST /store/reload`, so every reboot leaves a blank
# add-on store and no icons. Target-only: :host/:test must not reach out to
# github during a test run.
config :vagus, :store_boot_refresh, true

# Add-on DNS (M4-P1-T2). `Vagus.DNS` binds the hassio `dns` anchor
# (172.30.32.3:53) and forwards names it doesn't own to this upstream
# (`locals`); 1.1.1.1 keeps it a complete resolver for a host-networked Core
# pointed at .3 with `--dns` and for add-ons resolving external hosts.
config :vagus, :dns_upstream, "1.1.1.1"

# Add-on store repositories (M4-P2-T3). The official "core" add-ons repo;
# `POST /store/reload` fetches + parses these into the catalog. `core` gives
# the store-slug prefix (core_mosquitto), matching the Supervisor.
#
# The `%{builtin: :mqtt}` entry (M5-P5) injects Vagus's native mqttx broker into
# the catalog as `core_mqtt` — the default MQTT provider. `:store_fetcher`
# selects `BuiltinFetcher`, which serves builtin repos from an embedded config
# and delegates the git-backed ones to the HTTP fetcher. The containerized
# Mosquitto (`core_mosquitto`, from the official repo) stays in the catalog as a
# reference but is never auto-installed (only `core_mqtt` is — see
# `:default_native_addon`); both can't own `:1883`/the mqtt service at once.
config :vagus, :store_fetcher, Vagus.Addon.Store.BuiltinFetcher

# The default set mirrors upstream's `BuiltinRepository`
# (`supervisor/store/const.py`) minus `local`, which needs a user-writable
# add-on directory Vagus doesn't have yet. Note the two `core` entries are one
# repository as far as the wire is concerned — the built-in mqtt source rides
# the core slug so its catalog key is `core_mqtt` — and `Store.repositories/1`
# collapses them into a single wire entry. Adding a source under a *new* slug
# is cheap; changing an existing slug is not, because installed add-ons are
# keyed by `<repo_slug>_<addon_slug>`.
config :vagus, :store_repositories, [
  %{slug: "core", builtin: :mqtt},
  %{slug: "core", url: "https://github.com/home-assistant/addons", ref: "master"},
  %{slug: "community", url: "https://github.com/hassio-addons/repository", ref: "master"},
  %{slug: "esphome", url: "https://github.com/esphome/home-assistant-addon", ref: "main"},
  %{
    slug: "music_assistant",
    url: "https://github.com/music-assistant/home-assistant-addon",
    ref: "main"
  }
]

# Make the native mqttx broker the default MQTT provider (M5-P5):
# `Vagus.Addon.DefaultProvider` auto-installs + boots this store slug on startup,
# independent of the container engine.
config :vagus, :default_native_addon, "core_mqtt"

# NOTE: the Supervisor↔Core unix socket needs no config here. Its path is
# `Vagus.Core.Container.socket_path/0` (`/run/supervisor/core.sock`, the
# value of Core's own `SUPERVISOR_CORE_API_SOCKET` env and one half of its
# bind mount), which `Vagus.Core.Transport` resolves by default on every
# target. The old `:core_api_socket` key pointed at `/run/vagus-core/core.sock`
# — a directory nothing ever created or mounted, so it never worked on a
# device and every caller silently used its TCP fallback.

# Host-management backends (P4-T1) — the real vintage_net/Nerves.Runtime-
# backed implementations. See config/host.exs for the :host-side stubs and
# config/test.exs for the Mox mocks.
config :vagus, :backends, %{
  network: Vagus.Backend.Network.VintageNet,
  host: Vagus.Backend.Host.Nerves,
  os: Vagus.Backend.OS.Nerves
}

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
#
# One file per entry in `@all_targets` (apps/vagus/mix.exs,
# apps/vagus_platform/mix.exs) — currently config/rpi3_64.exs and
# config/dragon_q6a.exs. A missing file for a selected target is a hard
# failure at config load, so adding a board means adding its file here too.
import_config "#{Mix.target()}.exs"
