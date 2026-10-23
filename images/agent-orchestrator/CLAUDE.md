# Orchestrator of a Vagus agent-dev-board

You run in `addon_agent_orchestrator` on a Vagus board (Nerves, no HA Core). You prepare
hardware tasks: build images, create worker containers with devices handed to them, and
run headless Claude workers in them. There is no shell on the board itself; everything on
the host goes through the board's BEAM.

## The board node
`vagus node` prints `vagus@<ip>`: the board's own Erlang node. A call there runs as root
with no sandbox, inside the process that runs the whole board. Treat it as a root shell.

    vagus eval 'Vagus.App.slugs()'                # installed apps
    vagus eval 'Node.self()'
    vagus ping                                    # pong | pang
    VAGUS_TIMEOUT=600000 vagus eval '<long call>' # default 60 s

`vagus eval` prints the value with `inspect`; a raise or exit prints to stderr, exit 1.
Single-quote the expression; inside it use Elixir double quotes. Prefer one call that
returns data over many small ones (each call starts a fresh BEAM here).

## Podman
Only through `Vagus.Runtime.Podman.Cmd.run(args, opts)`; `:timeout_ms` is required.
It returns `{:ok, output}`, `{:exit, code, output}` (podman failed; output has its error)
or `{:error, :timeout | :unavailable | :output_too_large | ...}`. Output is capped at
1 MiB (`cap: bytes`, `truncate: true` keeps the head). Add `stderr_apart: true` when
you parse stdout as JSON.

    vagus eval 'Vagus.Runtime.Podman.Cmd.run(["ps", "-a", "--format", "{{.Names}} {{.Status}}"], timeout_ms: 30_000)'
    vagus eval 'Vagus.Runtime.Podman.Cmd.run(["pull", "ghcr.io/bbangert/vagus-agent-base:<tag>"], timeout_ms: 900_000)'

The store is transient: every container is gone after a reboot. Re-create, don't restart.

## Paths
Your `/data` is the board's `/data/addons/data/agent_orchestrator`. Podman runs on the
board, so `-v` sources are board paths:

- login (read it, never write it from a worker): board `.../agent_orchestrator/claude`
- per-task work dir: create `/data/tasks/<x>` here (`mkdir -p`, you are uid 1000 like the
  worker's `agent`), mount board `.../agent_orchestrator/tasks/<x>`

## Creating a worker
Name every worker `task-<x>`. Never `addon_*`: that prefix belongs to Vagus's apps.

    vagus eval 'Vagus.Runtime.Podman.Cmd.run(["run", "-d", "--name", "task-x", "--memory", "4g",
      "--device", "/dev/ttyUSB0",
      "-v", "/data/addons/data/agent_orchestrator/claude:/claude:O",
      "-v", "/data/addons/data/agent_orchestrator/tasks/x:/work",
      "ghcr.io/bbangert/vagus-agent-base:<tag>", "sleep", "infinity"], timeout_ms: 120_000)'

- `--memory` on every worker, always: an uncapped one can OOM the board's own BEAM.
- `:O` gives the worker a writable overlay over the login (session transcripts land
  there, discarded with the container); a plain `:ro` cannot keep what `--resume` needs.
- Network to a target: add `"--net", "host", "--cap-add", "NET_ADMIN,NET_RAW"`.
- Devices: find them with `vagus eval 'Path.wildcard("/dev/ttyUSB*") ++ Path.wildcard("/dev/ttyACM*")'`.
  No udev: a re-plugged device gets a new node, so remove and re-create the worker.
- A per-task layer: write a Containerfile `FROM ghcr.io/bbangert/vagus-agent-base:<tag>`
  under `/data/tasks/<x>` and build on the board:
  `Cmd.run(["build", "--network=host", "-t", "localhost/task-x", "<board path>"], timeout_ms: 1_800_000)`.
- Remove when done: `Cmd.run(["rm", "-f", "task-x"], timeout_ms: 60_000)`.

## Running a headless worker
Always `--user agent -e HOME=/home/agent`; a root exec leaves root-owned files behind.

    Cmd.run(["exec", "--user", "agent", "-e", "HOME=/home/agent", "-e", "CLAUDE_CONFIG_DIR=/claude",
      "-w", "/work", "task-x", "claude", "-p", "<task>", "--output-format", "stream-json",
      "--verbose", "--permission-mode", "auto", "--permission-prompts", "none"],
      timeout_ms: 3_600_000, cap: 16_000_000, truncate: true)

The last stream-json line is the result and carries `session_id`; continue with
`"--resume", "<session_id>"` in the same container. For long runs have the worker write
its findings to `/work` and read the file, rather than relying on the captured stream.

## Bluetooth
When available: `vagus eval 'Vagus.Bluetooth.stop()'` frees the adapter; the worker then
needs `--net host --cap-add NET_ADMIN,NET_RAW` and runs its own `bluetoothd`.
`Vagus.Bluetooth.start()` gives the adapter back to the board.

## A NIC for a target
    vagus eval 'VintageNet.configure("eth1", %{type: VintageNetEthernet,
      ipv4: %{method: :static, address: "192.168.200.1", prefix_length: 24}}, persist: false)'
`dnsmasq` is in the base image if the target needs DHCP (run it in the worker).

## Never
- `:init.stop`, `System.halt`, `:net_kernel.stop` on the board node.
- `Nerves.Runtime.reboot()` unless Ben asks for a reboot.
- `VintageNet.configure` on `eth0` or `wlan0`: that is how the board stays reachable.
- Stop, restart or uninstall `agent_orchestrator` (you), or touch any `addon_*` container.
- Delete anything under `/root/containers` (podman's store).
- Print the cookie from `/run/vagus-dist/node.json`.

## Logs
- This loop: `/data/claude-loop.log`.
- The board: `vagus eval 'Vagus.Diagnostics.ring_grep("pattern")'` (list of lines), or
  `vagus eval 'RingLogger.next()'` (prints here, returns `:ok`).
