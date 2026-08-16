# Device gate transcript — Phase 7 (partial)

Run 2026-08-16 against live boards. Engine **balenaEngine v25.0.14, API 1.44**
on both — the version the earlier docker-29.6.1 measurement could not stand in
for.

| Board | IP | Platform | vagus_platform |
|---|---|---|---|
| rpi3_64 | 192.168.2.149 | rpi3_64 aarch64 | 0.6.1 |
| dragon_q6a | 192.168.2.58 | dragon_q6a | 0.5.1 |

The `/dev` bind is **not** on either board's firmware (it is on `main`,
unreleased). These containers were created directly against each board's engine
with the exact `HostConfig.Mounts` entry `mounts/2` emits, so the measurement is
of the **engine**, not of a flashed build. No add-on was touched; every probe
container was removed and both boards verified clean afterwards.

---

## Result 1 — `DeviceCgroupRules` is enforced (U1 SETTLED) ✅

Positive **and** negative control on .149, whole-`/dev` bind present in both,
target `/dev/mmcblk0` = `b 179:0 rwm`:

```
##### NEGATIVE: no DeviceCgroupRules (must be denied) #####
OPEN_DENIED
##### POSITIVE: with b 179:0 rwm (must be granted) #####
OPEN_OK
READ_OK
```

The rule is what grants access, and its absence genuinely denies — this is not
"accepted by the API and ignored". Block devices are denied by default, so the
`devices:` mechanism works exactly as designed.

It also shows the teeth: `READ_OK` is 512 bytes off the **boot medium**. On
rpi3_64 `/dev/mmcblk0` *is* system storage, so `Vagus.Addon.SystemDisk` (PR #25)
would refuse to emit that rule — which is the whole reason that check exists.

## Result 2 — the unconditional `/dev` bind leaks host console + ptys ❌

**Both boards. Container with `Tty: false`, so it owns no pty of its own, and
NO device rules at all.**

Host (.149): `/dev/console 5:1`, `/dev/pts/0 88:0` (hex), `/dev/pts = ["0", "ptmx"]`

```
##### A: WITH /dev bind, Tty FALSE #####          ##### B: CONTROL, no bind #####
/dev/console 5:1      <-- host's, exactly         /dev/console ABSENT
/dev/pts/0   88:0     <-- host's, exactly         /dev/pts/0   ABSENT
/dev/pts = 0 ptmx                                 /dev/pts = ptmx
```

Host (.58): `/dev/console 5:1`, `/dev/pts/0 88:0`, `/dev/pts/1 88:1`

```
##### A: WITH /dev bind, Tty FALSE #####          ##### B: CONTROL, no bind #####
/dev/console 5:1                                  /dev/console ABSENT
/dev/pts/0   88:0                                 /dev/pts/0   ABSENT
/dev/pts/1   88:1                                 /dev/pts/1   ABSENT
/dev/pts = 0 1 ptmx                               /dev/pts = ptmx
```

Device numbers match the host **exactly**, and `Tty: false` removes the
alternative explanation — the container has no pty of its own, so every entry it
sees belongs to the host. The control gets a private, empty devpts and no
console at all, which is what makes the bind the proven cause.

An earlier run with `Tty: true` additionally showed `CONSOLE_OPEN_OK` and
`PTS0_OPEN_OK` — the nodes are not merely visible, they open. `/dev/pts` is
mounted `ro` (inherited from the bind) rather than the control's `rw`, the same
signature seen on docker 29.6.1.

**Consequence:** every add-on, with no `devices:` and no protection change,
could open the host's console and pty slaves. Result 3 below narrows what that
is actually worth — the IEx shell is **not** among them.

**The HAOS fixture is not a counter-example after all.** It showed `/dev/pts` as
`rw`, which is what suggested balenaEngine might not leak. That inference is now
falsified on the actual engine at the actual version.

---

## Result 3 — it is a MOUNT problem, not a cgroup one, and cgroups are working

Same container, plain `/dev` bind, no device rules:

```
/dev/tty1     DENIED     <-- the IEx shell's VT (erlinit --ctty tty1)
/dev/tty0     DENIED
/dev/ttyAMA0  DENIED     <-- serial
/dev/mmcblk0  DENIED     <-- boot medium (Result 1)
/dev/console  OPEN_OK + WRITE_OPEN_OK
/dev/pts/0    OPEN_OK
```

Exposure is confined to **exactly** the numbers moby's default allowlist
permits (`c 5:1`, `c 136:*`). Everything outside it is denied. No board cgroup
option is missing, and none could help: `DeviceCgroupRules` is additive and
cannot revoke the default allows.

**Correction to Result 2's severity.** `erlinit.config` uses `--ctty tty1` with
`--alternate-exec /usr/bin/nbtty`, so the IEx shell's VT is `/dev/tty1`, which
is **denied**. The earlier "unauthenticated root IEx on `/dev/console`" framing
was wrong. What `/dev/pts/0` actually is: PID 1's stdio (`heart`, `uevent`,
`kmsg_tailer`, `muontrap`, `if_monitor` all inherit it) — the pty slave nbtty
runs the BEAM on. So an add-on can read keystrokes typed at the *local* console
and write spoofed output to it. Writing to a pty **slave** does not inject input,
so this is disclosure and spoofing, not command injection.

## Result 4 — upstream's own `MOUNT_DEV` does not avoid this

`supervisor/docker/const.py`:

```python
MOUNT_DEV = DockerMount(type=MountType.BIND, source="/dev", target="/dev",
    read_only=True, bind_options=MountBindOptions(read_only_non_recursive=True))
```

Vagus emits the bind with **no `BindOptions` at all** — a real parity gap. The
engine supports the field (round-trips in inspect, while a bogus field is
dropped, which is what makes the echo meaningful):

```
ronr:   sent=%{"ReadOnlyNonRecursive" => true}  echoed=%{"ReadOnlyNonRecursive" => true}
nonrec: sent=%{"NonRecursive" => true}          echoed=%{"NonRecursive" => true}
bogus:  sent=%{"ThisFieldDoesNotExist" => true} echoed=%{}
```

But behaviourally **A ≡ B**: upstream's exact config leaks host console and ptys
identically. So this is inherited upstream behaviour, not a Vagus-invented hole
and not a balena-engine limitation. Switching to Docker would not help either —
docker 29.6.1 leaked the same way.

## Result 5 — candidate mitigations, measured

| Option | Effect | Verdict |
|---|---|---|
| `BindOptions.ReadOnlyNonRecursive` | no change to the leak (A ≡ B) | do it anyway — upstream parity, we're missing it |
| Bind `/dev/null` → `/dev/console` | masks the **path** only | **REJECTED — see Result 6.** One `mknod c 5 1` walks around it |
| `BindOptions.NonRecursive` | host `/dev/pts` gone, but **PTMX_FAIL** | **reject** — breaks pty allocation, so the SSH/Terminal add-on dies |

No measured option closes the `/dev/pts` exposure without breaking ptys. That
half is upstream's behaviour too.

## Status

Read Result 6 before acting on Results 2 and 5 — it supersedes their
conclusions.

- Phase 7 "q6a positive / negative control" for `devices:` — **PASSED** (Result 1).
- Phase 7 bind-exposure control — **ran, and the finding was reclassified.** The
  bind exposes host console and ptys at their usual paths (Result 2), but does
  not *grant* anything: the same devices are reachable by `mknod` with no bind
  at all (Result 6). Not a release blocker, and not introduced by PR #24.
- Not yet run: rpi3_64 whole-fleet add-on regression, protection-mode gate
  (needs Phase 4), dsp bind (needs Phase 6).

**No release blocker from this gate.** The console/pty exposure is pre-existing
on shipped firmware, identical upstream, and independent of the `/dev` bind.
`CapDrop: ["MKNOD"]` is the only measured lever and is a separate, fleet-wide
decision (see `divergences.md`).

---

## Result 6 — the console exposure predates the `/dev` bind (added after review)

Copilot pointed out on #26 that masking a pathname does not revoke a device
number. It is right, and chasing it invalidated the framing of Results 2 and 5.

Shipping config (bind + `ReadOnlyNonRecursive` + `/dev/null` over
`/dev/console`), default capabilities:

```
masked=1:3        <- the pathname mask does work
MKNOD_OK
recreated=5:1     <- the add-on makes its own node
BYPASS_READ_OK  BYPASS_WRITE_OK
BLOCK_BYPASS_DENIED   <- block devices still denied; the cgroup is doing its job
```

With `CapDrop: ["MKNOD"]` the bypass closes (`MKNOD_DENIED`).

**Then the control that mattered — a container with NO `/dev` bind at all**,
i.e. every add-on on shipped firmware, before PR #24 existed:

```
devlist=fd full mqueue null ptmx pts random shm stderr stdin stdout tty urandom zero
MKNOD_OK   CONSOLE_READ_OK   CONSOLE_WRITE_OK
```

**So the bind never granted this.** `CAP_MKNOD` plus the default `c 5:1` allow
did, and has on every shipped firmware. The bind changes convenience only.

Consequences, recorded plainly:

* "The `/dev` bind is a release blocker" (Result 2's conclusion) was **wrong**.
* The `/dev/null` mask was removed rather than shipped.
* This is an **existing** fleet exposure, not one PR #24 introduced, and
  upstream HAOS has it identically.

The error in Result 2 was reasoning from visible nodes to reachability without
asking whether the node was the enforcement point. The earlier security review
had already said it was not.
