import Config

# Board-specific configuration for the Raspberry Pi 3 A+/B/B+ (64-bit).
#
# Imported at the very bottom of config/target.exs, so anything set here
# OVERRIDES the shared target config. Keep it minimal: only settings that
# genuinely differ between boards belong here. Everything else — the
# `/data/vagus/*` paths, `:docker_socket`, `:addon_data_root`,
# `:core_container`, the store repositories — is board-agnostic and stays in
# target.exs.

# Network interfaces. `usb0` is the USB gadget (VintageNetDirect) the Pi
# exposes over its OTG port — the Q6A has no gadget controller, which is why
# this list is per-board rather than shared. Note vintage_net's `:config` is
# a list of `{binary, map}` tuples, not a keyword list, so this REPLACES the
# shared value rather than merging into it.
config :vintage_net,
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

# The board identity reported to Home Assistant Core (`GET info`,
# `GET core/info` — see `Vagus.API.StaticData`). "raspberrypi3-64" is a real
# HAOS machine, known to Supervisor's add-on machine-validation regex and to
# the frontend's hardware map.
config :vagus, :machine, "raspberrypi3-64"
