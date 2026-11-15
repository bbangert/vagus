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
[install guide](https://github.com/bbangert/nerves_system_vagus/blob/v0.10.2/docs/ha-green-install.md)
in the system repository, which covers installing, returning to Home Assistant
OS and what is never written.

## No onboard radio

The Green has no WiFi or Bluetooth hardware, so the WiFi endpoints have no
interface to act on. D-Bus and BlueZ ship in the firmware, so apps that need the
host bus (Matter Server) work and a USB Bluetooth dongle can be used. No dongle
has been tested on this board. The firmware carries Realtek, Intel, MediaTek and
Qualcomm 6174A dongle firmware; Atheros AR3012 and Broadcom `.hcd`-firmware
dongles are not covered. USB WiFi dongles are not supported.

Vagus does not serve Core's LED and board settings here (no
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
app's image.

Every accelerator below was exercised from inside an app container, with the
public [`rockchip_probe`](https://github.com/bbangert/ha-bench-addons/tree/main/rockchip_probe)
bench app installed from the app store, on a board running kernel 6.1.172 with
HDMI unplugged. The sizes were 720p and 1080p test inputs; these are capability
results, not general performance claims.

| Accelerator | Measured from an app |
| --- | --- |
| NPU | RKNPU driver 0.9.8 with `librknnrt` / `rknn-toolkit-lite2` 2.3.2. Rockchip's resnet18 example returns the reference top-5, about 70 inferences per second in a loop. `/proc/rknpu/load` is readable in the container. A separate bench with INT8 640x640 detection models through the Python lite API (inference call only, no post-processing) took about 59 ms (YOLOv8n), 105 ms (YOLOv8s), 85 ms (YOLO11n) and 140 ms (YOLO11s) |
| GPU | Mali-G52, kernel driver and userspace library both g29p1. OpenGL ES 3.2 works through the GBM platform on `/dev/dri/card0` with no display connected: complete FBO, exact pixel read-back |
| Video (MPP 1.1.0) | Hardware H.264 decode (`h264d_vdpu34x`) and H.265 decode (`h265d_vdpu34x`) of 720p clips, all frames; hardware H.264 encode (`hal_h264e_vepu541`). CMA free memory did not move during 720p decode and encode |
| RGA (RGA2, librga 1.10.5) | With dma-buf buffers: copy, resize, NV12 to RGB888 (BT.601 limited and full), crop, rotate, flip and fill all match a CPU reference. 1080p NV12 to 640x640 RGB888 with padding takes about 5 ms; 500 consecutive jobs gave identical verified output. Driver limits: input up to 8192x8192, output up to 4096x4096, scale 1/16 to 16 |

Not measured: the probe app after a boot with no display attached (it ran with
HDMI unplugged from a running board), the `agent-dev-board` flavor on this
board, sustained or thermal behaviour (runs were under a minute, at about
30 C), the accuracy of quantized detection models, and the decoder-to-RGA
zero-copy handoff.

### What a consumer must do

- **GPU: use the GBM platform on `/dev/dri/card0`.** The surfaceless EGL platform
  fails with this library, and the GBM path fails when the app has only the
  render node, so the app must list the card node.
- **RGA: pass dma-buf fds.** The kernel driver refuses buffers passed as
  ordinary user memory (a virtual address): it requires user memory to map as
  one contiguous segment, which pageable memory does not. This is a property of
  the vendor RGA2 driver on RK356x, not of this board's memory layout. Use
  dma-heap allocations or the decoder's frame buffers.
- **Video and NPU: set `devicetree: true`** (next section).

### `devicetree: true`

Software that detects the SoC through `/proc/device-tree` needs
`devicetree: true` in the app's config. Without it the path does not resolve in
the container. Rockchip's MPP reads only `/proc/device-tree/compatible`, so
without the key it cannot identify the SoC and registers no decoder or encoder,
and the RKNN runtime fails to initialise. The GPU and RGA work without it.
Vagus does slightly more than upstream
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
costs 256 MiB: about 3.58 GiB of the 4 GB is usable. No RGA job was refused for
its address.
