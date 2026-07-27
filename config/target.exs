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
config :nerves, :erlinit, update_clock: true

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

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
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Supervisor-API emulator (P2-T1/T2). Core's SUPERVISOR env var carries
# host:port verbatim (docs/contract-2026.7.md §1) — real Supervisor
# installs bind port 80.
config :vagus, :api_port, 80
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

# Core-facing token handshake (P3-T1/T2) — see config/host.exs for the
# rationale, identical on target.
config :vagus, :core_token_path, "/data/vagus/core_token.json"
config :vagus, :core_base_url, "http://localhost:8123"

# Installed/latest HA Core version state (CL-P2-T1) — see config/host.exs
# for the rationale, identical on target.
config :vagus, :core_versions_path, "/data/vagus/core.json"

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

config :vagus, :store_repositories, [
  %{slug: "core", builtin: :mqtt},
  %{slug: "core", url: "https://github.com/home-assistant/addons", ref: "master"},
  %{slug: "esphome", url: "https://github.com/esphome/home-assistant-addon", ref: "main"}
]

# Make the native mqttx broker the default MQTT provider (M5-P5):
# `Vagus.Addon.DefaultProvider` auto-installs + boots this store slug on startup,
# independent of the container engine.
config :vagus, :default_native_addon, "core_mqtt"

# Core's Supervisor unix socket (M4 /auth). Core is run with
# SUPERVISOR_CORE_API_SOCKET=<this path> and its dir bind-mounted to the host;
# `Vagus.Auth` reaches api/hassio_auth over it, authenticating as the
# Supervisor user and bypassing Core's caller-IP check (which the host-net
# emulator can't satisfy over TCP).
config :vagus, :core_api_socket, "/run/vagus-core/core.sock"

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
