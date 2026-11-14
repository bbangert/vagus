# Home Assistant Green (`ha_green`)

Rockchip RK3566 (4x Cortex-A55, Mali-G52, 0.8 TOPS NPU), 4 GB RAM, 32 GB
eMMC, Ethernet. The system is `ha_green` in
[nerves_system_vagus](https://github.com/bbangert/nerves_system_vagus/tree/main/ha_green);
its README and `base/README.md` hold the hardware record, and what that record
does not cover is untested here too.

What Vagus does differently on this board:

- `eth0` DHCP only. There is no `wlan0` (no WiFi) and no `usb0` (the USB ports
  are host-only).
- `machine` is `green`, so an app that allow-lists `machine: [green]` can be
  installed, and one that lists only other machines (`generic-aarch64`, say) is
  unavailable here. `["!green"]` alone is unavailable too: upstream reads a list
  with only negations as matching nothing.
- `/os/info` reports the firmware platform `ha_green` as the board, not
  `green`. Core maps board `green` to its `homeassistant_green` integration,
  which calls `/os/boards/green` (the LED and board settings), and Vagus does
  not serve that.
- RAM is about 3.58 GiB, so the runtime should take the `fast` profile, and the
  root disk is `mmcblk0`, so swap should be zram (both follow from the code and
  have not been checked on the board). Nothing here depends on an SD card; one,
  when present, is `mmcblk1`.

## Installing and recovering

Install is an SD-booted Vagus image plus one command on the board, and
recovery needs no serial console. The stock first-stage loader stays untouched,
and Vagus never writes the SPI NOR or eMMC LBA 64-16383. Follow the
[install guide](https://github.com/bbangert/nerves_system_vagus/blob/v0.10.0/docs/ha-green-install.md)
in the system repository, which covers installing, returning to Home Assistant
OS and what is never written.

## No radio

The Green has no WiFi or Bluetooth. The firmware carries no BlueZ or D-Bus, so
`Vagus.Bluetooth` and the Improv provisioning it hosts do not start (one
warning at boot says why), and the WiFi endpoints have no interface to act on.
USB WiFi or Bluetooth dongles are not supported.

With no system bus, Core's container gets no host D-Bus mount, and an app with
`host_dbus: true` is refused at start (see
[the divergences entry](divergences.md#core-gets-no-rundbus-bind-on-a-firmware-without-d-bus)).
Nobody has run Core on this board yet, so what it does without a bus is not
established; expect its Bluetooth integrations to find no adapter. Vagus
does not serve Core's LED and board settings here either (no
`/os/boards/green`), so expect them to be absent.

## What an app can be given

The nodes below are owned by root, and the system ships no rules opening them
to other users or groups, so an app must run as root to use them. List the
ones an app needs under `devices:`.

| Node | What |
| --- | --- |
| `/dev/dri/card0`, `/dev/dri/renderD128` | Display controller |
| `/dev/dri/card1`, `/dev/dri/renderD129` | NPU (there is no `/dev/rknpu`) |
| `/dev/mali0` | GPU (vendor `kbase` driver) |
| `/dev/mpp_service` | Video codecs (Rockchip MPP) |
| `/dev/rga` | 2D scaler |
| `/dev/dma_heap/system`, `/dev/dma_heap/system-uncached`, `/dev/dma_heap/reserved` | DMA heaps |
| `/dev/rk_dma_heap/rk-dma-heap-cma` | Rockchip CMA heap |

The numbering is the same with no monitor attached; only `/dev/fb0` is absent.

The kernel provides drivers and device nodes only. The userspace pieces
(`librknnrt`, the Mali userspace driver, MPP and RGA libraries) must be in the
app's image. As of the system's README, no inference job, GPU context, video
encode or decode, or RGA job has been run on the board: the nodes exist and the
drivers probe, and nothing more is claimed.

### `devicetree: true`

Software that detects the SoC through `/proc/device-tree` (Rockchip's MPP reads
`compatible` there) needs `devicetree: true` in the app's config. Without it the
path does not resolve in the container. Vagus does slightly more than upstream
to make it work; see
[the divergences entry](divergences.md#devicetree-true-also-exposes-sysfirmwaredevicetree).

### Mali userspace must match the kernel

The kernel's Mali `kbase` interface is version g29p1. The `libmali` inside an app
image has to match it. A kernel update that moves the version is therefore a
breaking change for every app that ships a GPU userspace, and the release notes
must say so.

### RGA and memory

The RGA2 core has no IOMMU and reaches only the first 4 GiB of RAM. To keep
every buffer addressable the system keeps usable RAM below 4 GiB physical, which
costs 256 MiB: about 3.58 GiB of the 4 GB is usable. No scaling job has been run
yet, so RGA scaling is unproven.
