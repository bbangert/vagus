# Build targets

Vagus builds for three Nerves targets. **All three are first-class** —
`dragon_q6a` and `rubik_pi3` were added alongside `rpi3_64`, not as
replacements for it.

| Target | Board | Kernel | Boot chain | `machine` reported to Core |
| --- | --- | --- | --- | --- |
| `rpi3_64` | Raspberry Pi 3 A+/B/B+ (64-bit) | 6.18 | bootcode → `config.txt` → A/B | `raspberrypi3-64` |
| `dragon_q6a` | Radxa Dragon Q6A (QCS6490) | 7.1.4 | EDK2 UEFI → GRUB arm64-efi → A/B | `generic-aarch64` |
| `rubik_pi3` | Thundercomm Rubik Pi 3 (QCS6490) | 7.1 (mainline) | PBL → XBL (SPI NOR) → EDK2 UEFI → GRUB (ESP on UFS) → kernel | `generic-aarch64` |

All three are aarch64 on the same toolchain, so `arch` is `aarch64`
everywhere and Core runs the generic `ghcr.io/home-assistant/home-assistant`
image on all of them (no per-machine image).

## Building

```sh
mise run firmware -- rpi3_64        # or: dragon_q6a, rubik_pi3
mise run mix-for -- dragon_q6a deps.get
mise run test                       # host tests
```

> **Prefer the `mise run` tasks — they set `MIX_TARGET` *inside* the task, so
> they always win.** An explicit `MIX_TARGET=… mix …` prefix is reliable only
> once the environment is activated (`eval "$(mise env)"`); invoked through
> mise's bare shims it can be re-injected from `.mise.toml` and silently build
> the default target instead of the one you asked for. When in doubt use
> `mise run`, or `mise exec`. `.mise.toml`'s `MIX_TARGET` is the default for
> everything else.

Nerves firmware assembly runs from the Nerves app, not the umbrella root, so
it needs the `mix-for` task (or an activated shell) rather than a bare prefix:

```sh
cd apps/vagus_platform
MIX_TARGET=dragon_q6a mix firmware       # after: eval "$(mise env)"
MIX_TARGET=dragon_q6a mix upload <device-ip>
```

The Nerves *system* build alone produces `rootfs.squashfs`, `Image` and
`fwup.conf` — but **no `.fw` bundle**. That comes from `mix firmware` here,
which is why a new board must be wired into `@all_targets` before it can be
flashed at all.

## How a target is wired

Adding a board touches four places:

1. **`@all_targets`** in both `apps/vagus/mix.exs` and
   `apps/vagus_platform/mix.exs` — this gates `nerves_pack`/`vintage_net`.
2. **A system path dep** in `apps/vagus_platform/mix.exs`, scoped by
   `targets:`. Path deps never enter `mix.lock`, so multiple system entries
   cannot conflict; only the selected board's system is fetched and compiled.
3. **`config/<target>.exs`** — imported at the *bottom* of
   `config/target.exs`, so it **overrides** the shared config. A missing file
   for a selected target is a hard failure at config load.
4. **The Nerves system itself**, in the sibling `nerves_system_vagus` repo.

Keep the per-target files minimal. Only genuinely board-specific settings
belong there — currently the vintage_net interface list and `:machine`.
Everything else (`/data/vagus/*` paths, `:docker_socket`, `:addon_data_root`,
`:core_container`, the store repositories) is board-agnostic and stays in
`config/target.exs`.

> **Non-obvious:** vintage_net's `:config` is a list of `{binary, map}`
> tuples, **not** a keyword list, so Elixir's Config deep-merge does not
> apply — a per-target value *replaces* the shared list wholesale. Each board
> must therefore enumerate every interface it wants. `config/target.exs`
> deliberately sets no `:config` default at all.

### Interfaces per board

| Board | Interfaces |
| --- | --- |
| `rpi3_64` | `usb0` (VintageNetDirect, USB gadget), `eth0`, `wlan0` |
| `dragon_q6a` | `eth0` (RTL8125 2.5 GbE), `wlan0` (onboard AIC8800D80) — **no `usb0`**, the board has no USB gadget controller |
| `rubik_pi3` | `eth0` (USB3-attached ASIX AX88179B, `ax88179_178a`, behind a UPD720201 USB3 controller), `wlan0` (AMPAK AP6256/BCM43456-class SDIO, `brcmfmac`) — **no `usb0`**, the board has no USB gadget controller |

### Why `generic-aarch64` for the Q6A and the Rubik Pi 3

It is a real Home Assistant machine, not an invented string — verified
against HA source rather than assumed:

- it is in Supervisor's add-on machine-validation regex (`supervisor/apps/validate.py`)
- it maps to `["aarch64"]` in `supervisor/data/arch.json`
- it is in the frontend's hardware map (`frontend/src/data/hardware.ts`)
- it is HAOS's own **UEFI-capable aarch64** board
  (`operating-system/board/arm-uefi/generic-aarch64`) — exactly this board's
  boot model

A custom `dragon-q6a` string would be unknown to that regex and would render
as an unknown board. `machine` is read at runtime from
`config :vagus, :machine`, so each target (and `:host`/`:test`) sets it
independently; `Vagus.API.StaticData` reads it with `fetch_env!/2` and
**raises** if it is missing, so a new board that forgets to set it fails
loudly instead of silently claiming to be a Raspberry Pi.

`rubik_pi3` reuses the same `"generic-aarch64"` string and the same
rationale — it boots through the same EDK2 UEFI → GRUB arm64-efi chain, just
with XBL in SPI NOR ahead of EDK2 and the ESP living on UFS rather than
eMMC/NVMe.

## dragon_q6a: what is device-proven

Full parity gate, 2026-07-27, on firmware built from merged `main`:

| Capability | Status |
| --- | --- |
| Container engine (balenaEngine v25) | daemon self-starts, builds `hassio`/`bridge` networks, programs NAT |
| HA Core cold start | 2.33 GB image pull → container running → `:healthy` on `:8123` |
| hassio integration | all 20 coordinator endpoints 200; Core mints a `hassio_user`; `hassio: Supervisor` config entry `loaded` |
| DNS | `Vagus.DNS` on `172.30.32.3:53`, resolves external and hassio-internal names |
| Native MQTT (`core_mqtt`) | discovery → Core config entry "MQTT Broker (native)"; session stable over a 6+ minute soak with zero reconnects |
| Container add-on + ingress | `core_configurator` installed, healthy on the bridge, ingress serves real content |
| A/B OTA with containers running | both containers auto-restart on the new slot |
| Core watchdog | hung-Core probe restart and engine-absorbed crash both behave per the ladder |
| Unclean power cycle | ext4 journal recovers, anchors re-bind, containers restart, Core healthy, ingress still serves |
| Pre-existing board capabilities | fastrpc 3/3, Venus `/dev/video0`+`1`, USB3 root hub @ 5000 Mbps, `wlan0` + `hci0` |

### Q6A caveat: an OTA cannot change the kernel cmdline

`fwup.conf` writes `grub.cfg` to the ESP only in its `complete` task (a full
EDL flash). `upgrade.a`/`upgrade.b` carry the rootfs slot and `grubenv`
alone. A device that OTAs into a new version therefore keeps its previous
kernel cmdline — plan a full reflash for any future cmdline change on this
board.

### Ingress and the supervisor anchor

Add-ons that filter on client IP expect ingress traffic to arrive from the
supervisor anchor `172.30.32.2`. In HAOS that is free — the Supervisor is a
container that genuinely holds `.2`. Vagus runs on the **host**, so without an
explicit source bind its connections take the bridge's primary address
(`172.30.32.1`, the gateway) and such add-ons reject them outright.

`config :vagus, :ingress_source_ip` therefore sets the source address both
ingress legs bind to — the plain-HTTP pool and the WebSocket bridge — via
`Vagus.Network.source_bind_opts/0`. It is **target-only**: on `:host`/`:test`
no `.2` is bound and binding would fail `:eaddrnotavail`, so those configs
leave it unset and the helper returns `[]`. An unset or invalid value degrades
to "no source bind" with a warning rather than raising, so a config typo
cannot take ingress down.

This bites any host-run Supervisor emulator, not just this board — it was
found on the Q6A but rpi3_64 had the identical latent gap.

## rubik_pi3: what is pending

App wiring only, so far — device bring-up (Phase 3) has not run yet, and
nothing below is device-proven.

### Storage

The onboard 128 GB UFS (4096-byte logical block size, dual LUN) is the boot
and data disk, matching rpi3_64's and dragon_q6a's single-disk model. The
M.2 NVMe slot is enabled and has been verified mountable, but it is not part
of the storage layout.

### Boot chain and flashing

PBL → XBL (SPI NOR) → EDK2 UEFI → GRUB (ESP on UFS) → kernel. The
bootloader lives in SPI NOR and is never reflashed by Vagus; flashing goes
through Qualcomm EDL/QDL (`prog_firehose_ddr.elf` plus the rawprogram/patch
XMLs from Thundercomm) writing the UFS LUN0 image. See
`nerves_system_vagus/rubik_pi3/README.md` for the flashing playbook.

### Kernel and console

Mainline 7.1 kernel with the in-tree `qcom/qcs6490-thundercomm-rubikpi3.dtb`.
Serial console is `ttyMSM0` at 115200.

### Bluetooth

`hci_bcm` over `uart7`, patched with the `BCM4345C5.hcd` firmware blob —
the same AP6256 module that provides `wlan0`.
