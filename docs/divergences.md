# Deliberate divergences from the real Supervisor

Vagus targets behavioural parity with Home Assistant's Supervisor. Where it
knowingly does something different, the difference is recorded here with the
reason and the evidence — a divergence that is not written down becomes a bug
report from a user who expected upstream's behaviour.

This is for *decisions*. Gaps still to close belong in issues, and the
mount-level ledgers enforced by
`test/vagus/addon/container_fingerprint_test.exs` (`@accepted_mounts`,
`@vagus_only_mounts`) are the machine-checked half of this document.

---

## `/dev/console` is masked with `/dev/null` in every add-on container

**Upstream:** binds the host's whole `/dev` read-only into every add-on
(`MOUNT_DEV` in `supervisor/docker/const.py`) and leaves `/dev/console`
reachable.

**Vagus:** does the same bind, then binds `/dev/null` over `/dev/console`.

**Why.** moby's default device cgroup allows `c 5:1` (console) and `c 136:*`
(pty slaves) for every container, because containers need their own console and
ptys. The `/dev` bind replaces the container's private `/dev` with the host's,
so those default allows now resolve to *host* devices. `DeviceCgroupRules` is
additive and cannot revoke a default allow, so this cannot be fixed with a
cgroup rule — it is a mount-namespace problem.

Measured on both boards (balenaEngine v25.0.14, `Tty: false` so the container
owns no pty, no device rules at all):

| | with `/dev` bind | control, no bind |
|---|---|---|
| `/dev/console` | `5:1` — the host's | absent |
| `/dev/pts/0` | `136:0` — the host's | absent |
| `/dev/tty1`, `/dev/tty0`, `/dev/ttyAMA0` | denied | — |

Upstream's own `bind_options=MountBindOptions(read_only_non_recursive=True)`
does **not** avoid this: the engine honours the field (it round-trips in
`inspect`, while a bogus field is dropped) and the result is byte-identical.
Docker 29.6.1 behaves the same, so this is neither a balena-engine limitation
nor something switching runtimes would fix. **Upstream HAOS has the same
exposure.**

**So why diverge at all?** What sits on the node differs. A HAOS console is a
login getty; this one carries the BEAM's output, so spoofed writes there are
more misleading. The mask is cheap and measured: afterwards the node reads
`1:3` instead of `5:1`. Writes still succeed and are discarded, because a
character device bypasses a mount's read-only check — so an add-on that logs to
`/dev/console` keeps working.

**What this does NOT fix.** The `/dev/pts` half is untouched. An add-on can
still open the host's pty slaves, which on this platform means the BEAM's nbtty
pty — reading it captures keystrokes typed at the *local* console, writing it
spoofs that display. It is not command injection: writing to a pty **slave**
sends output to the terminal, it does not inject input. The IEx VT itself
(`/dev/tty1`, per `erlinit --ctty tty1`) is denied by the device cgroup.

Nothing measured closes the pts half without breaking pty allocation:
`BindOptions.NonRecursive` removes the host devpts but then `/dev/ptmx` fails,
which would kill the SSH/Terminal add-on. Left as upstream parity.

**Evidence:** [`device-gate-2026-08-16.md`](device-gate-2026-08-16.md) — the
full run against boards 192.168.2.149 (rpi3_64) and 192.168.2.58 (dragon_q6a),
including the negative controls.

---

## System storage is refused for `devices:` grants

**Upstream:** refuses a block device that `disk.is_used_by_system/1` claims —
a partition whose udev `ID_FS_LABEL` starts with `hassos`, or a whole disk
owning one (`hardware/policy.py` `allowed_for_access/1`, consulted by
`docker/app.py` before each rule is built).

**Vagus:** refuses any block devnum backing a system mount (`/`, `/boot`,
`/root`, `/data`), plus — via sysfs — the whole disk it sits on and every
sibling partition (`Vagus.Addon.SystemDisk`).

**Why the mechanism differs.** Nerves runs no udev, so `ID_FS_LABEL` does not
exist, and Vagus's partitions are not labelled `hassos*` in any case. The mount
table answers the same question without udev.

**Why it is stricter.** Upstream blocks only labelled partitions, leaving a
co-resident unlabelled one grantable. On a Nerves appliance every partition of
the boot medium is system storage, so the whole device is refused. Any
unresolved step (unreadable mount table, a mount sysfs cannot map, a malformed
`dev` file) collapses the answer to "refuse every block device" — the half that
failed to resolve is exactly where the system partition would hide.

Character devices are unaffected, matching upstream's block-only check.
