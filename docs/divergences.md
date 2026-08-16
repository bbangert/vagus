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

## NOT a divergence: the host console and ptys are reachable from any add-on

Recorded here because it looks like one, was nearly "fixed" like one, and the
attempted fix was theatre.

**The facts, all measured** (balenaEngine v25.0.14, both boards — see
[`device-gate-2026-08-16.md`](device-gate-2026-08-16.md)):

moby's default device cgroup allows `c 5:1` (console) and `c 136:*` (pty
slaves) for every container, because containers need a console and ptys.
`DeviceCgroupRules` is additive and cannot revoke a default allow. `CAP_MKNOD`
is in the default capability set, and the `m` bit on those allows permits
node creation.

**A cgroup rule names a device number, not a path.** So a container with **no
`/dev` bind at all** — every add-on on every shipped Vagus firmware — can do
this:

```
devlist=fd full mqueue null ptmx pts random shm stderr stdin stdout tty urandom zero
MKNOD_OK   CONSOLE_READ_OK   CONSOLE_WRITE_OK      # after `mknod /tmp/c c 5 1`
```

The `MOUNT_DEV` bind therefore changes **convenience, not reachability**. It
puts `/dev/console` at its usual path instead of requiring one `mknod`.

**A `/dev/null` mask over `/dev/console` was implemented and then removed.** It
worked at the pathname level — the node read `1:3` instead of `5:1` — and was
defeated in one command:

```
masked=1:3   MKNOD_OK   recreated=5:1   BYPASS_READ_OK   BYPASS_WRITE_OK
```

Shipping it would have added an upstream divergence, a ledger entry and a test,
in exchange for nothing but false confidence.

**Upstream is identical.** Its `MOUNT_DEV` sets
`bind_options=MountBindOptions(read_only_non_recursive=True)`; the engine
honours the field and behaviour is byte-identical, and upstream does not drop
`MKNOD` either. Docker 29.6.1 behaves the same, so this is neither a
balena-engine limitation nor something switching runtimes would fix.

**What the exposure is worth.** The IEx shell is **not** reachable: `erlinit
--ctty tty1` puts it on `/dev/tty1`, and `c 4:*` is not in the default
allowlist — `/dev/tty1`, `/dev/tty0` and `/dev/ttyAMA0` are all denied, as is
every block device without an explicit rule. `/dev/pts/0` is PID 1's stdio (the
BEAM's nbtty pty), so an add-on can read keystrokes typed at the *local*
console and spoof its output. Writing a pty **slave** sends output; it does not
inject input, so this is disclosure and spoofing, not command injection.

**The only measured fix is `CapDrop: ["MKNOD"]`**, verified to close the
recreation path. Not adopted: upstream does not do it, it would break an add-on
that legitimately creates device nodes, and it is **unverified** against a
device node shipped inside an add-on's own image layers. If the local-console
exposure is ever judged unacceptable, that is the lever — and it is a fleet-wide
decision, not a property of the `/dev` bind.

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
