# App lifecycle

Everything that installs, starts, stops, restarts, updates, watches and
removes apps and Home Assistant Core goes through one Kubernetes-shaped
reconciliation model: desired state is stored, observed state is derived, and
controllers close the gap. This page is the vocabulary for that model. It
describes the design the `redesign/app-lifecycle` branch is building toward,
not code that exists yet; each change on the branch keeps it current.

The HTTP wire toward Core is unchanged: routes stay `/addons`, keys stay
`addon`, job names keep their upstream names. Only internal names say "app".

## Resources

A resource is one `%Vagus.Resource{}`. App is the main kind; an Update, a
Backup hold and each Services or Discovery entry an app publishes are others.

| Field | Purpose | Persisted |
|---|---|---|
| `kind`, `name` | Identity, and the store key | yes |
| `uid` | Tells a re-created resource from its predecessor of the same name | yes |
| `generation` | Counts spec changes; status records the generation it observed | yes |
| `spec` | Desired state | yes |
| `status` | Observed state: conditions, the running instance, failure counts | no |
| `progress` | Phase of an Update or Backup | yes |
| `finalizers` | Cleanup still owed before the resource may disappear | yes |
| `owner_refs` | The resources this one belongs to and is collected with | yes |
| `managed_fields` | Which writer owns which spec path | yes |
| `deleting?` | Deletion was requested; finalizers are pending | yes |

The central rule: `spec` is persisted, `status` is derived and never reaches
flash. After a reboot every status is rebuilt by observation, so nothing
stale is believed. Failure counts are status, so restart budgets reset then.

`progress` is the one exception. The phase of an Update or Backup is the only
record that it is, say, rolling back; lost at a reboot, the update would
apply the new version again. Only that kind's own controller writes it.

Core is not a separate mechanism. It is a resource of kind App named
`homeassistant` with different lifecycle settings (table below).

## The store

`Vagus.Resource.Store` is the single writer of every resource.

- The ETS tables belong to a separate process, `Vagus.Resource.Tables`,
  which names itself heir and gives them to the store. A read is a plain ETS
  lookup: it never enters a mailbox and it survives a store restart. With
  the store absent, reads work and writes exit.
- One file, `/data/vagus/resources.json`, holds the persisted fields. It is
  rewritten only when one of them changed, so status churn costs no flash
  writes: temp file, fsync, rename, directory fsync.
- Kinds are static and given to the store when it starts
  (`Vagus.Resource.Kind`): the validators that admit a spec, and the hooks
  that carry the kind's own shapes through JSON. The file is loaded before
  the store's start returns. A missing file is an empty store; one that
  cannot be read or parsed, has another version, or holds a kind or atom this
  build does not know fails the start, because loading it as empty would
  read as "nothing installed".
- A write goes to flash, then to ETS, then to subscribers. A reader never
  acts on desired state a reboot would take back. A store that dies between
  the first two leaves readers behind flash; its replacement re-reads the
  file and announces the difference.
- `managed_fields` gives each spec path one owning writer; a write to a path
  someone else owns is a conflict. An Update claims its app's `version` this
  way, so a user's write to it mid-update is refused instead of raced.
- `Store.commit(ops)` applies writes to several resources all or none,
  persists once and notifies once.
- The store keeps one in-memory operation claim per app. A command takes it;
  a second mutating command on that app fails as busy. The claim ends when
  its holder releases it or dies, and outlives a store restart.
- A kind has one owner, the only writer of its `progress` and of status
  outside conditions. Every writer declares the condition types it owns, and
  a type has one writer.
- `Vagus.Resource.Watch` is a duplicate-key `Registry`, so subscriptions
  outlast a store restart. They are by object, kind or owner:
  `{:object, kind, name}`, `{:kind, kind}`, `{:owner, kind, name}`. ETS is
  written before the notification is sent, so a woken subscriber reads a row
  at least as new as the change.

## Controllers and runtimes

A controller implements `Vagus.Resource.Controller` for one kind. Its work
is in three parts, which keeps the decision a pure function a table can test:

- `observe/2` reads the outside world (the container engine, other
  resources) and writes nothing.
- `reconcile/2` is a pure function of (resource, observation). It returns a
  verdict and a list of effects: store writes, actions, timed re-queues.
- `act/3` performs one action, such as creating or stopping a container. It
  is idempotent against observation, so the pass after a crash carries on.

The other callbacks are declarations: `kind/0`, `condition_types/0`, and
optionally `validate/1` (admission), `references/1` (resources whose changes
concern this one), `priority/1` (queue order), `retention/0`,
`owned_conditions/0` and `finalize_after/0`. One controller owns a kind and
writes its verdict; others attach and write only the conditions they declare.

Each controller has its own `Vagus.Resource.Runtime`, so a wedged controller
blocks no other and several can work one kind. The runtime keeps a queue
keyed by resource with at most one step in flight per key; a change arriving
mid-step marks the key dirty and it runs again. Steps run in tasks. The
effects between two actions are grouped into one commit, so a crash can fall
between a commit and an action but never inside a group.

Controllers are level-triggered: they act on what they observe, not on the
event that woke them, so a missed event is repaired by the next observation.
The engine's event stream is lossy, and that is the drift a resync exists
for: a gap in the stream (signalled after every reconnect), a runtime start
and a five-minute timer each trigger one filtered container list.

`Vagus.Resource.Lanes` holds a counting semaphore per action class: pulls 1,
engine calls 4. Only action tasks count, so a waiting app holds nothing. A
pull runs in a keyed pull worker whose state `observe` reads; it never
occupies the app's queue slot, and a stop during a pull cancels it.

While the host is shutting down every runtime rests and writes nothing;
otherwise the containers the shutdown stops would be read as crashes. While
the engine is unreachable the verdict is Progressing with reason
`:engine_unavailable` and no failure is counted: every boot starts that way.

```
Vagus.Resource.Supervisor        :rest_for_one
├─ Tables                        owns the ETS tables
├─ Watch                         Registry, duplicate keys
├─ Store                         single writer, persistence
├─ Lanes                         action semaphores
└─ Controllers.Supervisor        :one_for_one
   └─ one per controller         :one_for_all
      ├─ Task.Supervisor
      └─ Runtime
```

Each pair is `:one_for_all` because steps are `async_nolink` tasks: one in
flight would otherwise outlive its runtime, and the replacement could start a
second action for the same key. There is no per-app process.

## Verdicts

`reconcile/2` returns `{%Verdict{} | :no_verdict, effects}`. A
`Vagus.Resource.Verdict` holds a condition for every type the controller
lists in `condition_types/0`, never a subset. `:no_verdict` is for a pass
with nothing to report.

Status is not an effect. Only the runtime writes status, from the verdict, in
the same commit that marks the generation observed, so a generation cannot be
marked observed beside a condition left over from the previous one. The
store rejects a condition type its writer does not own.

## The App kind

An App's spec holds `config` (the parsed manifest), `version`, `options`,
`settings`, `ingress_port`, `run`, `restart_counter`, `start_counter`,
`holds` and `lifecycle`. The app should run when `run` is true and `holds` is
empty. `lifecycle` is what tells the three app types apart.

### Lifecycle settings per app type

| Field | Ordinary app | Core | Native broker |
|---|---|---|---|
| `backend` | `:container` | `:container` | `:native` |
| `container_name` | `app_<slug>` | `homeassistant` | n/a |
| `on_stop` | `:remove` | `:keep` | n/a |
| `reuse` | `:never` | `:fingerprint` | n/a |
| `engine_restart` | none | `unless-stopped` | n/a |
| `restart_policy` | from `watchdog` | crash-loop rule | from `watchdog` |
| `readiness` | running / healthcheck | `/manifest.json`, 600 s | process alive |
| `stop_grace` | engine default | image `S6_SERVICES_GRACETIME` + 20 s | n/a |
| `hooks` | none | port migration, safe-mode, http-config refresh, socket unlink | none |
| `boot` | `auto`/`manual` | `always` | `auto` |
| `wave` / `wave_wait_ms` | from `startup` | 40 / 120 000 | from `startup` |
| `token` | minted per create | the Supervisor token | none |
| `backup` | per manifest | excluded | native rule |

Core keeps the container name `homeassistant` because the previous firmware
must still find Core after a revert; only apps become `app_<slug>`. A lower
`wave` starts first: an app waits while an earlier wave is still progressing,
for at most its own `wave_wait_ms`, then starts anyway.

### Start sequence and gates

A gate is a condition another controller sets before the App may proceed.

1. Pull the image, in the pull worker.
2. Create the container, minting the token into its environment.
3. Status publishes the instance: container id, address, token.
4. Gates `:auth_ready` and `:ingress_ready` must name that instance id; a
   condition left from a previous instance opens nothing.
5. Start the container and wait for readiness, as `readiness` defines it.
6. Gate `:dns_ready`, then Ready.

The invariant: a container never runs before auth knows its token. The token
is never written to flash; after a restart it is re-read from the engine.

Four controllers attach to the App kind, each with its own runtime:

- AuthIndex owns `:auth_ready` and the token table that API auth reads.
- Dns owns `:dns_ready`.
- Ingress owns `:ingress_ready`, ingress sessions and the panel push to Core.
- Publications turns Services and Discovery entries into resources owned by
  the publishing app.

### Wire state

| Internal condition | Wire `state` |
|---|---|
| Ready | `started` |
| Container running but not Ready | `startup` |
| Failed | `error` |
| No container and not Failed (stopped, held, pulling, creating) | `stopped` |
| Never observed | `unknown` |

## Deletion and collection

Deleting a resource only sets `deleting?`. Each controller with something to
clean up holds a finalizer and releases it when the cleanup is done; the
resource disappears when all are released. The App's own finalizer runs
after AuthIndex's, declared in `finalize_after/0`, so the token row is gone
before the container is touched; the rest run in any order.

Owned resources are collected through their declared `owner_refs`, never by
inferring ownership from a name: an uninstalled app's publications go with
it. One-shot kinds such as Update and Backup declare `retention/0`, a keep
count and then a TTL. Collection is an ordinary delete, so finalizers run.

## Clocks

The boards have no RTC, so wall time is for display only. Every stored
instant is a `%Vagus.Resource.Stamp{incarnation, at}`: a monotonic reading
and the incarnation it was taken in. An instant from another incarnation
reads as age zero, so a restart can lengthen a deadline but never skip one.

## Commands

| Command | Returns when | Background |
|---|---|---|
| install | image present and resource created, or the error | yes → `{job_id}` after admission |
| start | container running (healthy/unhealthy if it has a healthcheck), a permanent create/run failure, or 120 s (success) | no |
| stop | no container (or stopped, for `on_stop: :keep`) | no |
| restart, rebuild | as start, for the instance made for the new `restart_counter` | no |
| uninstall | resource gone | no |
| update | Update terminal | yes |
| Core start/restart/rebuild | Core Ready, or Failed | no |
| Core update | Update terminal | yes |

Every command writes desired state and waits for exactly one named condition;
it does no engine work itself. It holds the app's operation claim until that
condition resolves (`start` only until the container is created and run), and
a second mutating command on the same app is refused as busy: HTTP 400,
`Another job is running for job group addon_<slug>`. A `start` that reaches
120 s with its gates still closed returns success with state `startup`, as
upstream does.
