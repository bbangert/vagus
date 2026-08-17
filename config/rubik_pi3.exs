import Config

# Board-specific configuration for the Thundercomm Rubik Pi 3 (QCS6490).
#
# Imported at the very bottom of config/target.exs, so anything set here
# OVERRIDES the shared target config. Keep it minimal: only settings that
# genuinely differ between boards belong here. Everything else — the
# `/data/vagus/*` paths, `:docker_socket`, `:addon_data_root`,
# `:core_container`, the store repositories — is board-agnostic and stays in
# target.exs.

# Network interfaces. No `usb0`: this board has no USB gadget controller, so
# VintageNetDirect has nothing to bind. `eth0` is a USB3-attached ASIX
# AX88179B (`ax88179_178a`, behind a UPD720201 USB3 controller); `wlan0`
# comes from the onboard AMPAK AP6256 (Broadcom BCM43456-class) over SDIO via
# mainline `brcmfmac`. `config/target.exs` deliberately sets no `:config`
# default, so this is the only source of the interface list for this board —
# and it must stay that way: `:config` is a list of `{binary, map}` tuples,
# not a keyword list, so Config's deep-merge would not apply and a shared
# default would simply be replaced wholesale.
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
# "generic-aarch64" rather than a custom "rubik-pi3" string, verified
# against real HA source: it is in Supervisor's add-on machine-validation
# regex (`supervisor/apps/validate.py`), maps to `["aarch64"]` in
# `supervisor/data/arch.json`, is in the frontend's hardware map
# (`frontend/src/data/hardware.ts`), and is HAOS's own **UEFI-capable
# aarch64** board (`operating-system/board/arm-uefi/generic-aarch64`) —
# which is exactly this board's boot model (EDK2 → GRUB arm64-efi). A custom
# string would be unknown to that regex and render as an unknown board.
config :vagus, :machine, "generic-aarch64"

# Where the operator-supplied QNN Hexagon skel is stored (`Vagus.DSP`).
#
# Board-specific rather than shared, because unset is the answer for a target
# with no Hexagon DSP: `status/0` reads `nil` as :unsupported, so rpi3_64 needs
# no separate capability check.
#
# The REAL mount path (`/root`), not the `/data` symlink — this directory is
# bound into a container as a mount source and runc rejects a symlinked path,
# the same reason `:addon_data_root` reads the way it does (target.exs:239).
config :vagus, :dsp_root, "/root/vagus/dsp"

# The Hexagon architecture of this board's DSP (`Vagus.DSP.expected_arch/0`).
#
# QCS6490 (Kodiak) is Hexagon v68. Only the admin panel reads it, and only to
# name the right one of the SDK's seven `hexagon-v*/unsigned/` directories in
# the operator instructions and to warn when the stored skel is for another
# version — a skel that does not load makes a DSP add-on fail to start rather
# than fall back to the CPU silently, so upload time is still the best place
# to catch it.
config :vagus, :dsp_arch, "V68"
