import Config

# Board-specific configuration for the Radxa ROCK 4D (Rockchip RK3576).
#
# Imported at the very bottom of config/target.exs, so anything set here
# OVERRIDES the shared target config. Keep it minimal: only settings that
# genuinely differ between boards belong here. Everything else — the
# `/data/vagus/*` paths, `:runtime_host`, `:addon_data_root`,
# `:core_container`, the store repositories — is board-agnostic and stays in
# target.exs.

# Network interfaces. No `usb0`: both dwc3 controllers are host-only in this
# board's device tree, so VintageNetDirect has nothing to bind. `eth0` is the
# gmac0 + RTL8211F GbE; `wlan0` comes from the onboard AIC8800D80 (USB).
# `config/target.exs` deliberately sets no `:config` default, so this is the
# only source of the interface list for this board — and it must stay that
# way: `:config` is a list of `{binary, map}` tuples, not a keyword list, so
# Config's deep-merge would not apply and a shared default would simply be
# replaced wholesale.
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
# "generic-aarch64", as on the Qualcomm boards: HAOS has no RK3576 board, and
# this is the aarch64 machine Supervisor's add-on machine-validation regex
# (`supervisor/apps/validate.py`) and the frontend's hardware map know, mapped
# to `["aarch64"]` in `supervisor/data/arch.json`. A custom string would be
# unknown to that regex and render as an unknown board. No `:dsp_root` or
# `:dsp_arch`: the RK3576's NPU is not a Hexagon DSP, so `Vagus.DSP` reads
# this board as :unsupported.
config :vagus, :machine, "generic-aarch64"
