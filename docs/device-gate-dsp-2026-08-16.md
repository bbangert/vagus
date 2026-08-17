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
`/usr/lib/rfsa/adsp` — which makes a natural mount target for the store,
leaving the existing `/usr/lib/dsp` bind exactly as it is.

**Measured, not assumed.** Skels bound *only* at `/usr/lib/rfsa/adsp`, with
`DSP_LIBRARY_PATH` pointing somewhere else entirely and shells at
`/usr/lib/dsp`:

```
##### K: skels at /usr/lib/rfsa/adsp #####    ##### L: control, skels at /opt/skels #####
Sum = 499500                                   ERROR 0x80000406: Failed to compute sum
Max value = 999                                ERROR 0x80000406: Unable to create
[PASS] libcalculator.so                          FastRPC session on domain 3
exit=0                                         exit=3
```

The control is what makes this mean something: move the same files off the
search list and the skel-load code `0x80000406` comes back. So the default list
resolves **skels**, not merely shells, and `/usr/lib/rfsa/adsp` is a working
store target.

**Confirmed at QNN level too** — see Result 4.

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

## Result 4 — a real QNN graph ran on the DSP from the store path ✅

Everything above is fastrpc's loader. This is QNN's, and it is the result the
plan's defining risk rests on.

Built for the occasion, since the SDK ships no runnable model: the example
`qnn_model_8bit_quantized` (an InceptionV3 conv+relu slice) cross-compiled to
aarch64, run by the SDK's own `qnn-net-run` against `libQnnHtp.so` in a
container. The **only** source of the skel was a directory bound at
`/usr/lib/rfsa/adsp` — exactly where `Manager.dsp_mount/1` binds the Vagus
store. Device rules were the measured minimum from Result 2.

```
##### A: skel at /usr/lib/rfsa/adsp #####      ##### B: control, nothing stored #####
Composing Graphs                                Device Creation failure
Finalizing Graphs                               EXIT=11
  Graph Optimizations      (12640 us)           (no output tensor)
  Graph Sequencing for Target (940 us)
  VTCM Allocation           (269 us)
  ====== DDR bandwidth summary ======
  write_total_bytes=739328 read_total_bytes=309248
Executing Graphs
Finished Executing Graphs
EXIT=0
--- outputs ---
InceptionV3_InceptionV3_Conv2d_1a_3x3_Relu_0.raw
```

VTCM allocation and a DDR-bandwidth summary are Hexagon-side facts — they do
not exist for a CPU run — and the graph both prepared and **executed**,
writing a real output tensor.

**This also disposes of the silent-CPU-fallback worry on this path.** There is
no quiet degradation to detect: with `--backend libQnnHtp.so` and no skel, QNN
fails at `QnnDevice_create` and exits 11. Removing the skel does not make the
workload slow, it makes it stop. Silent fallback remains a hazard for
*frameworks* that wrap QNN with a CPU backend (a TFLite delegate will fall
back); it is not one for the layout this feature ships.

### Two traps worth recording

**`libQnnHtpV68Stub.so` has a `NEEDED` of `libcdsprpc.so` — with no `.1`.**
Shipping only the sonamed `libcdsprpc.so.1` makes the stub fail to load, and
the symptom is a bare `Device Creation failure` with **no DSP-level error at
all**, at any log level. That is indistinguishable from "no skel" until you
read the stub's `NEEDED`. An add-on image must carry the unsuffixed name.

**Offline-prepared context binaries did not load** (`Create From Binary
failure`, exit 16), with and without `O`/`vtcm_mb`/`pd_session` set. On-device
preparation from the model `.so` worked first time. Unresolved, and out of
scope — it is a property of the hand-built artifact and of offline/SoC
matching, not of anything Vagus mounts. Recorded so the next person does not
read it as a Vagus failure.

## Result 5 — the whole thing, through Vagus, on deployed firmware ✅

Everything above was measured with hand-written container configs. This is the
shipping path: firmware built from this branch and OTA'd to .58 (0.5.1 →
0.6.1), and **every DSP mount and device rule below was taken verbatim from
`Manager.build_spec/2`** rather than written by hand.

`Vagus.DSP` on the board, before anything was stored:

```
root()          "/root/vagus/dsp"     <- the real path, not the /data symlink
expected_arch() "V68"
status()        :not_configured
```

**Negative, with the store absent** — `Manager.start/2` refuses before the
engine is ever called, and the message is the deliverable:

```
{:error, {:dsp_not_configured,
  "no DSP skeleton library has been supplied — upload one from the QAIRT SDK on the Vagus admin panel"}}
```

**Storing the real 10,240,928-byte skel** through `Vagus.DSP.store/1`:

```
filename  "libQnnHtpV68Skel.so"   <- derived from the file's own content
arch      "V68"     version "2.48.40"     size 10240928
store dir ["libQnnHtpV68Skel.so"]         <- exactly one file
cdsp_version()  "CDSP.HT.2.5.c3-00134-KODIAK-1"
```

**The spec Vagus then emits**, on this board:

```
/usr/lib/dsp    -> /usr/lib/dsp        ro=true system=true
/root/vagus/dsp -> /usr/lib/rfsa/adsp  ro=true system=true
rules: ["c 10:262 rwm", "c 10:263 rwm", "c 251:0 rwm"]
```

Those minors are **this** board's — the same code emits `10:260`/`10:261` on
.87. Resolution at create time is doing exactly the work Result 3 said it must.

**A QNN graph run in a container built from that spec:**

```
--- skel visible at the spec target ---
-rw------- 1 root root 10240928 libQnnHtpV68Skel.so      <- via Vagus's own mount
--- shells visible ---
example_image.so  fastrpc_shell_3  fastrpc_shell_unsigned_3
Composing Graphs / Finalizing Graphs
  Graph Optimizations (11371 us)   VTCM Allocation (240 us)
  ====== DDR bandwidth summary ======  write=739328 read=309248
Executing Graphs
Finished Executing Graphs
EXIT=0
--- output tensor ---
InceptionV3_InceptionV3_Conv2d_1a_3x3_Relu_0.raw
```

**OTA survival.** A second OTA, then `wall_clock` = 124 s confirming the board
really rebooted rather than no-op'd:

```
status() {:configured, %{..., stored_at: ~U[2026-08-17 00:20:42Z]}}
```

`stored_at` is the **pre-OTA** timestamp, so this is the same file rather than
a re-created one — which is the whole reason the store lives on `/data`.

**`rpi3_64` regression**, also OTA'd (.149):

```
{root: nil, expected_arch: nil, status: :unsupported, cdsp_version: nil}
ssh_facts()  {:ok, "ed25519", "SHA256:M2w00x…"}
```

`cdsp_version/0` returning `nil` rather than raising is the case worth naming:
that board has no `cdsp` remoteproc for the sysfs walk to find. The SSH section
still resolves, so the page renders 200 rather than the 503 a degraded
`SSHAccess` produces. Core, ESPHome, SSH and matter-server all running on both
boards afterwards.

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
4. ~~**Phase 6 still owes a QNN-level run.**~~ **Delivered — Result 4.** A real
   QNN graph prepared and executed on the DSP with the skel supplied only from
   `/usr/lib/rfsa/adsp`, and the no-skel control failed outright rather than
   degrading. What Phase 6 still owes is the *Vagus-mediated* path: the same
   thing driven through the panel upload and `dsp: true` on deployed firmware,
   plus OTA survival and the `rpi3_64` regression.
