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

---

## A `host_network` add-on's address is decided, not assumed

**Upstream:** `supervisor/docker/app.py`'s `ip_address` returns the `hassio`
bridge gateway for any `host_network: true` add-on, unconditionally. Ingress
and the watchdog both consume that one property.

**Vagus:** connects to the ingress port on loopback and uses it if something
is listening; otherwise the gateway (`Vagus.Network.host_network_ip/1`).

**Why upstream's rule cannot simply be adopted.** The two addresses are not
interchangeable *to the add-ons*, and each of the two host-network add-ons in
this fleet needs a different one — both device-measured:

| add-on | `127.0.0.1:<port>` | gateway `172.30.32.1:<port>` |
|---|---|---|
| ESPHome | listening → **200** | listening → **403** |
| Music Assistant | **econnrefused** | listening → serves |

ESPHome listens on `0.0.0.0` and refuses anything that did not arrive on
loopback. That was reproduced with and without the supervisor-anchor source
bind, with `Host` rewritten, and with `X-HA-Ingress`, `X-Ingress-Path`,
`X-Hass-Source` and `X-Forwarded-For` set — only the peer address unlocks it.
Music Assistant binds `0.0.0.0` for its LAN UI and streams but its *ingress*
port to the gateway alone, deliberately keeping ingress off the LAN.

So gateway-only would have fixed Music Assistant and broken ESPHome.

**Why upstream never has to choose.** Its Supervisor is a container on the
bridge, so loopback is that container's own and is not an option; the gateway
is the only address it can offer. Vagus's supervisor is the host BEAM process,
so loopback is genuinely available and is strictly more local. This divergence
exists because Vagus's supervisor is host-networked, not because upstream is
wrong.

**Only a connection-level failure falls back.** An add-on answering 403, 404
or 500 has connected, and that status is its answer — not evidence of a wrong
address. Retrying such a response elsewhere would mask real add-on errors.

Deliberately uncached: a refused loopback connect costs a syscall with no
network hop, while a cached answer goes stale the moment an add-on rebinds,
and a stale answer here is a 502 for the whole panel.
`Vagus.Addon.Watchdog.Probe` uses the same helper — a watchdog that disagreed
with the proxy would probe a live add-on dead and restart-loop it.

## `dsp:` — a config key, two host mounts, and an operator setup step, none with upstream precedent

This is the largest divergence in the ledger, and it is three at once: a schema
key upstream does not have, host mounts of vendor accelerator libraries
upstream has no analogue for, and a **post-install step a human must perform**
— something upstream's add-on model has nowhere to put.

**Upstream:** no equivalent. `_SCHEMA_ADDON_CONFIG` has no accelerator key, and
the Supervisor never host-mounts vendor runtime libraries into an add-on. The
closest thing in spirit is `kernel_modules`, which exists for the same reason
this does — a payload that must match the running system image and therefore
cannot be baked into an add-on image.

**Vagus:** `dsp: true` grants an add-on access to the Qualcomm Hexagon DSP via
two read-only binds and two device cgroup rules.

**Why it cannot be an add-on image instead.** Two payloads, two owners:

| payload | owner | why it cannot live in the add-on image |
|---|---|---|
| fastrpc shells (`/usr/lib/dsp`) | system image | must match the CDSP firmware — the shell embeds `cdsp.mbn`'s `QC_IMAGE_VERSION_STRING` verbatim, and an OTA moves both together |
| `libQnnHtpV<NN>Skel.so` (the store) | **the operator** | Qualcomm does not permit redistributing it |

The second row is the unusual part and the reason for the setup step. Nothing
Vagus or an add-on author ships may contain that file, so the only lawful path
is for the operator to fetch it from the QAIRT SDK themselves. The Vagus admin
panel takes the upload — chosen because it is already the admin-gated page an
operator visits for post-install setup (SSH access), and its gate is *stronger*
than the Supervisor API's supervisor-only.

**Why two mounts and not one composed directory.** `libcdsprpc.so.1` resolves
both shells and skels along a built-in path *list*
(`/usr/lib/dsp/cdsp;/usr/lib/dsp/adsp;/usr/lib/rfsa/adsp;/usr/lib/dsp`), so
they need not share a directory. The store binds at `/usr/lib/rfsa/adsp` — on
that list, and never populated by the system image, so the two binds cannot
collide. Composing a directory was the alternative and would have meant
re-composing whenever an OTA replaced the shells under a store the operator
never touched.

**Why device rules are part of the flag.** The binds alone reach nothing.
Vagus binds the whole host `/dev` into every container, so the fastrpc nodes
are *visible* without any grant — but visibility is not access, and without
rules the container dies at `ERROR 0x68: memory alloc failed` before fastrpc is
reached. Measured minimum: `/dev/fastrpc-cdsp-secure` and
`/dev/dma_heap/system`. Note **not** `/dev/fastrpc-cdsp` — granting that one
instead fails identically to granting nothing, because "secure" names the
channel and is orthogonal to the signed/unsigned protection domain. Both are
resolved by stat at container-create time, never as literals: they are misc
devices with dynamically allocated minors, measured `10:262` on one
`dragon_q6a` and `10:260` on another the same day.

**Why a missing skel fails the start rather than degrading.** Both mounts carry
`system: true`, so `ensure_mount_sources/1` never creates them. An empty bind
means direct QNN dies at device creation rather than degrading — confirmed on
device, see below; only a framework that wraps QNN with its own CPU fallback
would instead run the whole session silently on the CPU. `ensure_dsp_store/1`
turns the refusal into a sentence naming the panel; the engine remains the
backstop.

**Inert on `rpi3_64`**, where `:dsp_root` is unset — `Vagus.DSP.status/0`
reports `:unsupported`, the panel section says so and offers no form, and no
mount or rule is emitted.

All of the above is measured, not reasoned: see
[`device-gate-dsp-2026-08-16.md`](device-gate-dsp-2026-08-16.md), including a
real QNN graph preparing and executing on the DSP with the skel supplied only
from the store path, and the no-skel control failing outright.

**Not machine-checked by `container_fingerprint_test.exs`.** Its
`@vagus_only_mounts` ledger compares against a fixture captured from a real
Supervisor add-on, which has no `dsp:` — so these two mounts never appear in
that spec and cannot be registered there without failing its "each declared
divergence is still real" assertion. They are ledgered here instead.

---

## Cookie-only Erlang distribution, on a LAN, off by default

`Vagus.Dist` can take a board's BEAM distributed at runtime — an agent with the
SSH access it already has runs one function call and gets a node name plus a
cookie back, with no firmware build and no OTA. That capability ships in every
release. Nothing enables it: there is no gate file, no config flag and no
supervised process, so a board is `:nonode@nohost` until someone calls
`enable/0` over SSH, and it is `:nonode@nohost` again after the next reboot.

`enable/0` is idempotent by record. The session it produced is held in the
`:vagus_dist` ETS table — created at application start, owned by the
application master's process, and seeded `:not_requested` so "nobody has asked"
is a value that is read rather than an absence that is assumed. Repeat calls
return the same node and cookie without touching `net_kernel` again. It is
memory only: a reboot drops it, which is what makes a reboot the off switch.

**This diverges from published guidance, not from upstream Supervisor.** Home
Assistant's Supervisor has no equivalent to diverge from — it is a Python
container. What is diverged from is the [EEF Security WG's position on
distribution](https://security.erlef.org/secure_coding_and_deployment_hardening/distribution.html):
cookie-only distribution over a LAN is stated to be insufficient. Not because
the cookie travels: the handshake is challenge-response over a digest, so the
secret itself is never put on the wire. The problem is everything after it —
without `inet_tls_dist` the session is unencrypted and unauthenticated beyond
that first exchange, so there is no protection against a man in the middle, and
epmd hands out the node's name and port to anyone who asks. Recording it here
because "we accepted the risk" is not an argument, and a divergence nobody wrote
down becomes a surprise later.

**What is done about it instead.**

*Nothing persists, so a reboot is the off switch.* An earlier version gated this
on a cookie file at `/data/vagus.cookie`, brought distribution up unattended at
boot, and had a `disable/0` that deleted the file and rebooted. Every hazard in
that design belonged to the file rather than to distribution: it had to be
mode-checked, validated, mint-or-adopted, guarded against symlinks, and refused
when corrupt — and a bad one crash-looped the board into a firmware rollback.
Adopting a malformed one once produced a live node with the cookie `:''`, which
is unauthenticated root-equivalent LAN access.

Holding no state deletes that whole class. A broken `enable/0` now fails one
call for one operator, and there is nothing on disk for the next boot to act on.
It also removes any need to stop distribution in place — which meant stopping
`net_kernel`, killing epmd, and threading each of those failures back without
ever leaving a node alive under a secret already deleted. A reboot does all of
it, correctly, and this is a test mode toggled a handful of times in a board's
life. The cost is that the mode does not survive a restart, which is the
intended behaviour rather than a limitation.

*The cookie exists nowhere on disk.* It is 32 bytes of
`:crypto.strong_rand_bytes/1`, minted once per boot, applied with
`:erlang.set_cookie/1` and returned by every subsequent `enable/0`. Nothing
writes it to storage; the only copy outside the VM's own state is the ETS row,
which dies with the VM.

OTP does create `$HOME/.erlang.cookie` (0400) when `net_kernel` starts, and that
file survives a reboot — but it never holds the cookie that authenticates
anything. MEASURED on OTP 29: `net_kernel.start` mints its own random value and
writes *that*, `set_cookie/1` updates the VM only and leaves the file untouched,
and a second run reuses the stale file and is again overridden. The residue is a
value that was live for the microseconds before `set_cookie/1` ran and was never
used to authenticate a connection.

A live node whose record was lost is recovered, not refused. MEASURED on host:
stopping and restarting the `:vagus` app destroys the ETS table — its owner is
the application master — while `net_kernel` belongs to `:kernel` and stays up,
still using the cookie `enable/0` minted. Refusing there would lock an operator
out of a board that is distributed on the LAN right now, so `enable/0` re-reads
the cookie the node is actually using and records it again. Nothing else on a
Nerves board starts distribution, so the node being recovered is always one
this module started.

That is also why `status/0` reports `enabled?` and `alive?` separately. They
can disagree for exactly the window above, and a status that reported only the
record would call such a board "off" while it answered on the LAN.

`:erlang.set_cookie/1` cannot run before `net_kernel` — it raises
`:distribution_not_started` — so the ordering is: **start `net_kernel`, call
`set_cookie/1`, then read `get_cookie/0` back and stop the node if it
disagrees.** That read-back is the module's one safety property; a node alive
under a cookie the caller was not handed is the single state it must never
leave behind. An earlier version also pre-seeded `$HOME/.erlang.cookie` with our
value to close the window before `set_cookie/1` ran. That window was never a
security problem — a cookie OTP invented is unknown to everyone, which is
strictly more secret than ours — and the read-back already covers the
correctness case, so the pre-seed is gone.

The release-baked `releases/COOKIE` never applies either. That value used to be
`vagus_platform_cookie`, derived from a name in a public repo; it is now random
per build as defence in depth.

*The listener binds `0.0.0.0`, deliberately.* An earlier version pinned it to a
single VintageNet-managed interface, and this doc credited that with keeping
add-on containers out. **That was false**, and this repo already documents why
in `Vagus.API.SourceGuard`: a packet from a `hassio`-bridge container addressed
to the board's own LAN IP is delivered **locally**, so it never traverses
`FORWARD`, and `Vagus.Network.Nat` writes only the `nat` table — no `filter`
rule drops it. A container that dialled the LAN address reached the pinned port
anyway. Measured on a dragon_q6a, not reasoned: from inside a running add-on,
both 4369 and the dist port were reachable.

So the pinning bought a narrower listener and an interface-ranking apparatus to
choose it, against a surface the cookie already protects. It is gone. A board
with this mode on is a board whose operator is on the LAN and owns the exposure;
what they are handed by `enable/0` is the only thing that opens it.

*Predictable ports.* 4369 plus 9100-9105, pinned, so the range can be firewalled
at the LAN edge rather than discovered. Nothing is advertised: there is no mDNS
record, and `enable/0` hands back the node name, cookie and port range over the
SSH session that called it.

**What has not been done.** TLS distribution (`inet_tls_dist`) is the hardening
that would actually close this: `-proto_dist inet_tls`, ssl in the boot script,
`-ssl_dist_optfile` and a certificate per board. It is rated moderate overhead
and is a realistic later step rather than a blocker for a dev fleet on a
trusted LAN, and it is filed as such. Until then, treat an enabled board as
equivalent to an unauthenticated root shell open to its LAN segment, and reboot
it when the work is done.
