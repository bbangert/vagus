# Agent dev board

The agent-dev-board flavor of the dragon_q6a firmware runs Claude Code on the
board instead of Home Assistant Core. Build, OTA and how to tell a board's
flavor are in [targets.md](targets.md#agent-dev-board-flavor-dragon_q6a).

## Two layers

1. **Vagus on the board.** The same release as stock, minus Core. On this
   flavor boot also starts Erlang distribution, writes the node file (below)
   and installs and starts one app, `agent_orchestrator`.
2. **The agents.** The orchestrator app
   (`ghcr.io/bbangert/vagus-agent-orchestrator`) holds the board's one
   claude.ai login and runs a Remote Control session the owner drives from
   claude.ai. For each task it creates worker containers from
   `ghcr.io/bbangert/vagus-agent-base` and runs headless Claude in them.

## Owner decisions

**D1, raw dist.** The orchestrator controls the board over plain Erlang
distribution: it gets the node name and cookie and can run any Elixir on the
node. There is no scoped API in between.

**D2, hybrid images.** A fat base image (glibc, arm64, pinned Claude Code,
the hardware tools) is built in CI and published to ghcr. Per-task layers are
thin and built on the board with `podman build`.

**D3, one login holder.** Only the orchestrator holds the claude.ai login and
runs Remote Control. Workers are headless `claude -p` and get a copy of the
login in a config dir of their own. No two live sessions share a config dir,
and no agent container has an `ANTHROPIC_API_KEY`. When the owner wants to
drive a worker directly, the orchestrator can start an interactive one that
does its own login.

**D4, firmware flavor.** All the code ships in the base release. The flavor is
picked at build time and runs no Core.

**D5, raw podman workers.** Workers are plain podman containers. The
orchestrator creates them through `Vagus.Runtime.Podman.Cmd` over dist. They
are outside the app lifecycle, and none is ever named `addon_*`.

**D6, Bluetooth on demand (planned).** Vagus's Bluetooth stack will be
stoppable and startable over dist (`Vagus.Bluetooth.stop/0` and `start/0`,
a later phase), so a worker can take the adapter; it runs by default. Until
then the playbook marks those calls "when available", like D8's loader.

**D7, root by design.** The agent (the orchestrator and, through it, its
workers) is root on the board, and that is intended. Tasks load kernel
modules, hand devices over, reconfigure interfaces and build packages. The
guard rails keep the board reachable and recoverable (the A/B slot, heart,
the playbook's never-do list). They do not limit privilege. The board is
expendable. The agent cannot build or flash firmware, so the firmware slots
are never at risk. Anything it breaks on the running system is fixed by a
reboot, a revert to the other slot, or a fresh OTA.

**D8, hot patches.** The agent may hot-load changed modules into the running
Vagus node. Patches will be kept under `/data`, each with a note, and loaded
at boot. Vagus's loader for them arrives in a later phase.

## The node file

| | |
|---|---|
| Host path | `/run/vagus/dist/node.json`, on the `/run` tmpfs |
| Mode | file 0640, directory 0750, root:1000 (the image's `agent` group) |
| Content | `{"node": "vagus@<ip>", "cookie": "<cookie>"}`, nothing else |
| Lifetime | Written again on every boot, when dist starts. Gone at reboot. |
| In the container | The directory is bound read-only at `/run/vagus-dist`. `VAGUS_DIST_FILE=/run/vagus-dist/node.json` |

The directory is bound rather than the file, so the container always reads the
current file. The cookie is never in the container's env or in
`podman inspect`. If `/run/vagus/dist` does not exist, dist did not come up,
and creating the container fails instead of binding an empty directory.

The container also gets `CLAUDE_CONFIG_DIR=/data/claude`. Its `/data` is
`/data/addons/data/agent_orchestrator` on the board.

## What the orchestrator may do over dist

Anything (D1, D7). The playbook in the image (`images/agent-orchestrator/CLAUDE.md`)
lists the useful calls: podman through `Vagus.Runtime.Podman.Cmd.run/2`,
Bluetooth stop and start, `VintageNet.configure/3` for a target NIC, and the
board's logs. It also has the never-do list: don't stop the node, don't
reconfigure `eth0` or `wlan0`, don't touch `addon_*` containers or podman's
store, and don't copy the cookie anywhere.

## Lab services

Phase 8 calls for wiring a target board to the dev board. Lab, NFS and USB/IP
are agent flavor only. Their state survives a Vagus restart (Lab keeps it in
`persistent_term`, NFS adopts `/run/nfs/etab`, USB/IP re-reads which devices
`usbip-host` holds) but not a reboot, by design; the orchestrator re-applies
them.

**Target network.** `Vagus.Network.Lab.up(ifname, cidr)` gives an extra USB NIC
a static address (not persisted) and adds an nft forward plus masquerade to the
primary interface only while it is up. `down/1` undoes both and `status/0`
reports. It refuses `eth0`, `wlan0`, `usb0`, `hassio*`, any interface
VintageNet already configures, and a cidr that overlaps the LAN or
`172.30.32.0/23`. DHCP, TFTP and PXE for the target run in a worker, since
`dnsmasq-base` is in the base image. The worker is on the host network, so
`--interface` must name the lab NIC, never `eth0` or `wlan0`, or it answers
DHCP on the LAN:

    podman run -d --name lab-dnsmasq --network=host --cap-add=NET_ADMIN,NET_RAW \
      -v /data/vagus/tftp/<target>:/data/tftp:ro <base image> \
      dnsmasq --keep-in-foreground --interface=<lab NIC> --bind-interfaces \
      --dhcp-range=10.42.0.50,10.42.0.150,12h --enable-tftp --tftp-root=/data/tftp \
      --dhcp-boot=<bootfile>

The base image has no `/data/tftp`, so populate the bind-mounted directory
first with the target's kernel, initrd and bootloader. `/data/vagus/tftp/` is
the suggested place, beside `/data/vagus/nfs/`.

**NFS root.** `Vagus.NFS.export(path, client_cidr)`, `unexport/1` and
`status/0`, agent flavor only. Paths must be under `/data/vagus/nfs/`, and
the server speaks NFSv4 only. Kernel nfsd listens on every interface, so the
per-export client CIDR is the only access control; a `/0` client is refused.
Exports use `subtree_check`, so a client cannot reach outside the exported
directory. The target mounts the path `status/0` reports as `export_path`,
not the one passed to `export/2`: NFSv4 clients walk the server's real
directory tree, and on Nerves `/data` is a symlink to `/root`, so that is
`/root/vagus/nfs/<target>`. Kernel args for the target:

    root=/dev/nfs nfsroot=10.42.0.1:/root/vagus/nfs/<target>,vers=4,tcp rw ip=dhcp

**USB/IP.** `Vagus.USBIP.share("usb:1-1.2")` (the id comes from
`Vagus.Devices.list()` / `GET /hardware/devices`), `unshare/1` and `shared/0`,
agent flavor only. The host side binds the device to `usbip-host` through sysfs;
`usbipd` runs in the privileged host-network container `vagus-usbipd`, from the
base image. On the laptop:

    sudo modprobe vhci-hcd && usbip list -r <board-ip> && sudo usbip attach -r <board-ip> -b 1-1.2

The board's onboard WiFi/Bluetooth device (`usb:1-1.4`, the AIC8800 on the
dragon_q6a) cannot be shared: the chip disconnects and re-enumerates itself
whenever `usbip-host` claims it, so the share is dropped within seconds and the
device returns to its own driver. Share only devices plugged into the board's
USB ports.

The share drops when the device is unplugged. USB/IP has no authentication:
anyone on the LAN who can reach port 3240 can attach a shared device, so share
only for as long as a task needs it. The board must not open a shared device
itself.

**Power.** `Vagus.Power.mqtt(topic, payload)` publishes to the board's own
broker (QoS 1, `retain: true` and `qos:` are options), so smart plugs need no
worker. `:ok` means the message was sent, not acknowledged. Do not use
`retain: true` for plug commands: a retained `ON` fires again whenever the
plug reconnects. Tasmota takes `cmnd/<device>/Power` with `ON` or `OFF`; Shelly Gen1
takes `shellies/<id>/relay/0/command` with `on` or `off`. It returns
`{:error, :no_broker}` when the broker app is not running. Two recipes live in
a worker instead:

- `uhubctl -l <hub> -p <port> -a off|on` for hubs with per-port power
  switching; the worker needs `/dev/bus/usb`.
- GPIO relays, with Python `gpiod` or `Circuits.GPIO` against `/dev/gpiochip*`.
  The worker needs `--device /dev/gpiochipN`. Header pin names are
  board-specific, so record them in the task notes.

## Logging in

The login is done once per board by the owner. It is a paste-code flow. From
IEx over ssh:

```elixir
cmd("podman exec -it --user agent -e HOME=/home/agent addon_agent_orchestrator claude auth login")
```

This is the one `addon_`-named container the agent may touch, because Vagus
owns it. Always use `--user agent`. As root, the 0600 credentials file is
written where the agent cannot read it.

`cmd/1` has no TTY and does not pass stdin through, so the paste prompt cannot
be answered there. The route that worked is to run the same command in a tmux
window inside the container (as `--user agent`), read the URL with
`tmux capture-pane`, and type the code with `tmux send-keys`. Check it with
`claude auth status --json`, which should show `authMethod: "claude.ai"`.
Remote Control connects on the loop's next start.

The login expires like any other: the CLI warns 3 days ahead, and the same
procedure renews it.

## Headless workers

1. `worker-config <task>` (inside the orchestrator) creates
   `/data/worker-configs/<task>` holding only a copy of the login. It prints
   the board path to mount. Running it again refreshes the copy.
2. Create the worker with `podman run -d --name task-<task> --memory <limit> …`
   through `Cmd.run`. Mount its config dir at `/claude` and its work dir at
   `/work`. `--memory` is always set, because an uncapped worker can OOM the
   board's BEAM.
3. Run Claude in it:
   `podman exec --user agent -e HOME=/home/agent -e CLAUDE_CONFIG_DIR=/claude -w /work task-<task> claude -p "<task>" --output-format stream-json --verbose --permission-mode auto --permission-prompts none`.
4. The last stream-json line carries `session_id`. Continue the same session
   in the same container with `--resume <session_id>`.
5. `podman rm -f task-<task>` when done. The podman store is transient, so
   every worker is gone after a reboot.

Worker output is untrusted. It never goes into `vagus eval` and never decides
board-level actions.

## Protection

For the orchestrator slug (`config :vagus, :orchestrator_app`, set only on
this flavor), `POST /addons/<slug>/stop`, `restart` and `uninstall` return
400 "protected", and so does a partial backup restore that names it. So does
an options POST that carries `boot` or `watchdog`, and nothing else in that
body is applied. The other options still save. The same holds when the app
names itself `self`, and for `Vagus.App.stop/1`, `restart/1`, `uninstall/1`,
`restore/5` and `set/2` called directly, which return `{:error, :protected}`.
An update stays allowed: an image bump is legitimate, and it starts the app
again.

The app is installed with `boot: "auto"` and `watchdog: true`, and every boot
puts them back if they are missing. Within that:

- the watchdog gives up after 5 consecutive restarts, leaving the app stopped
  until the next boot;
- a boot whose `dist` gate fails, or runs out of tries, halts there, and the
  app is not started until the next boot;
- the install pulls an image beside the boot, so a pull that fails (an
  offline first boot) leaves no app until a later boot's install succeeds.

Shutdown is unaffected. The boot sequencer halts the app and stops its
container through its own units, not through these calls.

## OTA

The updater only installs the `-agent` asset on this flavor and the stock one
on stock, so an OTA never switches flavors. An OTA restarts the node, which
drops any hot-loaded code until a boot-time loader exists (D8). `/data` is
kept, along with the login and the task dirs. The node file and the cookie
are new after every boot.

## Security

- Root by design (D7). Whoever drives the orchestrator owns the board.
- The cookie exists only on tmpfs, in a file only root and the image's
  `agent` group (gid 1000) can read, and in the BEAM. It is never on `/data`,
  in env or in `podman inspect`. The `vagus` CLI puts it on its own argv,
  though, and argv (`/proc/<pid>/cmdline`) is readable by any process that
  shares the host PID namespace: every host process, an app with `host_pid`
  (were the orchestrator's protection lifted, through it too), and a worker
  started with `--pid=host`. Never start a worker with `--pid=host`. The next
  orchestrator image reads the cookie at runtime instead of passing it on
  argv (a follow-up).
- The credentials dir (`/data/claude`) belongs to one board's login. It is
  never copied to another board and never mounted into a worker. Workers get
  `worker-config` copies.
- Erlang distribution runs in the clear. A worker on the host network shares
  the board's loopback, so host networking is only for tasks that need it.
- The board is a development appliance. Never share it or expose it to an
  untrusted network.
