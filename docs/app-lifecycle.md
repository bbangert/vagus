# App lifecycle

How Vagus holds installed apps and runs every operation on them. Read it
beside `apps/vagus/lib/vagus/app.ex` and `apps/vagus/lib/vagus/app/`. The
rules mirror upstream Supervisor's apps where they can; where they do not,
the reason is here or in [`divergences.md`](divergences.md).

The model in one line: **one process per app holds every fact about it and
runs every operation on it; everything else asks that process, or reads a
key it registered.** There is no second holder of app state, no lock, and
no outside party that stops and starts an app on its behalf.

Commands, settings and questions from outside the subsystem go through
`Vagus.App`, which returns plain maps and results, never a pid. Three hot-path
readers skip the facade and read `Vagus.App.Directory` directly:
`Vagus.Runtime.Events` (to route a container event to its app's pid),
`Vagus.DNS` and `Vagus.Ingress` (to resolve a name or an ingress token without
a call).

---

## The tree

```
Vagus.Supervisor (one_for_one)
 ├─ … Vagus.Backups, Vagus.Discovery.Push, Vagus.Addon.Backend.Native.Supervisor
 ├─ Vagus.App.Supervisor (rest_for_one, 5 restarts / 30 s)
 │   ├─ Vagus.App.Directory      Registry, unique keys
 │   ├─ Vagus.App.Instances      DynamicSupervisor, 10 restarts / 60 s
 │   │   └─ Vagus.App.Server     one :gen_statem per app, :transient
 │   └─ Vagus.App.Orchestrator   GenServer; boot and shutdown sequences
 └─ … Vagus.DNS, Vagus.Runtime.Events, Vagus.Ingress, Vagus.API.Supervisor,
      Vagus.Core.Supervisor
```

| Child | Started by | A crash takes down |
|---|---|---|
| `Vagus.App.Directory` | `Vagus.App.Supervisor` | every app process and the Orchestrator (`rest_for_one`): a lost registry orphans every registration made in it |
| `Vagus.App.Instances` | `Vagus.App.Supervisor` | every app process and the Orchestrator |
| `Vagus.App.Server` | `Vagus.App.Instances.ensure/1` | only itself; `:transient`, so an abnormal exit restarts it |
| `Vagus.App.Orchestrator` | `Vagus.App.Supervisor` | only itself and its boot task |

An app process whose file cannot be read or decoded, or whose rewrite
failed, returns `:ignore` from `init/1`, so it is not restarted and cannot
spend the DynamicSupervisor's restart budget: a retried start would only
fail again until the supervisor's intensity took every app down. The
facade's `ask_healing` tries again on the next request.

`Instances` has a wider restart budget than the tree so a few app processes
in an abnormal crash loop at runtime do not take the directory with them. A
bad file never reaches that budget.

An app process is started by the Orchestrator's `init/1` (one per saved
file), by `Vagus.App.install/2` for a new slug, or on demand by the facade
when an installed app has no process (`ask_healing`). A crashed app
process's containers keep running; its successor learns about them through
the Orchestrator (see `boot/2` outcomes).

`Vagus.App.Supervisor` starts after `Vagus.Addon.Backend.Native.Supervisor`
(a native app starts into it) and before DNS, the events stream, ingress,
the API and Core's subtree, all of which read apps. Because the top level is
`one_for_one`, a restart of the app tree does not restart those readers:
they hold no app state, and every lookup they make goes through the directory
at the moment of the request, so they see the new processes without
resubscribing.

`Vagus.Backups` sits outside the tree. It owns only the backup store's index;
the stopping, snapshotting and restoring are the app process's own
operations, called from the backup caller's process. `Vagus.Runtime.Events`
also sits outside: it routes each container event to `{:slug, slug}` in the
directory as the event is sent, and after every reconnect it sends each app
its container's state as the event it missed (a running container as
`start`, an exited one as `die`).

## The state machine

`Vagus.App.Server` runs `:handle_event_function` with four states:

| State | Meaning |
|---|---|
| `:new` | no file yet; a 60 s state timeout ends the process unless an install moves it out of `:new` |
| `:idle` | installed; takes any operation |
| `{:busy, op}` | an operation is running |
| `:shutting_down` | halted for a shutdown; refuses operations until `resume` |

The step an operation is on is deliberately not part of the state. A state
change replays postponed events and cancels the state timeout; both must
happen once, when the operation ends, not at every step.

**Admission** (`Vagus.App.Policy.admit/2`), in clause order:

| Command | `:new` | `:idle` | `{:busy, _}` | `:shutting_down` |
|---|---|---|---|---|
| `install` | taken | `:already_installed` | `:already_installed` | `:already_installed` |
| `halt` | `:not_installed` | taken | taken (pre-empts); `:busy` during a halt | no-op |
| `resume` | `:not_installed` | no-op | no-op | taken |
| anything else | `:not_installed` | taken | `:busy` | `:shutting_down` |

A busy app rejects rather than queues, as upstream's job groups do.

**Questions are answered in every state**, an operation in flight
included (in `:new`, as an app that is not installed). An unknown question
gets an error reply rather than crashing every app process that receives it.

**Settings writes and the app's own service and discovery posts** are taken
in every state from install on, an operation in flight included, so an app
mid-update can still post its discovery. Two windows refuse them: `:new`
(nothing to write before an install commits) and once an uninstall has begun
(`{:set, _}` is `:not_installed`, posts are `:unavailable`), because a write
then would bring the file back and a post would land for an app being
removed.

**Postponed while busy**: container events, the native broker's `DOWN`, and
the `:retry`, `:settled` and `:probe` timers. They are replayed when the
operation ends, against the facts the operation left.

### Operations and their steps

`(T)` is a task step, `(L)` a local step applied inside `Policy.next/3`,
`(S)` a step the Server runs inline and feeds back into `Policy.next/3`.
`port?` expands to `port` only for a dynamic ingress port with none
assigned; `start?` expands to the start steps only if the stop found the
container running (or, for a backup, the app wanted started).

| Op | Steps | Notes |
|---|---|---|
| install | `pull(T)`, `port?`, `commit(L)` | runs from `:new`; any failure replies and the process exits, leaving no file |
| start | `port?`, `mint_token(L)`, `start(T)` | `mint_token` is skipped for a native app; wanted becomes `:started` |
| stop | `stop(T)` | token and DNS keys dropped before the task; wanted becomes `:stopped` |
| restart | `stop(T)`, `port?`, `mint_token(L)`, `start(T)` | wanted unchanged |
| update | `pull(T)`, `stop(T)`, `commit(L)`, `start?`, `reclaim_image(T)` | pulls first, so a failed pull leaves the old container untouched |
| update with backup | `pull(T)`, `stop(T, strict)`, `snapshot(T)`, `commit(L)`, `start?`, `reclaim_image(T)` | a failed snapshot commits nothing and restarts the old version: `{:backup_failed, r}` |
| backup, cold | `stop(T, strict)`, `snapshot(T)`, `start?` | the reply is the snapshot's result, even if the restart fails |
| backup, hot | `exec_hook(T, pre)`, `snapshot(T)`, `exec_hook(T, post)` | each hook only if the config has one; `post` runs after a failed snapshot too; no container → hook skipped |
| backup, native | `snapshot(T)` | |
| restore | `stop(T, strict)`, `swap_data(T)`, `set_options(T)`, start steps if the backup says started | `set_options` skipped when the backup had none |
| uninstall | `stop(T)`, `delete_file(S)`, `remove_app(T)` | every key but `{:slug, _}` dropped before the stop |
| halt | `halt_stop(T)` | stop by name, no remove; never persists; ends in `:shutting_down` |

Update start failures: after a commit, a failed start runs
`rollback_config(L)` and the start steps again, replying
`{:rolled_back, cause}`; if that start fails too, `{:rollback_failed, r}`.
`reclaim_image` never fails the operation.

Uninstall's commit point is the file delete: once it succeeds nothing writes
the file again, so nothing that follows can bring the app back, and any later
failure ends the process. A failed delete fails the uninstall and puts the
ingress keys back, so the still-installed app's URL answers again. Discovery
DELETEs are queued before the stop, because Core reads a message before
acting on its DELETE.

`halt` pre-empts an operation, because a shutdown cannot wait out an image
pull: the running task is killed, the parked caller gets
`{:error, :shutting_down}`, and the halt runs. A halt during an install just
ends the process; nothing was written.

**A step that dies or overruns its deadline** becomes the outcome
`{:error, :died}` or `{:error, :timeout}`, handled on the same path as any
other failure. When that step touched the container (`start`, `stop`) its
state is unknown, so the one recovery is a `{:stop, :by_name}` cleanup step;
the operation then fails and the restart rule decides what happens next.

### The restart ladder and the probe

`Policy.restart?/2`: nothing restarts during a shutdown or for an app not
wanted started. A container app needs its watchdog flag and fewer than five
attempts; the wait is 0 s, then 10 s doubling (`Policy.backoff/1`). A native
app with effective boot `auto` is always revived, 5 s then every 30 s, with no
cap and no watchdog flag: it is the MQTT broker every other app leans on, and
nothing outside the BEAM restarts it.

Any start that is not a ladder retry (a user's start or restart, an
update, a boot start) zeroes the attempt count. A retry start keeps it until
the start has stayed up for 120 s (the `:settled` timer), so a container that
dies a second after each retry runs out. A `:retry` timer carries the
container id it was armed for; it is stale once an operation replaced that container. A clean exit restarts too,
as upstream's `watchdog_container` does for a `STOPPED` container it did not
stop itself, except a `startup: once` app's, which is its completion.

The URL probe (`Vagus.App.Probe`) runs every 120 s in its own task while the
app is idle, has a container, its watchdog flag is on and its config has a
`watchdog` URL. Two misses in a row (`Policy.strike/2`) count as one restart
on the same ladder; a probe that could not be run is `:skip`, never a miss.
With no attempt left the app reports `error` and the probe stops. An
operation never runs beside a probe: beginning one kills it.

After five failed restarts nothing else happens: wanted stays `:started` and
the app reports `error` until the user acts.

### `boot/2` outcomes

`Policy.boot/2` decides from what the app wants and whether its container
runs. The process reports `:managed` for a container it started and still
holds (a token, or a broker pid); otherwise the engine's answer, except that
a native app it does not hold is `false`: the engine knows nothing of an app
that runs in the BEAM.

| wanted | container | boot | Outcome |
|---|---|---|---|
| `:started` | `:managed` | any | `:none` |
| `:started` | running, not ours | any | `:start` — replaced under a fresh token |
| `:started` | stopped | `auto` | `:start` |
| `:started` | stopped | `manual` | `:demote` — wanted recorded `:stopped` |
| `:started` | `:unknown` | `auto` | `:start` |
| `:started` | `:unknown` | `manual` | `:none`: no engine answer never demotes |
| `:stopped` | any | any | `:none` |

A container running without this process's token is replaced whatever the
boot mode: the per-start token died with the process that minted it, so
nothing the container holds authenticates any more.

## The step runner and effects

The runner lives in `Vagus.App.Policy` as pure functions so every operation
is a table test. `Policy.plan/3` returns the run or why it cannot begin
(an update needs a version different from the installed one, whose schema
accepts the saved options).
`Policy.next(run, outcome, data)` applies one outcome (or `:begin`), runs
local steps in place, and returns new data plus effects that end in one
task step or in the operation's end. An outcome no clause plans for fails
the operation rather than raising.

The process (`Vagus.App.Server`) only spawns task steps and interprets
effects. The vocabulary is closed:

| Effect | What the Server does |
|---|---|
| `{:step, step}` | spawn-links the task with `Policy.task_input/2`, arms the step's deadline as a `state_timeout` |
| `{:reply, term}` | replies to the operation's caller; a success with an unsaved record becomes `{:error, {:persist, r}}` |
| `{:keys, add, drop}` | unregisters `drop`, registers `add` (a `{key, value}` item carries its value) |
| `:persist` | writes the app's file inline |
| `{:emit, state}` | pushes `Vagus.Core.Events.app_state/2` through `Vagus.Core.EventPusher` |
| `{:timer, name, ms, msg}` | arms a generic timeout |
| `{:cancel, name}` | cancels one |
| `:monitor_broker` | monitors the native broker's pid |
| `:delete_file` | deletes the file inline and feeds the result back to `Policy.next/3` |
| `:idle` | ends the operation |
| `:shutting_down` | ends a halt |
| `:exit` | stops the process normally, sending its replies |

`{:emit, _}` is produced by comparing the reported state before and after
each `next/3` or event, so Core hears once per change of the reported state;
a change that leaves it the same (a boot demote of a stopped app) emits
nothing. Container events and probe results go through
`Policy.on_event/2` and `Policy.strike/2`, which return effects from the same
vocabulary.

**Task steps vs local steps.** A task step touches the engine, disk or
network and runs in `Vagus.App.Steps.run/2`; it gets everything it needs as
input and reads no app state. Local steps (`mint_token`, `commit`,
`rollback_config`) are decisions applied inside `Policy.next/3`; minting a
token is the one impure act left in `Policy`. `delete_file` is planned like a
step but `Policy` only emits the `:delete_file` effect: the Server deletes the
file inline, because the uninstall's commit point must be acknowledged before
anything else runs.

**Deadlines.** Each task step has its own (`Policy.deadline/1`), re-armed
as a `state_timeout` at every spawn without a state change, so an operation
has no overall deadline and a facade call into one waits `:infinity`. Two
values carry a reason: `halt_stop` gets 40 s around an engine stop of 30 s,
so the engine kills a container that ignores SIGTERM and the step still
returns inside its own deadline; `swap_data`
gets as long as a snapshot because it removes the old data dir first, a walk
of the same size. The probe has its own 10 s deadline.

**`task_input/2` is built from the data current when the task is spawned**,
not from a copy taken when the operation began. Options saved while an
update pulls reach that update's start step. That is the defined boundary:
a write lands at the next step that reads it.

**The run record** carries `op`, `args`, the remaining `steps`, the current
`step`, `task` and `ref` of the running task, `from` (the caller),
`unsaved` (the reason of the last failed save, cleared by the next good one)
and `acc`, the operation's own memory: `old` (the config an update started
from, needed by every branch that rolls back), `was_running`, `cause`,
`result`, `cleaned`, and for a restore the `options_rev` it started at.

## The directory keys

`Vagus.App.Directory` holds keys only. A key's owner is the process that
registered it, so no entry can outlive its app, and a reader finds the app
without asking anyone.

| Key | Value | Registered | Dropped | Read by |
|---|---|---|---|---|
| `{:slug, slug}` | — | process start (its name) | process exit | the facade, `Vagus.App.Instances`, `Vagus.Runtime.Events` |
| `{:token, sha256}` | slug | `mint_token`, before the start task | before a stop or halt, when the container dies, after a failed start | `Vagus.API.Auth` and `Vagus.API.CoreProxy` via `Vagus.App.identity_for_token/1`, then `:identity` asked of the owner |
| `{:dns, name}` | IP | after a start that produced an IP | with the token | `Vagus.DNS`, from the value alone |
| `{:ingress_token, sha256}` | slug | at install, or at init from the file, if the config has ingress | before an uninstall's stop; follows the config at an update's commit or rollback | `Vagus.Ingress`, then `ingress_target` asked of the owner |
| `{:ingress_port, n}` | slug | dynamic ports only: at init from the file, or by the `port` step's outcome | with the config | the `port` step, to skip held ports |
| `{:service, name}` | slug | the app's `provide_service` post | its withdraw, or before an uninstall's stop | `Vagus.App.service/1`, `Vagus.App.services/0`, `Vagus.Mqtt.Broker.Provider` |
| `{:discovery, uuid}` | slug | a new `add_discovery` | its delete, or before an uninstall's stop | `Vagus.App.discovery/1`, ownership check in `delete_discovery/3` |

Tokens are keyed by hash, so the directory never holds one in the clear.
`Vagus.App.ask/3` folds "no key", "dead pid" and "directory restarting" into
`:absent`; auth fails closed on it. List routes ask every app at once with
`:gen_statem.send_request/4` under one absolute deadline (1 s), so a stuck app
costs the caller one deadline, not one per app. `Vagus.App.list/0` renders
an app that does not answer from its file with `state: :unknown` rather than
leaving it out: Home Assistant deletes the device of an app missing from
`GET /addons`.

A stopped app keeps its services and discovery: only its run keys go.

**Port collisions.** The `port` step picks a random port in 62000–65500 that
no app holds and nothing listens on at the gateway. The registration is the
arbiter: two apps that picked the same port cannot both register it, and the
loser's step outcome becomes `{:error, {:port_taken, key}}`, failing its
start. A saved port another app already holds at init is dropped and the
file rewritten; the next start picks a fresh one. A rollback never takes
back a port its commit dropped, since another app may hold it by then.

**DNS name collisions.** The name is the slug with `_` as `-`, lowercased
(`Policy.dns_name/1`), so `foo_bar` and `foo-bar` share one. Whichever app
registered first keeps it; the second is logged and runs without a record.
A host-network app has no record; a native app's is the supervisor address.

## The Orchestrator's sequence

`Vagus.App.Orchestrator` holds only the sequence in flight; the sequence
runs in a task. Every unit is idempotent, so a crashed boot task stops the
Orchestrator, and its restart simply boots again.

**`init/1`**, before any app process exists:

1. the staging sweep (`Vagus.App.Units.sweep/0`), only when `boot: true`
   and only once per VM. It must run before any app process and before the
   API tree can admit a backup or restore whose staging it would wipe; a
   later run would be the Orchestrator restarted under app processes that
   may be mid-backup;
2. the legacy import (`Vagus.App.File.import_once/2`);
3. one app process per saved file, so the tree is not reported started until
   every app process exists.

**The boot plan** (`handle_continue(:boot, _)`), skipped if a shutdown is in
flight:

1. the default native app (`:default_native_app`) is installed if missing,
   and on that fresh install recorded wanted `:started`;
2. gate `tree` (the rest of the application is up), then the `native`
   stage: native apps need no engine, so an offline boot still brings the
   broker up;
3. gates `engine`, `network` and `api` (`Vagus.App.Gates`): each check
   bounded by `gate_timeout` (10 s), retried every 5 s for 60 tries, then
   carried past with a warning. `api` exists because an app's s6 init asks
   `/addons/self/info` first and a refused connection exits it for good;
4. one engine listing of running app containers, taken right after the
   `engine` gate (`:unknown` if it fails) and carried through the stages;
5. the stages `initialize`, `system`, `services`, `core`, `application`
   (`once` apps join `application` but are not awaited). Each app gets
   `Vagus.App.boot_start/2` with its entry from the listing; each stage is
   awaited up to `stage_timeout` (120 s), then carried past. The `core`
   stage is `Vagus.App.CoreUnit.start/1`, which never creates Core;
6. `supervisor_update` with `startup: complete`, which Core takes as the
   Supervisor having finished starting.

**Cancel.** A shutdown pre-empts a boot only at a step boundary: before a
gate or a stage, or while a gate waits out its interval. A unit in flight is
never killed: Core's start may be midway through stop, remove, create and
start, and a killed one leaves Core absent, which no boot repairs.

**Shutdown** (`Vagus.App.Orchestrator.shutdown/2`, called by
`Vagus.Host.Shutdown`) runs in an unlinked task, so an Orchestrator crash
does not cut it short:

1. `halt` to every `application`-stage app at once;
2. Core stops (`Vagus.App.CoreUnit.stop/1`, which rides out a busy lifecycle
   lock for up to 60 s), within what is left of the caller's budget after
   setting aside the earlier group's bound (`app_stop_timeout` 35 s plus a
   5 s margin);
3. `halt` to every earlier-stage app at once.

Native apps keep running. A halted app keeps what it wants, so the next boot
starts the same apps.

**Resume.** After a shutdown that did not take the device down,
`Vagus.App.Orchestrator.resume/1` boots again; each halted app answers
`boot_start` with `:shutting_down`, and the facade sends it `resume`, which
applies the same boot rule.

**An app process that restarts** calls `Vagus.App.Orchestrator.up/1` from
its `init/1`; one created by an install enters `:new` without announcing, as
nothing has been installed to boot. After the Orchestrator has reached `:up`,
it inspects that app's container at once and sends `boot_start` with the
answer. While boot is still running the announcement is ignored: the process
is covered by its stage if that stage has not run yet, and otherwise stays
idle until the next boot or a user start (a running container keeps running,
unowned, until then). A correct replay would need the Orchestrator to know
which process a stage reached, and every attempt to infer it raced, so this
narrow window, a process crash inside the boot minute, is accepted instead.

**Once-per-VM guards.** Two `:persistent_term` flags survive any restart of
this tree: the sweep's `{Vagus.App.Units, :swept}`, and
`Vagus.Host.Shutdown.in_flight?/0`, which stops a restarted Orchestrator from
booting what is being stopped, starts a restarted app process in
`:shutting_down`, and stops the restart ladder of every app.

## Stated exceptions

The app process otherwise performs no action itself; these are deliberate.

- **Inline file writes.** Settings writes are written by the process before
  it replies (the process checks only that each key is a known setting; the
  router validates the values), and `:persist` and `:delete_file` run inline,
  because the reply must mean "on disk": a reboot right after a 200 keeps the
  change. The file is small, so the write does not hold the process up.
- **Postponed own-container events.** An event about the app's container
  while an operation runs describes a container the operation is replacing;
  it is handled once, after the operation, against the facts it left.
- **Each step reads current settings.** See `task_input/2` above.
- **Boot's saves are log-only.** A boot demote's save, and a boot start
  whose container started but whose save failed (`Vagus.App.boot_start/2`
  folds `{:persist, _}` to `:ok`), are logged: boot would otherwise report a
  running app as failed. A failed settings write is not: it replies `:error`
  and nothing changes in the process. Inside an operation a
  failed save is reported as `{:error, {:persist, reason}}` (the router's
  500), and the operation still completes, because the container already did
  what was asked. An install is the exception: an install that could not
  save its file has installed nothing, so it fails and the process exits.
  Every save writes the whole record, so a later good one clears the failure.
- **The options revision rule.** `Policy.put_options/2` bumps
  `options_rev` on every options write. A restore records the revision it
  started at and commits the backup's options only if it is unchanged: a
  write made during the restore was acknowledged to its caller and is newer
  than the backup. Revisions, not values, because a write of the very
  options the restore started from is still newer.
- **Strict vs tolerant stops.** A plain stop tolerates an engine error (a
  failing daemon must not keep a stop from completing; an absent container is
  success). A stop that a snapshot or a data swap follows is strict: a
  container still running would write under the tar or into the directory
  being replaced. A failed strict stop commits nothing, skips the snapshot or
  swap, and starts the app again if it should run.

## Behaviour changes

Against the lifecycle Vagus had before (one Manager driving apps from
outside, per-app locks, a separate Watchdog, separate Services and
Discovery owners, backups that stopped and started apps themselves), and
against upstream where noted.

- **Busy is a 400 with upstream's text.** An operation on a busy app is
  refused, not queued: `Another job is running for job group app_<slug>`,
  for update, the start/stop/restart/uninstall commands, backup and restore
  alike.
- **No per-app restart window; the ladder is the only bound.** Five attempts
  with backoff, zeroed by any non-retry start, and kept by a retry until it
  has stayed up 120 s. Upstream also throttles the watchdog
  to 10 restarts per 30 minutes; Vagus does not (ledgered in
  [`divergences.md`](divergences.md)).
- **No demote after five failures.** The app stays wanted started and reports
  `error`. The only demote left is boot's, for a `manual` app whose container
  is known stopped.
- **The default broker's stop survives a reboot.** It is wanted `:started`
  only on a fresh install; a user's stop is recorded and kept.
- **Unhealthy containers are restarted.** A `health_status: unhealthy`
  event goes on the ladder, as upstream.
- **DNS name collisions are refused**: the first holder keeps the name.
  Upstream's `PluginDns.add_host` replaces an existing entry for the name, so
  the newest wins.
- **Backups and restores are the app's own operations.** A busy app fails
  the whole backup (`{:busy, slug}`, the busy text); a restore aborts at the
  first app that fails. Restore wipes the data dir then renames the staged
  copy in, with no rollback, like upstream's wipe-then-extract: a failure
  between the two leaves an empty data dir and the caller retries. Hot
  backups do not pause the container, as upstream does not. A caller that
  dies mid-backup cannot leave a cold app stopped, since the app's own
  operation starts it again.
- **Staging** for backups is under `<data_root>/.backup-staging` (the root
  is 0700), outside
  every tree a `map:` key mounts into an app, because Vagus writes and
  removes there as root and would follow a planted symlink. A restore stages
  in a `.restore-<slug>-<n>` sibling of the app's data dir, so the swap is a
  rename on one filesystem. Both are swept only at the first boot of a VM.
- **`backup_not_stored`.** An update with a backup that succeeded but whose
  backup could not be stored is `{:error, {:backup_not_stored, reason}}`
  (500): the update stands, and the caller who asked for a backup hears it
  has none. A backup taken before an update that then rolled back is kept: it
  holds the version the user had.
- **`addons.json` is read once and never written.** See below.
- **A token of a stopped or uninstalled app is a 401**, since its key went
  before the stop.
- **A restarted app process replaces its running container** under a fresh
  token rather than attaching to it (see `boot/2`).

## Persistence

One JSON file per app, `<:app_files_dir>/<slug>.json` (`/data/vagus/apps` on
target). Only an app's own process writes its live file (the legacy import
writes the first set into a staging directory before any process exists),
through `Vagus.App.File.write/2`: a temporary opened exclusive and set to 0600 before
any content lands, then a rename, so no reader ever sees a partial or
world-readable file while the system runs. Nothing is synced to disk, so a
power cut right after the rename can still lose that write; the next boot
then sees the previous file, which is why every write carries the whole
record. It holds the ingress token.

| Persisted | Not persisted |
|---|---|
| `config`, `wanted`, `user_options`, `ingress_token`, `ingress_port` (dynamic only), and the settings `ingress_panel`, `watchdog`, `network` (ports), `boot`, `auto_update`, `protected` | the per-start API token, container id, IP, broker pid, last event, attempt and strike counts, services, discovery, `options_rev` |

The token lives only in the process: on flash it would outlive the container
it was minted for. Services and discovery are re-posted by the app (the
native broker's `Vagus.Mqtt.Broker.Provider` monitors the process and
publishes again into the next one). `options_rev` restarts at 0 with each
process; it only orders writes within one restore.

Loading never bricks a boot. `Vagus.Addon.Config.parse/1` re-validates the config; a file
it rejects, or one that is not JSON, is logged and its app process returns
`:ignore`. It is never taken for a slug with no file, which an install would
overwrite. Every other field decodes tolerantly to its default, except
`protected`, which falls back to `true` because it gates `full_access`,
`host_pid` and `docker_api`. A file whose ingress token had to be minted is
rewritten once by its owner, or each read would mint another and move the
ingress URL; if that rewrite fails the app is not started.

**The legacy import.** When the apps directory does not exist,
`Vagus.App.File.import_once/2` reads the single `addons.json` earlier
releases kept (`:legacy_addons_json`), writes one file per valid entry into a
sibling `.import` directory, and renames it into place, so an import cut
short is redone at the next boot rather than counted as done. An
`addons.json` that exists but cannot be read or has the wrong shape is an
error and no directory is created: an empty one would count as finished and
every app in it would be lost. The legacy file is never written, so a
reverted firmware boots from it exactly as it was at the upgrade; anything
changed since is not carried back.
