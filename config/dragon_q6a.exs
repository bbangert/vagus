import Config

# Board-specific configuration for the Radxa Dragon Q6A (QCS6490).
#
# Imported at the very bottom of config/target.exs, so anything set here
# OVERRIDES the shared target config. Keep it minimal: only settings that
# genuinely differ between boards belong here. Everything else — the
# `/data/vagus/*` paths, `:docker_socket`, `:addon_data_root`,
# `:core_container`, the store repositories — is board-agnostic and stays in
# target.exs.

# Network interfaces. No `usb0`: this board has no USB gadget controller, so
# VintageNetDirect has nothing to bind. `eth0` is the RTL8125 2.5 GbE
# (r8169); `wlan0` comes from the onboard AIC8800D80. Note vintage_net's
# `:config` is a list of `{binary, map}` tuples, not a keyword list, so this
# REPLACES the shared value rather than merging into it.
config :vintage_net,
  config: [
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

# The board identity reported to Home Assistant Core (`GET info`,
# `GET core/info` — see `Vagus.API.StaticData`).
#
# "generic-aarch64" rather than a custom "dragon-q6a" string, verified
# against real HA source: it is in Supervisor's add-on machine-validation
# regex (`supervisor/apps/validate.py`), maps to `["aarch64"]` in
# `supervisor/data/arch.json`, is in the frontend's hardware map
# (`frontend/src/data/hardware.ts`), and is HAOS's own **UEFI-capable
# aarch64** board (`operating-system/board/arm-uefi/generic-aarch64`) —
# which is exactly this board's boot model (EDK2 → GRUB arm64-efi). A custom
# string would be unknown to that regex and render as an unknown board.
config :vagus, :machine, "generic-aarch64"
