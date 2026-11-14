import Config

# Board-specific configuration for the Home Assistant Green (Rockchip RK3566).
#
# Imported at the very bottom of config/target.exs, so anything set here
# OVERRIDES the shared target config. Keep it minimal: only settings that
# genuinely differ between boards belong here.

# Ethernet only. The board has no radio, so no `wlan0`, and its USB ports are
# host-only, so no `usb0` gadget. `config/target.exs` deliberately sets no
# `:config` default: it is a list of `{binary, map}` tuples, which Config's
# deep-merge would replace wholesale rather than merge.
config :vintage_net,
  config: [
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }}
  ]

# Reported to Core as the machine, and what an app's `machine:` allow-list is
# matched against. HAOS names this board `green`, and Supervisor's machine
# regex and `arch.json` know it. It is deliberately NOT the `/os/info` board:
# that comes from the firmware's platform (`ha_green`), because Core maps board
# `green` to its `homeassistant_green` integration, which calls
# `/os/boards/green`, an endpoint Vagus does not serve. No `:dsp_root`: the
# NPU is not a Hexagon DSP, so `Vagus.DSP` reads this board as :unsupported.
config :vagus, :machine, "green"
