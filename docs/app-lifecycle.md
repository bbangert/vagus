# App lifecycle

Everything that installs, starts, stops, restarts, updates, watches and
removes apps and Home Assistant Core goes through one Kubernetes-shaped
reconciliation model: desired state is stored, observed state is derived, and
controllers close the gap. This page is the vocabulary for that model, on
the `redesign/app-lifecycle` branch; each change there keeps it current.

What exists so far is the generic machinery under `Vagus.Resource` (the
resource, the store, and everything in "Controllers and runtimes",
"Verdicts", "Clocks" and the generic half of "Deletion and collection"),
"The engine layer" a controller will act through, and what the App
controller will be made of: the lifecycle profiles, the spec with its
admission and codec, the container config, the failure table, the token
table and the engine observer. The rest is the design they are built for
and has no code yet: the App controller and the controllers attached to
its kind, Core's container config and hooks, Update and Backup, and the
commands. No controller is configured, only the token table of the new
parts runs, with nothing in it, and apps and Core still run on the code
this replaces.

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
`homeassistant` with the Core lifecycle profile (table below).

## The store

`Vagus.Resource.Store` is the single writer of every resource.

- The ETS tables belong to a separate process, `Vagus.Resource.Tables`,
  which names itself heir and gives them to the store. A read is a plain ETS
  lookup: it never enters a mailbox and it survives a store restart. With
  the store absent, reads work and writes exit. While the whole subtree is
  being replaced the tables are gone too, and a read raises (see
  "Commands").
- One file, `/data/vagus/resources.json`, holds the persisted fields. It is
  rewritten only when one of them changed, so status churn costs no flash
  writes: temp file, fsync, rename, directory fsync.
- Kinds are static and given to the store when it starts
  (`Vagus.Resource.Kind`): the validators that admit a spec, the hooks
  that carry the kind's own shapes through JSON, and who may write its
  status. Nothing is added to a kind while the store runs. The file is
  loaded before the store's start returns. A missing file is an empty store; one that
  cannot be read or parsed, has another version, or holds a kind or atom this
  build does not know fails the start, because loading it as empty would
  read as "nothing installed". So a file written by a newer build that added
  a kind, a finalizer or a writer name does not load on an older one.
- Nothing is written that would not load back the same: the store reads back
  what it encoded and refuses the commit if it differs, with or without a
  file.
- A write goes to flash, then to ETS, then to subscribers. A reader never
  acts on desired state a reboot would take back. A flash write that fails
  before its rename rejects the commit. One that fails after it has an
  unknown outcome: the store stops instead of answering, and its
  replacement re-reads the file and announces the difference, as it does
  after dying between flash and ETS.
- A write is a call with a 30 s timeout. A write whose call exits, by
  timeout or because the store died, may have been applied; the caller
  reads to find out.
- `managed_fields` gives each spec path one owning writer; a write to a path
  someone else owns is a conflict. An Update claims its app's `version` this
  way, so a user's write to it mid-update is refused instead of raced.
- `Store.commit(ops)` applies writes to several resources all or none,
  persists once and notifies once. An `{:expect, kind, name, uid: n}` op
  rejects the commit unless the resource is still that one; `generation:`
  can be expected too. Whoever decided from a read uses the uid, so that a
  decision about a deleted resource never lands on a new one of its name.
- A kind can name finalizers that every resource of it holds from creation,
  and spec paths whose entries belong to their writer (`writer_entries`, an
  app's `holds`). `Store.release_writer` gives up everything a writer owned
  on a resource: its entries are deleted, any other value stays, unowned.
- `Store.await` blocks its caller until a function of one resource halts. It
  subscribes before its first read, reads again on every notification and
  once a second regardless, and gives up at a deadline. A store restart
  during the wait costs it nothing, the subscription being in `Watch`. A
  `Watch` restart, which replaces the whole subtree, ends the wait with an
  exit, as it ends every subscriber.
- The store keeps one in-memory operation claim per app. A command takes it;
  a second mutating command on that app fails as busy. The claim ends when
  its holder releases it or dies, and outlives a store restart.
- A kind has one owner, the only writer of its `progress` and of status
  outside conditions, and each condition type has one writer. Both are part
  of the kind, so the store checks them from its first message and the same
  after each of its restarts; no process registers anything.
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
concern this one),
`retention/0`, `owned_conditions/0`, `finalizer/0`, `action_class/1` (the
lane an action runs in), `writer_entries/0`, and the codec hooks
`encode_spec/1`, `decode_spec/1`, `encode_progress/1`, `decode_progress/1`
that a spec with atoms needs to get through JSON.

Controllers are listed in `config :vagus, :controllers`, each as a module
or as `{module, options}`. The options are for that controller's runtime
alone and are merged over the ones every runtime gets: how often it looks
at everything (`:resync`), how many steps it has in flight
(`:max_in_flight_steps`), its pacing, and a `:context` added to the shared
one. An option that is not one of those, one given twice or with a value it
cannot have, or a controller listed twice with different options, fails the
start of the subtree with the controller's name. One controller owns
a kind and writes its verdict; one that exports `owned_conditions/0` is
attached to a kind another owns and writes only those conditions. The
store's kinds are derived from the list, before the store starts: each
owner contributes its kind, with its admission and codec, the finalizers of
every controller on it, its owner and the writer of each condition type. A
list that cannot run (two owners of a kind, an attachment to a kind nobody
owns, one condition type or one finalizer declared twice on a kind) fails
the start of the subtree with an error that names the controllers.

Each controller has its own `Vagus.Resource.Runtime`, so a wedged controller
blocks no other and several can work one kind. The runtime keeps a queue
keyed by resource with at most one step in flight per key; a change arriving
mid-step marks the key dirty and it runs again. It has at most
`max_in_flight_steps` steps in flight at once (4), observations included,
which the lanes do not count: a start looks at every resource of the kind,
and several controllers on one kind would otherwise each observe every app
at the same moment. The rest wait in the order they were first asked for; a
key that waits keeps its place whatever else asks for it, and one whose
step has ended and is wanted again goes to the back, so none is starved.
Steps run in tasks, and so do the callbacks that take a resource: the
runtime handles data only, and a callback that raises or exits costs one
resource one step. A step keeps its place among those in flight until it
ends, a wait for a lane and the action included: a stop holds one for the
grace it gives plus a margin, so four long actions leave the rest of the
kind unobserved meanwhile, and what bounds a step is the timeout of the
calls it makes. The declarations,
which take no argument, are evaluated once when the subtree starts, and one
that raises fails that start with its name.

A step is one pass: one commit, of the verdict and every store write
`reconcile/2` returned, then at most one action, and then the resource is
observed again, so nothing is decided from what an action has since
changed. A pass can still be cut anywhere, inside the action or with a
commit whose outcome its caller never learns, which is why an action has to
be idempotent against observation: the next pass looks and carries on.
Create and start, stop and remove, and each hook are therefore
separate passes. The commit expects the uid the step read, and what a step
reports is believed only of that uid: a resource created under the name
meanwhile starts clean. What `reconcile/2` returns is checked whole before
any of it is applied (see "Verdicts").

A step that crashes is retried with back-off. An action that returns an
error ends its step; the next one runs at once and is told of the failure,
because a failed pull leaves nothing to observe. Counting failures and
spacing retries is the controller's decision, kept in status. Two things
the runtime paces by itself, with the same back-off: steps that keep ending
in a failed action, and steps that perform the action the step before
performed (by name, whatever its arguments, until a step performs none),
since an action that changes nothing observable would otherwise
repeat without pause. Such a timer holds back only the dirty mark made
while the failing step was in flight, because that mark may be the step's
own status write, which is announced like any other and cannot be told
apart. A change that arrives after the step has ended queues the resource
at once, whatever timer is armed.

A runtime indexes what each resource refers to: its `references/1`, its
owners and the resources that wrote fields of its spec, as each step reports
them. A change to one of those runs the resources that refer to it, and no
others. A reference first reported by a step gets one more step, for a
change that came before the index knew of it.

Controllers are level-triggered: they act on what they observe, not on the
event that woke them, so a missed event is repaired by the next observation.
A runtime looks at every resource of its kind when it starts, on a timer
(five minutes, or never), and when told to (`Runtime.resync`).
`Runtime.enqueue` has one resource looked at again, for a change the store
does not announce: an event about its container, the end of a pull it waits
for. Arriving during the resource's step it gets a step of its own right
after, even where a store change would wait for a back-off: it cannot be
the step's own write.

For the App kind, looking at everything is not how drift in the engine is
repaired: with several controllers on the kind it would be one engine call
per app per controller. One engine observer does it instead (see "The
engine layer"), and wakes only the apps that changed; the App runtime is
given a long `:resync` of its own, or none.

`Vagus.Resource.Lanes` holds a counting semaphore per action class: pulls 1,
engine calls 4. Only running actions count, and the wait is in the task
that asks, so no runtime waits; a step that waits for a lane holds no lane
slot, but does hold one of its runtime's steps in flight. The next slot
goes to the lowest priority waiting, then to whoever asked first. Pulls ask
with a priority. Steps do not: the order of steps is their runtime's queue,
and a controller has no say in it. A pull is not an action: it runs in the pull worker, whose state `observe`
reads, so it never occupies the app's queue slot, and a stop during a pull
cancels it (see "The engine layer").

While the host is shutting down every runtime rests and writes nothing;
otherwise the containers the shutdown stops would be read as crashes. While
the engine is unreachable `observe/2` returns `{:unavailable,
:engine_unavailable}`, `reconcile/2` is given that and answers Progressing
with that reason, no action is performed, no failure is counted, and the
runtime looks again a few seconds later: every boot starts that way.

```
Vagus.Resource.Supervisor        :rest_for_one
├─ Tables                        owns the ETS tables
├─ Watch                         Registry, duplicate keys
├─ store supervisor              :one_for_one, 3 restarts in 30 s
│  └─ Store                      single writer, persistence
├─ Lanes                         action semaphores
├─ services                      what controllers stand on, in this order:
│  ├─ App.AuthIndex              the token table API auth reads
│  ├─ App.Pulls                  which pulls run, who waits, their state
│  └─ Task.Supervisor            the pulls themselves
├─ Controllers.Supervisor        :one_for_one
│  └─ one per controller         :one_for_all
│     ├─ Task.Supervisor
│     └─ Runtime
└─ observers                     what stands on the controllers:
   └─ App.EngineObserver         engine events and inventory (started
                                 only with a controller to wake)
```

The store stands alone under a supervisor of its own, so its restart is
absorbed there. Nothing after it holds anything a new store lacks: rows and
claims are in the tables, subscribers in `Watch`, ownership in its start
options. And it stops on purpose when it cannot tell whether a write
reached flash; replacing the runtimes with it would end every step in the
middle of an engine call and cancel the running pulls. Those who outlive it
see this: a write that was waiting, or is made while there is no store,
exits and may have been applied, and a step whose commit exits is a
crashed pass, retried with back-off; reads go on; the new store announces
what its file holds that the tables did not, and tells `:store`
subscribers that it is new, on which every runtime looks at everything, for
a change the old store wrote to the tables and did not live to announce.
A store that is replaced more than three times in thirty seconds ends its
supervisor, and then everything after it is replaced as well.

Each pair is `:one_for_all` because steps are `async_nolink` tasks: one in
flight would otherwise outlive its runtime, and the replacement could start a
second action for the same key. There is no per-app process. The resource
supervisor knows nothing of apps: services are child specs it is given and
places after the lanes and before the controllers. Each stands before the
runtimes because a new one has forgotten what the resources had told it:
the pull worker its waiters, the token table its tokens. The runtimes start
again with it and look at everything, which tells it again. The token table
is first among them: a table that is replaced refuses every app's token
until that app's next pass puts it back, and the pull worker, which talks
to the engine, is the likelier to end.

Observers are the other kind of child it is given, placed after the
controllers. An observer tells runtimes where to look and holds nothing a
runtime relies on, so its replacement takes nothing with it: no step in
flight ends, no pull is cancelled, no token is forgotten. It makes up for
what it missed by having its runtime look at everything when it starts.

## The engine layer

**Client.** `Vagus.Runtime.Docker` makes one connection per call. Its 60 s
receive timeout is how long the engine may stay silent, not a deadline, and
a call can pass its own (`:recv_timeout`). `stop` needs that: the engine
answers a stop only when the container has exited, so the call waits the
grace plus 15 s, and a call that gives up does not stop the stop.
`Docker.failure/1` puts any error of the client into one shape:
`{:unreachable, reason}` (nothing at the socket), `{:timeout, :recv | :idle
| :total}`, `{:status, status, message}` with the engine's own text or
`nil`, `{:stream, message}` (a pull that answered 200 and then failed),
`{:transport, reason}` (the connection broke after the request was sent),
`{:invalid, term}` (refused before any request) and `{:other, term}` for
anything else, unchanged.

**Events.** `Vagus.Runtime.Events` holds the engine's event stream and passes
on the events of our containers: those labelled `supervisor_managed`, named
`app_…` or `addon_…`, or named as Core's. A dropped stream is retried from a
timer in that process, 1 s doubling to 30 s. What happened while no stream
was up is not seen, so each time a stream is established subscribers get
`{:docker_events, :gap}` before anything it carries, and a subscriber that
joins a running stream gets it at once: the notice is the whole mechanism,
and what it asks for is a look at everything. The engine is not asked to
replay what it still holds, because a consumer that acts on each event
would judge the old ones against present state.

**Backends.** `Vagus.App.Backend` is what a controller's `observe/2` and
`act/3` call: `observe` (by container name: `:absent`, or the instance's id,
state, exit code, start time, restart count, health, image, labels,
environment and address), `image_present?`, and the actions `create`,
`start`, `stop`, `remove`, `remove_image`, each one engine call. An action
succeeds when its end state already holds, except `create` on a name in use
(`:already_exists`), since what is there was made from another config. No
action returns an id: the instance's id is `observe`'s to report. With the
engine away `observe` is `{:unavailable, :engine_unavailable}`, never
`:absent`. `Backend.Container.list/1` is the one call that says which of our
containers exist. `Backend.Native` runs the MQTT broker as a `:temporary`
subtree of the supervisor that holds native apps: `:absent` or `:running`,
nothing to create and no image. Supervision owns the broker's internal
recovery: its own supervisor restarts its children. The subtree itself
ending is handed to reconciliation: it stays down and is observed as
`:absent`, and the controller starts it again with its back-off. A restart
by the holding supervisor would race the dead subtree's children for their
names and the port, and its failed tries would spend the budget every
native app shares. The engine observer monitors the subtree and wakes the
app when it ends, so the hand-over is immediate.

**Pulls.** `Vagus.App.Pulls` runs one pull per image reference, each in a
task holding the `:pull` lane. A pull exists for its waiters, each a
`{controller, resource name}`: `request` names one and returns at once, and a
request for a reference being pulled joins the pull. `state` is a table
read: `:idle`, `{:pulling, progress}` or `{:failed, reason, stamp}`. A
failure is kept, with when, until the next request, and is not retried by
the worker: spacing retries is the controller's. The end of a pull (success,
failure or cancel) is a `Runtime.enqueue` for each waiter. `cancel`
withdraws one waiter, and when it was the last, kills the task, which closes
the connection, which stops the engine pulling. Progress is summarised in
the task and passed on at most twice a second, to the table and to the one
function each waiter may have given. The functions run in the task, so one
may be called once more, for a summary already on its way, after it was
replaced or its waiter withdrew, and never for a later one.

**Engine observer.** `Vagus.App.EngineObserver`, one process placed after
the controllers, is the only subscriber to `Vagus.Runtime.Events` and the
only reader of the engine's inventory. Everything it does ends in a
`Runtime.enqueue` for one app of one controller, the hint to look again; it
decides nothing and keeps nothing a controller reads.

- An event about a container wakes the app the container is named for:
  `app_<slug>` and `addon_<slug>`, as the other firmware slot names it, are
  `<slug>`, and Core's is `homeassistant`. Only an action that can change
  what a pass decides does so: `create`, `start`, `die`, `stop`, `kill`,
  `oom`, `destroy`, `pause`, `unpause`, `restart`, `rename` and
  `health_status: …`. The rest is dropped, the three `exec_*` events of
  every healthcheck probe above all. Events are only made members of a
  set, emptied once per burst, so a thousand events about one container
  are one wake.
- On every gap it makes one container list and wakes every app that has a
  container in that listing or in the one before. Events were lost, and a
  listing cannot stand in for them: a container restarted by the engine's
  own policy, as Core's is, has the same id and the same state before and
  after.
- Every five minutes (configurable, or never) it lists as well, and since
  no event was lost wakes only the apps whose row appeared, went or
  changed. A row is the container's id, image, state, and the exit code
  and health the engine's status text carries, without its durations: `Up
  3 seconds` becoming `Up 4 seconds` is no change. The first listing after
  its start wakes every app that has a container.
- A listing that fails, the engine being away or anything else, keeps the
  last listing and what the next one owes, and is tried again after 1 s,
  doubling to 60 s, by one timer; each gap or tick meanwhile is a try of
  its own. The listing's timeout is how long the engine may stay silent,
  not a deadline.
- The events worker is outside this subtree and keeps its subscribers in
  its own memory, so it is monitored, and when it is replaced, or was not
  there, subscribing is tried again after 100 ms, doubling to 30 s.
  Nothing announces that a name is registered again; the worker's
  supervisor has it back at once, and a subscriber that joins a running
  stream is sent a gap, which is a listing.
- `watch(app, pid)` has it monitor a native instance and wake the app when
  that ends, which is what makes the broker's recovery immediate: nothing
  else restarts it. The pid is the `process` of the instance `observe`
  returned, read with the rest of it, and whoever observed calls `watch`
  on every observation; it is idempotent.

When the observer is replaced nothing is replaced with it. It starts by
having its runtime look at every app, which finds what happened while it
was away and, as each pass observes a native instance, tells it again what
to watch. A backend that raises ends it, which is loud and costs only the
observer. This is the drift repair of the App kind: neither a gap nor a
timer has every app observed by every controller.

## Verdicts

`reconcile/2` returns `{%Verdict{} | :no_verdict, effects}`. A
`Vagus.Resource.Verdict` holds a condition for every type the controller
lists in `condition_types/0`, never a subset. The owner's verdict may also
carry other status (the running instance, a diary of what it has counted)
and say that the resource has finished for good. `:no_verdict` is for a pass
with nothing to report.

Status is not an effect. Only the runtime writes status, from the verdict, in
the same commit that marks the generation observed, so a generation cannot be
marked observed beside a condition left over from the previous one. The
store rejects a condition type its writer does not own.

A verdict that leaves out a declared type or carries an undeclared one, a
return that is no verdict, a term among the effects that is no effect, a
second action, and a store write after the action all fail the step, before
anything is written or done. Such a return is a defect in the controller,
and applying the part of it that is well-formed would act on the engine or
the store with no status to show for it. The step's task is the isolation
and the back-off the pacing. One contract test, over a table of
`(resource, observation)` rows, holds every controller to this.

## The App kind

An App's spec (`Vagus.App.Spec.Schema`) holds `config` (the app's own copy
of its manifest), `version`, `options` (the user's, merged over the
manifest's when written out), `settings` (`ports`, `protected`, `watchdog`,
`boot`, `ingress_panel`, `auto_update`), `ingress_port`, `run`,
`restart_counter`, `start_counter`, `holds` and `lifecycle`. The app should
run when `run` is true and `holds` is empty.

Nothing derived is stored. The wave, the boot mode, the container's name
and every other answer of the profile is computed from those fields when
asked for, so a new manifest cannot leave a stale copy behind.
`ingress_port` is stored only for a manifest that asks for a dynamic port,
which is an assignment and not a derivation.

Paths have owners: an Update owns `version` while it runs, the resource
that placed a hold owns `holds.<name>`, and `holds` is the kind's
`writer_entries`, so a hold disappears with its writer. Everything else is
written by commands, which own nothing.

### Admission

The kind's validator is `Schema.validate/2`: a pure function of the spec
and of `Vagus.App.Facts`, the machine's architecture, board, Core version
and so on as data. The store runs it on every write of a spec. It fills in
what was left out (a manifest alone is a whole spec) and refuses, each with
a reason a command turns into its answer:

- a `lifecycle` that is none of the three, a field or a setting the
  profile does not have, a field of the wrong shape;
- a profile the manifest's backend is not. A manifest that asks to run
  inside the VM gets the native profile only if the app is one of ours;
- a manifest whose slug is reserved (the system's own, and Core's name,
  since `app_homeassistant` would read back as Core's container) or is no
  name for a directory, a manifest with no image, a native manifest that
  runs once;
- a spec that would not come back from the resource file as itself, found
  by encoding and decoding it as the store does;
- options the manifest's schema does not accept;
- `watchdog` for an app that runs once;
- a dynamic ingress app without its port, a port outside the range or one
  the system keeps, and a port for any other app.

Whether this machine can run the manifest is not among them. Every rule
holds on every write, so an app whose manifest asks for a newer Core than
is installed would refuse its own stop. `Schema.availability/2` answers
it, by architecture, machine type and Home Assistant version, with
upstream's three refusals and messages, for an install or an update to ask
before it writes.

A validator is given one spec and no other resource, so it cannot refuse a
dynamic ingress port that another app holds, and nothing serialises one
caller's read of the ports in use with its create. The pick
(`assign_ingress_port/3`, the lowest free port) is therefore checked after
the fact: uids are given in the order the store creates, so of two apps
that picked the same port exactly the later one finds
`ingress_port_contested?/2` true, picks again and writes, before it is
first started.

### Lifecycle profiles

`lifecycle` names one of three profiles: `:container`, `:core` or
`:native`. A profile is a pure module (`Vagus.App.Profile.Container`,
`.Core`, `.Native`) that answers the questions in the table for one app,
one function a question; admission accepts the three names and nothing
else. The settings are not fields to combine freely: the controller is
tested against three profiles, not against every combination of their
answers. A profile also lists the spec fields and settings its apps have:
a native app has no ingress port and only the `watchdog` setting, and a
Core spec is its version and what commands write, until Core's container
is built from a spec.

The watchdog's budget is five attempts, the pause between them starting at
10 s and doubling, at most ten such runs in thirty minutes, forgotten once
the app has been ready for ten minutes. A native app's `watchdog` is on
unless turned off. Core's crash-loop rule is three engine restarts in ten
minutes, acted on at most ten times in thirty minutes.

| Question | `:container` | `:core` | `:native` |
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
for at most its own `wave_wait_ms`, then starts anyway. The wave follows
the manifest's `startup`: `initialize` 10, `system` 20, `services` 30,
`application` and `once` 50, with Core at 40 between them.

### The container

`Vagus.App.Container.Config.build/3` is the one description of an app's
container: a pure function of the spec, the facts, and what only creation
knows, the token and the device rules (resolving a device path reads the
node). For the same inputs it gives exactly what the code this replaces
gives. The container's name is not in it: that is the profile's, `app_<slug>`
where it was `addon_<slug>`, and nothing in the config is derived from it.
The image's tag is the spec's `version`, which an update moves ahead of the
manifest's. Core's container is not described by it.

### Failures

`Vagus.App.Failure.classify/2` says what a failed action or pull means:

| What failed | Class | Cause |
|---|---|---|
| a 5xx saying `address already in use` or `port is already allocated`, in any case | permanent | `:port_conflict`, with the port |
| a pull refused as unauthorized or denied, or whose repository "does not exist" | permanent | `:pull_denied` |
| a pull's 404, or its stream saying the manifest is unknown or not found | permanent | `:image_not_found` |
| a 400, or a reference refused before any request | permanent | `:invalid_config` |
| any other action's 404 | transient | `:not_found` |
| a stop that timed out | pending | `:still_stopping` |
| engine away, slow, connection broken | transient | `:engine_unreachable`, `:engine_timeout`, `:engine_transport` |
| any other 5xx; any other refusal | transient | `:engine_error`; `:engine_refused` |
| a pull that failed otherwise, or died | transient | `:pull_failed`, `:pull_crashed` |
| a name in use by a container, or by a process | transient | `:already_exists`, `:name_taken` |
| anything else | transient | `:unknown` |

Permanent means the same attempt fails the same way until the spec or the
machine changes. A stop that timed out has not failed: the engine answers
a stop when the container has exited, and goes on stopping it.

### Start sequence

One action per pass, each decided from what the pass before left to
observe:

1. Pull the image, in the pull worker; the app's passes wait for its end.
2. Create the container, minting the token into its environment.
3. Put the token in the token table. Status publishes the instance:
   container id, address.
4. Start the container.
5. Wait for readiness, as the profile defines it.
6. Gate `:dns_ready`, a condition the Dns controller sets and that must
   name this instance id, then Ready.

The invariant: a container never runs before auth knows its token. It holds
because both are the App controller's own actions, in that order: start is
decided only by a pass that observes the token in the table, which is
after the put has returned. The token is never written to flash; after a
restart it is re-read from the engine. A Core hook is an action too, and so
a pass of its own.

Auth is not a controller. `Vagus.App.AuthIndex` owns the token table, which
API auth reads directly: one lookup a request, from the token to the app's
name. What the app may do is read from its resource at each request.
It offers an idempotent `put` and `remove`, each a call that returns once
the table shows it, and a `put` replaces the app's earlier token. The
table is keyed by the token's SHA-256, taken by the caller, so neither it
nor the process ever holds a token.

With the process gone the table is gone: every lookup answers "unknown",
and a put or remove answers an error, which fails the step that made it.
It stands before the App runtime, so its replacement, which has an empty
table, restarts that runtime: every app is observed again, found without
its token, and put back, by the listing a runtime makes when it starts.
Until then the app's requests are refused: four apps are put back at a
time, and none while the engine is away if the pass must observe it first.
Uninstall removes the token before it touches the container.

Three controllers attach to the App kind, each with its own runtime:

- Dns owns `:dns_ready`, the one gate, and the last step before Ready.
- Ingress owns `:ingress_ready`, ingress sessions and the panel push to
  Core. It gates nothing: the ingress port is assigned at admission, and
  sessions and the panel follow the app eventually.
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
clean up declares a finalizer and releases it when the cleanup is done; the
resource disappears when all are released. Every resource holds the
finalizers of all its kind's controllers from creation, so a delete cannot
arrive before a controller has attached its own. They are released in any
order; a controller that must come after another reads the finalizers still
on the resource and waits, and the other's release is a change that brings
its next pass. The App needs no such order for its token: removing it is
the first action of its own uninstall.

Owned resources are collected through their declared `owner_refs`, never by
inferring ownership from a name: an uninstalled app's publications go with
it. Ownership is by uid, so a new resource under an old name owns nothing
its predecessor did, and a resource with several owners goes with the last.
A field written by a resource (a Backup's hold, an Update's claim on
`version`) is released when that resource is gone; a resource that is
itself an orphan is only deleted. Both are checked from the
resource that depends, at the start of each of its steps, by the runtime of
its kind; a resync finds whatever a missed notice left.

One-shot kinds such as Update and Backup declare `retention/0`, a keep count
and a TTL. A resource with a terminal verdict gets a finished stamp; the
newest `keep` by uid remain, and of those any finished longer ago than the
TTL goes too, looked at again when its time is up. The count is the bound
that always holds: the stamp is status and starts again after a reboot.
Collection is an ordinary delete of the uid that was listed, so finalizers
run and a newer resource of the name is left alone.

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
120 s still short of Ready returns success with state `startup`, as
upstream does.

The API is not a child of the resource subtree and keeps serving while that
restarts. For that moment the tables are gone and the store has no process:
a read raises and a write exits. The command facade catches both and
answers an explicit "control plane restarting" (HTTP 503), for reads as
for commands, so a restart of the subtree is an answer and not an API that
went down.
