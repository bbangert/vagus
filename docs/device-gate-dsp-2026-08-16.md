# Device gate — `vagus-dsp-setup` Phase 0

Run 2026-08-16 against `dragon_q6a` at 192.168.2.58 (vagus_platform 0.5.1,
balenaEngine v25.0.14). Cross-checks against the second `dragon_q6a` at
192.168.2.87. Both boards left in their pre-spike state: probe containers
removed, the pulled base image removed, staged files deleted.

**Answer: outcome B.** The container needs the fastrpc shells as well as the
skel. It also needs two device cgroup rules that `dsp: true` does not emit
today, without which it cannot reach the DSP at all.

---

## The probe, and why it is the right one

The plan called for a QNN HTP init. The host already ships a closer and much
cheaper instrument: `/usr/bin/fastrpc_test`, whose structure is the same
three-part split this feature has to get right.

| `fastrpc_test` | `vagus-dsp-setup` |
|---|---|
| `/usr/lib/fastrpc_test/*.so` — aarch64 stubs | QNN host libs, shipped in the add-on image |
| `/usr/share/fastrpc_test/v68/*_skel.so` — Hexagon skels, found via `DSP_LIBRARY_PATH` | `libQnnHtpV68Skel.so`, the operator upload |
| `/usr/lib/dsp/cdsp/fastrpc_shell_3` | the shells the system image ships |

It exercises the same `libcdsprpc.so.1` session-creation path and does real DSP
compute, so a pass is not "the file is visible" — it is a Hexagon round-trip.

Both halves are located by the same mechanism. `libcdsprpc.so.1` carries the
built-in search list

```
;/usr/lib/dsp/cdsp;/usr/lib/dsp/adsp;/usr/lib/rfsa/adsp;/usr/lib/dsp;
```

and looks up **both** `fastrpc_shell_*` and the skels along it, via
`apps_std_fopen_with_env(ADSP_LIBRARY_PATH, ";", …)` — the env var overrides,
the list is the default.

**Host baseline (positive control), no container:** `Sum = 499500` computed on
domain 3, 3/3 PASS. The cDSP is live — `remoteproc1` = `cdsp`, state `running`.

## Result 1 — the skel alone is not enough (outcome B) ❌

Container: Debian arm64 + the stubs + a Vagus-shaped store directory holding
**only** the skels, bound where `DSP_LIBRARY_PATH` points. No `/usr/lib/dsp`
anywhere. All four device rules granted, so device access is not the variable.

```
##### A: skel store only, no shells #####     ##### B: shells + same skel store #####
Compute sum on domain 3                        Compute sum on domain 3
Retry attempt unsuccessful. Timing out....     Call calculator_sum on the DSP
ERROR 0x80000600: Failed to compute sum        Sum = 499500
ERROR 0x80000600: Unable to create             Max value = 999
  FastRPC session on domain 3                  [PASS] libcalculator.so
Passed: 0  Failed: 3          exit=3           Passed: 3  Failed: 0     exit=0
```

**Control C — shells present, skel store absent:**

```
ERROR 0x80000406: Unable to create FastRPC session on domain 3
Passed: 0  Failed: 3   exit=3
```

The two failures carry **different error codes**, which is what makes this
conclusive rather than merely negative:

* `0x80000600` — no shell: the session never opens.
* `0x80000406` — shell present, skel missing: the session opens and the skel
  load fails. (Same code the SDK's own docs attribute to "Unable to load Skel
  Library".)

Each half is independently required, and each fails in its own distinct way.

### The part that makes outcome B cheap

In variant B the shells and the skels were in **different directories** —
shells at `/usr/lib/dsp`, skels at `/usr/share/fastrpc_test/v68` — and it
passed. So **no compose step is needed.** The plan's outcome-B delta assumed
Vagus would have to hardlink or copy the system shells in beside the uploaded
skel and re-run that whenever an OTA replaces either input. It does not: two
independent binds work, because the loader searches a *path list*, not a
directory.

That kills the plan's stated cost for outcome B (Phase 5's "re-compose when the
system shells change", and the OTA-staleness hazard behind it).

`libcdsprpc`'s default list has an entry the system image never populates —
`/usr/lib/rfsa/adsp` — which is a natural mount target for the store, leaving
the existing `/usr/lib/dsp` bind exactly as it is. **Unverified for QNN
specifically:** it follows only if QNN's skel lookup goes through
`apps_std_fopen_with_env` like the shell lookup does. Phase 6 must confirm it
with a real QNN load rather than inherit it from this result.

## Result 2 — `dsp: true` grants no device access, and cannot work without it ❌

Same composed mounts as the passing variant B, varying only
`DeviceCgroupRules`. `/dev` is bound in every case (Vagus binds it
unconditionally), so this isolates *access* from *visibility*.

| Rules granted | Result |
|---|---|
| none — **what `dsp: true` emits today** | `ERROR 0x68: memory alloc failed`, exit 3 |
| `c 10:263` (`fastrpc-cdsp`) + heap | `ERROR 0x72`, session never opens, exit 3 |
| `c 251:0` (`dma_heap/system`) only | `ERROR 0x72`, exit 3 |
| `c 10:264` (`fastrpc-adsp`) + heap | `ERROR 0x72`, exit 3 |
| **`c 10:262` (`fastrpc-cdsp-secure`) + `c 251:0`** | **`Sum = 499500`, 3/3 PASS, exit 0** |

Two things follow.

**The mount is not sufficient.** With no rules it fails before fastrpc is even
reached, at the DMA-heap allocation. `dsp: true` as written in PR #29 (open,
unmerged) binds libraries the container is then not permitted to use. The fix
belongs in that PR, before it lands. Phase 5 has to emit
device rules as well as a mount — `Vagus.Addon.Devices.cgroup_rules/3` already
stats paths at create time and decodes `st_rdev`, so it is the seam to reuse,
not to reinvent.

**The node is `/dev/fastrpc-cdsp-secure`, not `/dev/fastrpc-cdsp`.** Granting
the obvious-looking one fails identically to granting nothing relevant. The
naming is a trap: "secure" is the channel, orthogonal to the signed/unsigned PD
the `-U` flag selects (these runs used the default unsigned PD).

## Result 3 — the device numbers are per-boot, not per-target ⚠️

`fastrpc-*` are misc devices (major 10), so their minors are dynamically
allocated. Measured on the two `dragon_q6a` boards on the same day:

| node | .58 | .87 |
|---|---|---|
| `fastrpc-cdsp-secure` | 10:**262** | 10:**260** |
| `fastrpc-cdsp` | 10:263 | 10:261 |
| `fastrpc-adsp` | 10:264 | 10:264 |
| `dma_heap/system` | 251:0 | 251:0 |

A hardcoded `c 10:262 rwm` passes this gate on .58 and silently fails on .87.
The rule must be derived by stat-ing the node at container-create time.
`dma_heap/system`'s major is in the dynamic range too, so it gets the same
treatment despite matching here.

`Vagus.Addon.Devices` already carries a comment warning that a rule is a device
number and not a path — this is that hazard arriving for real.

## Consequences for the plan

1. **Phase 0 answers B**, but the delta is smaller than the plan budgeted: two
   binds, no compose step, no OTA re-compose hazard.
2. **Phase 5 grows a requirement the plan did not have**: `dsp: true` must emit
   device cgroup rules for `/dev/fastrpc-cdsp-secure` and
   `/dev/dma_heap/system`, resolved at create time.
3. **`dsp: true` is non-functional as currently written**, independently of the
   missing skel. PR #29 is still open, so the gate caught it before it shipped
   — which is the outcome a gate exists for. It answered a design question and
   found a bug on the way.
4. **Phase 6 still owes a QNN-level run.** This gate proves the fastrpc
   mechanism and the layout; it does not prove QNN's skel lookup uses the same
   search path, and it says nothing about silent CPU fallback.
