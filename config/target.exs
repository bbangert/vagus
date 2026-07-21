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
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

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

# Core-facing token handshake (P3-T1/T2) — see config/host.exs for the
# rationale, identical on target.
config :vagus, :core_token_path, "/data/vagus/core_token.json"
config :vagus, :core_base_url, "http://localhost:8123"

# Add-on runtime (M4). The balena-engine daemon's control socket
# (`Vagus.Engine.Manager`'s `--host`); `Vagus.Runtime.Docker` talks to it.
config :vagus, :docker_socket, "/run/balena-engine.sock"

# Add-on data/bind-source root. Use the REAL mount path (`/root`), not the
# `/data` symlink — the same runc symlink hazard that blocked the engine
# data-root (see Vagus.Engine.Manager) applies to bind sources.
config :vagus, :addon_data_root, "/root/vagus/addons"

# Add-on DNS (M4-P1-T2). `Vagus.DNS` binds the hassio `dns` anchor
# (172.30.32.3:53) and forwards names it doesn't own to this upstream
# (`locals`); 1.1.1.1 keeps it a complete resolver for a host-networked Core
# pointed at .3 with `--dns` and for add-ons resolving external hosts.
config :vagus, :dns_upstream, "1.1.1.1"

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
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
