defmodule Vagus.Core.Lifecycle do
  @moduledoc """
  HA Core container lifecycle operations — `adopt/1`, `start/1`, `stop/1`,
  `restart/1`, `rebuild/1`, `update/2` — the code that replaces the
  hand-run balena-engine recipe
  (`.claude/plans/vagus-core-lifecycle/plan.md` Phase 1, mirroring upstream
  `homeassistant/core.py`/`docker/manager.py` per
  `.claude/plans/vagus-core-lifecycle/research/supervisor-semantics.md`
  §1-§2/§4). A plain functions module, `Vagus.Addon.Manager` style — no
  process, no state of its own; every op reads/writes through
  `Vagus.Runtime.Docker` (the Engine-API client) and `Vagus.Core.Versions`
  (persisted installed version), both injectable per call.

  ## Options (every public op takes `opts \\\\ []`)

    * `:docker` - keyword list threaded into every `Vagus.Runtime.Docker`
      call (e.g. `[socket: path]`). Defaults to `[]` (the real socket).
    * `:versions` - the `Vagus.Core.Versions` server ref. Defaults to
      `Vagus.Core.Versions`.
    * `:health` - zero-arity fn `-> :healthy | :timeout`, the health gate.
      Defaults to `fn -> Vagus.Core.Health.await_healthy() end`.
    * `:http_config` - zero-arity fn run whenever this module establishes
      that Core is up, to re-pull Core's own HTTP parameters. Defaults to
      `fn -> Vagus.Core.HttpConfig.refresh() end`; its return value is
      ignored (see "HTTP-config refresh" below).
    * `:token` - threaded into `Vagus.Core.Container.create_config/2` when
      present (tests inject; production omits it, so `Container` falls back
      to its own real `Vagus.API.Token.get/0` default).
    * `:version` - (`start/1` only) the desired version; defaults to
      `Vagus.Core.Versions.installed/1`.

  The container name is always `Vagus.Core.Container.name/0` — every op
  targets the one fixed-name Core container, never an id passed in by the
  caller (mirrors upstream's fixed `homeassistant` name).

  ## Parity table (op → upstream behavior)

  | Op | Upstream (§1/§4) | v1 here |
  |---|---|---|
  | `adopt` | `attach()`: inspect by name, adopt as-is, no reconciliation | same — inspect by name, seed `Versions` from the running tag, never create |
  | `start` | reuse if `ImageID` matches desired, else "extended start" (recreate) | reuse if `Config.Image` tag AND spec fingerprint match desired, else recreate; already-running is a no-op |
  | `stop` | `docker stop` (S6 timeout), `remove_container=False` by default | identical — keeps the container |
  | `restart` | `docker restart`, no recreate | identical |
  | `rebuild` | stop-with-remove then start (recreates from current spec) | stop + remove + create(installed) + start — the drift healer |
  | `update` | pull → start() only if was running → health check → rollback-recreate on failure | same shape, sync (no `background`/`job_id`) |

  ## v1 deviations (see plan "Locked decisions" for the full list)

  No image pull in `start/1` — a missing image is returned as an error
  (`{:error, {:create_failed, ...}}`), not a landingpage fallback; `rebuild/1`
  and `update/2` are the only ops that (re)create against a specific spec.
  No automatic backup before `update/2`. Rollback is always a re-create with
  the previous version (never a backup restore), matching upstream — but if
  there was no previously-installed version to roll back to (e.g. the very
  first `update/2` ever run, before anything was adopted/seeded),
  `update/2` returns `{:error, {:health_timeout, :no_rollback_version}}`
  rather than attempting a recreate with a `nil` version — a gap upstream
  doesn't have (its `rollback_version` capture has its own "no rollback
  version" issue path, `core.py:454-456`, which this mirrors).

  A create/start failure recreating the **new** target version in
  `update/2` (after the old container has already been stopped+removed) is
  treated the same as a health-gate timeout: v1 attempts the same
  rollback-recreate of the previous version, returning
  `{:error, {:recreate_failed, reason, :rolled_back}}` on success or
  `{:error, {:recreate_failed, reason, :no_rollback_version}}` when there's
  nothing to roll back to (mirroring `rollback/2`'s own
  `:no_rollback_version` case) — without this, a create/start failure at
  that specific point would otherwise leave Core absent with no container
  at all, unlike every other failure path in this module.

  `start/1`'s tag-mismatch recreate and `rebuild/1`'s recreate do **not**
  get the same rollback treatment: both recreate the container from the
  *currently installed* version — there is no "previous version" different
  from the one that just failed, so a rollback-recreate there would just
  retry the identical create/start call and fail identically. A
  create/start failure in either path deliberately leaves Core absent (no
  landingpage fallback, matching the "no image pull" stance above); the op
  is explicit and safely retryable once the underlying failure (bad image,
  disk full, whatever) is fixed.

  ## The reuse-vs-recreate rule

  A container is only ever **reused** (plain `docker start`/`restart`, no
  create) when it already exists under the fixed name AND its
  `Config.Image` equals `Vagus.Core.Container.image(desired_version)` AND
  its `Vagus.Core.Container.spec_fingerprint_label/0` label equals the
  fingerprint of the spec `create_config/2` would build right now —
  otherwise every op that needs the container running recreates it: stop
  the old one (S6-derived timeout, keeping upstream's grace period),
  remove it, `create_config/2` a fresh one from the current spec, start it.
  This is exactly how drift gets healed: `adopt/1` never reconciles a
  running container's spec, so a hand-edited or stale-image container is
  left alone until the next `rebuild/1` (explicit) or a mismatched
  `start/1`/`update/2` forces a recreate.

  The fingerprint half is what makes that generic rather than
  version-only. Upstream's own reuse check is image-identity, which silently
  keeps a container running against a spec Vagus no longer builds — every
  env/mount change we ship (the `/run/supervisor` socket mount being the
  first) would otherwise need its own bespoke migration, or would simply
  never take effect on an already-installed device until someone hit
  `rebuild`. A container whose label is **absent** (created before
  fingerprinting existed, or by hand) can never match, so the first
  `start/1` after such an upgrade recreates it exactly once.

  ## Health gate placement

  The health gate (`opts[:health]`, default `Vagus.Core.Health.await_healthy/1`)
  only runs after an op that just (re)created the container or started a
  previously-stopped one — never after a no-op (already-running `start/1`)
  and never in `stop/1`. `update/2` additionally skips it when the
  container wasn't running before the update (upstream parity: a
  not-running update just swaps image+version, the container isn't
  started, and the whole point of the health gate — verifying the new
  Core actually comes up — doesn't apply to a container that stays down).

  ## HTTP-config refresh

  Core's HTTP parameters (`Vagus.Core.HttpConfig` — the port it actually
  listens on, ssl, server_host) are re-pulled at every point this module
  establishes that Core is up: after a passing health gate, and on the
  already-running no-op `start/1`. That no-op branch is not redundant —
  `Vagus.Core.Boot` calls `start/1` unconditionally on every boot, so it is
  the only hook that fires when Vagus restarts (an OTA, say) under a Core
  that kept running, where no health gate ever runs.

  The refresh cannot fail an op: `HttpConfig.refresh/1` returns
  `{:skipped, :no_socket}` on the TCP fallback and `{:error, _}` on a pull
  failure (logging it there), both of which are ignored here — a Core that
  is demonstrably healthy is not "failed to start" because it wouldn't say
  which port it is on.

  ## Core's stored port

  `start/1` runs `Vagus.Core.PortMigration.run/1` before anything else it
  does — the rewrite of the port Core persisted for itself in
  `<config>/.storage/http`, which on an already-installed fleet board still
  says 8123 and which Core prefers over every default once it exists (see
  that module for the full story). It re-runs on every start until Core has
  actually been seen serving port 80, which is a fact only the HTTP-config
  refresh above can establish.

  This is the choke point rather than each individual create/start call
  because it has to happen *before* Core comes up to take effect on that
  same start, and `start/1` is the one op guaranteed to run: `Vagus.Core.Boot`
  calls it unconditionally on every boot, adopted-running or not. `rebuild/1`
  and `update/2` deliberately do not get their own call — any device that can
  reach them has already booted, and any device on which they create Core for
  the very first time has no stored config for the migration to act on.

  The already-running no-op branch of `start_existing/3` is not an exception:
  the rewrite still lands, and Core picks the new port up whenever it next
  restarts. A migration that fails, for any reason, is logged and ignored —
  it can never fail the start it was called from.

  ## The socket file outlives Core

  Core never unlinks the `SUPERVISOR_CORE_API_SOCKET` it created
  (`Vagus.Core.Container.socket_path/0`) — a unix socket's directory entry
  survives the process that bound it. Left alone, that file keeps
  `Vagus.Core.Transport` resolving `{:socket, _}` at an endpoint nothing is
  listening on for as long as Core is down, so the TCP fallback never
  engages and a plain file dropped there would pin the transport
  indefinitely. Every op here that leaves Core stopped or removed therefore
  unlinks it (mirroring `scripts/dev-core.sh down`), best-effort: the next
  Core start recreates it, and a failed unlink is logged, never returned —
  a `stop` that worked is not a failure because a stale file survived it.

  ## Non-atomicity

  The multi-step `update/2`/rollback sequence (stop → remove → create →
  start → `set_installed` → health-gate → maybe-rollback) is **not
  atomic** — it's a sequence of independent Engine-API calls plus a
  `Versions.set_installed/2` persist, not a single transaction. A
  mid-sequence BEAM restart (crash, deploy, power loss) can leave
  `Vagus.Core.Versions.installed/1` and the actual container state
  transiently out of sync — e.g. the version file already updated but the
  container not yet started, or vice versa. v1's stance is
  reconcile-on-next-op, not crash-safety: the next `start/1`, `rebuild/1`,
  or `update/2` reads whatever `Versions.installed/1` and the container's
  actual state are at that moment and heals from there — the same
  reuse-vs-recreate drift-healing this module already does for
  hand-edited/stale containers — rather than this module tracking or
  resuming a partially-applied operation itself.

  ## Safe mode

  `restart/1` and `rebuild/1` accept `opts[:safe_mode]` — the "Restart Home
  Assistant → advanced → safe mode" recovery flow the frontend exposes for
  a boot-looping custom integration (audit E3). Upstream
  (`homeassistant/core.py`) touches an empty `safe-mode` file at the root
  of Core's `/config` before the restart it triggers; Core's bootstrap
  consumes (and deletes) that marker on its next boot, starting with
  custom components disabled. This module does the same: `File.touch/1` on
  `Vagus.Core.Container.config_path/1` joined with `"safe-mode"` —
  Core's `/config` is the `vagus-core-config` named volume, and
  `config_path/1` resolves its host-side directory (injectable via
  `opts[:homeassistant_path]`, same key `Vagus.Backend.Host.DiskBreakdown`
  uses for the same volume).

  The write happens before any container-affecting Engine-API call, and a
  write failure **aborts the whole op** (`{:error, {:safe_mode_marker,
  reason}}`) rather than falling through to an ordinary restart — a
  safe-mode request that silently restarts normally instead is exactly
  the bug this closes, so a marker that can't be written must fail loud,
  not degrade quietly.

  `opts[:force]` is part of the same request body upstream defines
  (`{safe_mode: bool, force: bool}`) but is accepted-and-ignored: upstream
  uses it to bypass an in-progress offline database migration gate, and
  Vagus has no such gate (nothing here blocks on one, audit D11). The
  router validates `force`'s type but never threads it down to this
  module.

  ## Serialization — one non-blocking global mutex

  Every public op wraps its body in
  `:global.trans({{:core_lifecycle, Container.name()}, self()}, fun, [node()], 0)`
  — the same `:global.trans/3`-based local mutex `Vagus.Addon.Manager` uses
  for its per-slug locks (see that module's "W6" moduledoc section), but
  with an explicit `retries: 0` and a **single** key (`Container.name()`,
  not per-op) rather than `Addon.Manager`'s blocking, per-slug lock.

  Two differences from `Addon.Manager`, both deliberate:

    * **One key for all ops, not one per op** — there is exactly one Core
      container, so unlike add-ons (many independent slugs that can run
      concurrently) every Core lifecycle op is mutually exclusive with
      every other one: a `stop` racing an in-flight `update`'s
      create/start would be exactly the kind of container/state
      inconsistency `Addon.Manager`'s per-slug lock exists to prevent, and
      Core has only the one container to protect.
    * **Non-blocking (`retries: 0`), not blocking** — add-on lifecycle
      calls come from a handful of internal callers (the router, the
      watchdog) that are fine waiting briefly for another op on the same
      slug to finish. Core's `update/2` can run for minutes (a multi-GB
      image pull + health gate on a slow device, per the plan's "long sync
      update" risk); a caller blocking on `:global.trans` for that whole
      window would tie up a Bandit request worker for no benefit. Returning
      `{:error, :busy}` immediately instead lets the router surface a fast
      409 (Phase 3) — "an update is already running, try again" is more
      useful to a client than a request that silently hangs for minutes.

  Because the lock is acquired **once per public call and never re-entered**
  (every op's actual work runs in a private, unlocked helper — `do_start/1`,
  `do_stop/1`, etc. — called directly by the public function's locked
  closure, never by another locked public function), there is no nested
  `:global.trans` acquisition anywhere in this module, so the
  retries: 0/non-blocking choice can never abort a legitimate internal
  reentrant call the way it would if one locked op called another.
  """

  require Logger

  alias Vagus.Core.{Container, Health, HttpConfig, PortMigration, Transport, Versions}
  alias Vagus.Runtime.Docker

  @fallback_stop_timeout_s 260
  @gracetime_env_prefix "S6_SERVICES_GRACETIME="
  @safe_mode_marker "safe-mode"

  @doc """
  Adopts the Core container by name, as-is — never creates.

  `{:adopted, info}` (the full `docker inspect` map) on success, seeding
  `Vagus.Core.Versions.seed/2` from the running image's tag (the part after
  the last `:` of `Config.Image`; skipped silently if unparseable).
  `:absent` if no container exists under `Vagus.Core.Container.name/0`.
  `{:error, term()}` on any other Engine-API failure.
  """
  @spec adopt(keyword()) :: {:adopted, map()} | :absent | {:error, term()}
  def adopt(opts \\ []) do
    with_lock(fn -> do_adopt(opts) end)
  end

  @doc """
  Starts the Core container at the desired version (`opts[:version]`,
  default `Vagus.Core.Versions.installed/1`).

  Reuses the existing container (plain `docker start`) when its image tag
  already matches the desired version; recreates it (stop+remove+create+
  start) on a tag mismatch; creates+starts fresh if absent. Already-running
  is a no-op (`:ok`, no health gate). No image pull — a missing image
  surfaces as `{:error, term()}`, not a landingpage fallback.
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []) do
    with_lock(fn -> do_start(opts) end)
  end

  @doc """
  Stops the Core container, keeping it (no remove). Timeout is derived from
  the image's `S6_SERVICES_GRACETIME` env (ms): `20 + div(gracetime, 1000)`
  seconds, falling back to `#{@fallback_stop_timeout_s}`s if the container
  can't be inspected or the env var is absent/unparseable. Already-stopped
  is `:ok` (Docker's 304).
  """
  @spec stop(keyword()) :: :ok | {:error, term()}
  def stop(opts \\ []) do
    with_lock(fn -> do_stop(opts) end)
  end

  @doc """
  Restarts the Core container in place (`docker restart`, no recreate),
  then runs the health gate.

  `opts[:safe_mode]` (default `false`) touches Core's `safe-mode` marker
  (see the moduledoc "Safe mode" section) BEFORE issuing the restart —
  Core's bootstrap consumes it on the boot this restart triggers.
  `opts[:force]` is accepted by the router but has no effect here (see
  moduledoc); this module never reads it.
  """
  @spec restart(keyword()) :: :ok | {:error, term()}
  def restart(opts \\ []) do
    with_lock(fn -> do_restart(opts) end)
  end

  @doc """
  The drift healer: stop (S6 timeout) + remove + create (from
  `Vagus.Core.Versions.installed/1`) + start + health gate — always
  recreates from the current spec, regardless of what was running before.
  An absent container still gets created+started (it's an explicit,
  user-requested op). `{:error, :no_version}` if nothing is installed yet.

  `opts[:safe_mode]` (default `false`) behaves exactly as it does for
  `restart/1` — the marker is written once the target version is
  resolved (so a `:no_version` failure doesn't leave a stray marker
  behind) and before the stop/remove/create/start sequence begins.
  """
  @spec rebuild(keyword()) :: :ok | {:error, term()}
  def rebuild(opts \\ []) do
    with_lock(fn -> do_rebuild(opts) end)
  end

  @doc """
  Updates to `version` (default `Vagus.Core.Versions.latest/1`).

  `{:error, :no_version}` if no target can be resolved.
  `{:error, :version_installed}` if `target == installed` already.
  Pulls the target image first — a pull failure returns
  `{:error, {:pull, reason}}` with the old Core container untouched.
  Then, if a container exists, stops+removes it; recreates+starts at the
  target version ONLY if it was running before the update (upstream
  parity — a not-running update just swaps the recorded version, no start,
  no health gate). `Vagus.Core.Versions.set_installed/2` runs as soon as
  the new container has started (before the health gate resolves — matches
  upstream recording the version before its own health check). On a
  health-gate timeout: rolls back — stop+remove the new container,
  recreate+start the previous version, `set_installed/2` back to it —
  returning `{:error, {:health_timeout, :rolled_back}}`, or
  `{:error, {:rollback_failed, reason}}` if the rollback recreate itself
  fails. If the new container's create/start itself fails (before the
  health gate even runs), the same rollback-recreate is attempted:
  `{:error, {:recreate_failed, reason, :rolled_back}}` on a successful
  rollback, `{:error, {:rollback_failed, reason2}}` if that rollback also
  fails, or `{:error, {:recreate_failed, reason, :no_rollback_version}}`
  when there's no previous version to roll back to. Success returns
  `{:ok, version}`.
  """
  @spec update(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def update(version \\ nil, opts \\ []) do
    with_lock(fn -> do_update(version, opts) end)
  end

  ## Locking — see moduledoc "Serialization" section.

  defp with_lock(fun) do
    case :global.trans({{:core_lifecycle, Container.name()}, self()}, fun, [node()], 0) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  ## adopt/1

  defp do_adopt(opts) do
    case inspect_container(opts) do
      {:ok, info} ->
        seed_versions(info, opts)
        {:adopted, info}

      {:error, {:http, 404, _message}} ->
        :absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seed_versions(info, opts) do
    case parse_tag(info) do
      {:ok, tag} -> Versions.seed(tag, versions_server(opts))
      :error -> :ok
    end
  end

  # Tag = the part after the last ":" that follows the last "/", so a
  # registry `host:port` prefix isn't mistaken for a tag (same rule
  # `Vagus.Runtime.Docker.split_image/1` applies to write an image ref).
  defp parse_tag(%{"Config" => %{"Image" => image}}) when is_binary(image) do
    last_segment = image |> String.split("/") |> List.last()

    case String.split(last_segment, ":", parts: 2) do
      [_name, tag] when tag != "" -> {:ok, tag}
      _no_tag -> :error
    end
  end

  defp parse_tag(_info), do: :error

  ## start/1

  defp do_start(opts) do
    # Pre-start, idempotent, ignored either way — see the moduledoc's
    # "Core's stored port" section and `Vagus.Core.PortMigration`.
    _outcome = PortMigration.run(opts)

    with {:ok, version} <- resolve_start_version(opts) do
      case inspect_container(opts) do
        {:ok, info} -> start_existing(info, version, opts)
        {:error, {:http, 404, _message}} -> create_and_start(version, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_existing(info, version, opts) do
    desired_fingerprint = Container.spec_fingerprint(desired_spec(version, opts))

    cond do
      image_of(info) != Container.image(version) ->
        recreate(info, version, opts)

      fingerprint_of(info) != desired_fingerprint ->
        Logger.info(
          "Vagus.Core.Lifecycle: Core container spec drift " <>
            "(#{inspect(fingerprint_of(info))} != #{inspect(desired_fingerprint)}) — recreating"
        )

        recreate(info, version, opts)

      running?(info) ->
        # Nothing to do to the container — but this IS the boot-time
        # reconcile hook (see "HTTP-config refresh" in the moduledoc), and
        # Core may have picked a different port since we last asked.
        refresh_http_config(opts)

      true ->
        with :ok <- Docker.start_container(Container.name(), docker_opts(opts)) do
          health_gate(opts)
        end
    end
  end

  defp recreate(info, version, opts) do
    with :ok <- stop_existing(info, opts),
         :ok <- remove_container(opts) do
      create_and_start(version, opts)
    end
  end

  ## stop/1

  defp do_stop(opts) do
    timeout =
      case inspect_container(opts) do
        {:ok, info} -> stop_timeout_s(info)
        {:error, _reason} -> @fallback_stop_timeout_s
      end

    case Docker.stop_container(
           Container.name(),
           Keyword.merge(docker_opts(opts), timeout: timeout)
         ) do
      :ok -> unlink_core_socket()
      {:error, reason} -> {:error, reason}
    end
  end

  ## restart/1

  defp do_restart(opts) do
    with :ok <- maybe_write_safe_mode_marker(opts),
         :ok <- Docker.restart_container(Container.name(), docker_opts(opts)) do
      health_gate(opts)
    end
  end

  ## rebuild/1

  defp do_rebuild(opts) do
    with {:ok, version} <- resolve_installed_version(opts),
         :ok <- maybe_write_safe_mode_marker(opts),
         :ok <- stop_if_present(opts),
         :ok <- remove_container(opts) do
      create_and_start(version, opts)
    end
  end

  ## Safe mode — see moduledoc "Safe mode" section.

  defp maybe_write_safe_mode_marker(opts) do
    if Keyword.get(opts, :safe_mode, false) do
      write_safe_mode_marker(opts)
    else
      :ok
    end
  end

  # `mkdir_p` first: the volume's host-side directory (`Container.config_path/1`)
  # may not exist yet (Core never adopted/created on this device), and
  # `File.touch/1` alone does not create parents — without this, that
  # ordinary case would abort the whole safe-mode op with `:enoent`
  # (security-phase6.md S3). A failed `mkdir_p` still aborts, same as a
  # failed `touch` — see the moduledoc's "fail loud" contract.
  #
  # The path is config-derived (`Container.config_path/1`: engine data_root
  # + the constant volume name) joined with a constant filename — no
  # request input reaches it; the `opts` seam is test-only (verified in
  # security-phase6.md item 2).
  # sobelow_skip ["Traversal.FileModule"]
  defp write_safe_mode_marker(opts) do
    path = Path.join(Container.config_path(opts), @safe_mode_marker)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(path) do
      :ok
    else
      {:error, reason} -> {:error, {:safe_mode_marker, reason}}
    end
  end

  defp stop_if_present(opts) do
    case inspect_container(opts) do
      {:ok, info} -> stop_existing(info, opts)
      {:error, {:http, 404, _message}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## update/2

  defp do_update(version_arg, opts) do
    versions = versions_server(opts)
    installed = Versions.installed(versions)

    with {:ok, target} <- resolve_target(version_arg, versions),
         :ok <- check_not_installed(target, installed),
         :ok <- report_stage(opts, "pull_image", 10),
         :ok <- pull_target(target, opts) do
      case inspect_container(opts) do
        {:ok, info} -> update_existing(info, target, installed, opts)
        {:error, {:http, 404, _message}} -> finish_update(false, target, nil, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Stage waypoints for the `home_assistant_core_update` job the router
  # creates (see `Vagus.Addon.Update`'s "Job progress" moduledoc section —
  # same discipline: coarse transitions, no-op without `opts[:job]`, always
  # `:ok` so it can sit in a `with` chain).
  defp report_stage(opts, stage, progress) do
    Vagus.Jobs.update(
      Keyword.get(opts, :job),
      [stage: stage, progress: progress],
      Keyword.get(opts, :jobs_server, Vagus.Jobs)
    )
  end

  defp resolve_target(nil, versions) do
    case Versions.latest(versions) do
      nil -> {:error, :no_version}
      version -> {:ok, version}
    end
  end

  defp resolve_target(version, _versions) when is_binary(version), do: {:ok, version}

  defp check_not_installed(target, target), do: {:error, :version_installed}
  defp check_not_installed(_target, _installed), do: :ok

  defp pull_target(target, opts) do
    case Docker.pull_image(Container.image(target), docker_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pull, reason}}
    end
  end

  defp update_existing(info, target, rollback_version, opts) do
    was_running = running?(info)
    :ok = report_stage(opts, "stop", 60)

    with :ok <- stop_existing(info, opts),
         :ok <- remove_container(opts) do
      finish_update(was_running, target, rollback_version, opts)
    end
  end

  defp finish_update(false, target, _rollback_version, opts) do
    Versions.set_installed(target, versions_server(opts))
    {:ok, target}
  end

  defp finish_update(true, target, rollback_version, opts) do
    :ok = report_stage(opts, "start", 75)

    case do_create(target, opts) do
      {:ok, id} -> finish_update_start(id, target, rollback_version, opts)
      # Never created — nothing to remove before the rollback recreate.
      {:error, reason} -> recreate_failed(reason, rollback_version, opts, remove_stale?: false)
    end
  end

  defp finish_update_start(id, target, rollback_version, opts) do
    case Docker.start_container(id, docker_opts(opts)) do
      :ok ->
        Versions.set_installed(target, versions_server(opts))
        :ok = report_stage(opts, "health", 85)

        case health_gate(opts) do
          :ok -> {:ok, target}
          {:error, :health_timeout} -> rollback(rollback_version, opts)
        end

      {:error, reason} ->
        # Created but never started — it's sitting under the fixed name and
        # would conflict with the rollback recreate's own create call.
        recreate_failed(reason, rollback_version, opts, remove_stale?: true)
    end
  end

  ## Rollback — two triggers share the same "clean up the broken container,
  ## recreate+start the previous version" mechanics (`recreate_previous/2`)
  ## but return different error tags: a health-gate timeout (the new
  ## container came up but failed its health check, so it's running and
  ## needs a `stop` before it can be removed) vs. a create/start failure (the
  ## new container never came up, so there's nothing to stop — and possibly
  ## nothing to remove either, see `finish_update/4` above).

  defp rollback(nil, _opts) do
    {:error, {:health_timeout, :no_rollback_version}}
  end

  defp rollback(rollback_version, opts) do
    with :ok <- Docker.stop_container(Container.name(), docker_opts(opts)),
         :ok <- remove_container(opts),
         :ok <- recreate_previous(rollback_version, opts) do
      {:error, {:health_timeout, :rolled_back}}
    else
      {:error, reason} -> {:error, {:rollback_failed, reason}}
    end
  end

  defp recreate_failed(reason, nil, _opts, _remove_opt) do
    {:error, {:recreate_failed, reason, :no_rollback_version}}
  end

  defp recreate_failed(reason, rollback_version, opts, remove_stale?: remove_stale?) do
    with :ok <- maybe_remove_stale(remove_stale?, opts),
         :ok <- recreate_previous(rollback_version, opts) do
      {:error, {:recreate_failed, reason, :rolled_back}}
    else
      {:error, rollback_reason} -> {:error, {:rollback_failed, rollback_reason}}
    end
  end

  defp maybe_remove_stale(false, _opts), do: :ok

  defp maybe_remove_stale(true, opts),
    do: remove_container(opts)

  defp recreate_previous(rollback_version, opts) do
    with {:ok, id} <- do_create(rollback_version, opts),
         :ok <- Docker.start_container(id, docker_opts(opts)) do
      Versions.set_installed(rollback_version, versions_server(opts))
      :ok
    end
  end

  ## Shared internals

  defp inspect_container(opts), do: Docker.inspect_container(Container.name(), docker_opts(opts))

  # Every remove goes through here so the socket the removed container
  # created can't outlive it — see the moduledoc's "The socket file outlives
  # Core" section.
  defp remove_container(opts) do
    case Docker.remove_container(Container.name(), docker_opts(opts)) do
      :ok -> unlink_core_socket()
      {:error, reason} -> {:error, reason}
    end
  end

  # `nil` is `config :vagus, :core_socket_path` set explicitly to "there is
  # never a socket here" (the test suite, host dev without one) — nothing to
  # unlink. Always `:ok`: a stale file surviving is a degraded transport
  # decision, not a failed lifecycle op.
  #
  # The path is config/module-derived (`Vagus.Core.Transport.socket_path/0`),
  # never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp unlink_core_socket do
    case Transport.socket_path() do
      nil ->
        :ok

      path ->
        log_unlink(path, File.rm(path))
        :ok
    end
  end

  defp log_unlink(_path, :ok), do: :ok
  defp log_unlink(_path, {:error, :enoent}), do: :ok

  defp log_unlink(path, {:error, reason}) do
    Logger.warning(
      "Vagus.Core.Lifecycle: could not unlink #{path} (#{inspect(reason)}) — " <>
        "Vagus will keep resolving the socket transport while Core is down"
    )
  end

  defp do_create(version, opts) do
    config = desired_spec(version, opts)
    Docker.create_container(config, Keyword.merge(docker_opts(opts), name: Container.name()))
  end

  # The spec a create would build right now — the fingerprint comparison in
  # `start_existing/3` and the create itself must read the exact same one.
  defp desired_spec(version, opts) do
    Container.create_config(version, create_config_opts(opts))
  end

  defp create_and_start(version, opts) do
    with {:ok, id} <- do_create(version, opts),
         :ok <- Docker.start_container(id, docker_opts(opts)) do
      health_gate(opts)
    end
  end

  defp stop_existing(info, opts) do
    timeout = stop_timeout_s(info)
    Docker.stop_container(Container.name(), Keyword.merge(docker_opts(opts), timeout: timeout))
  end

  defp stop_timeout_s(info) do
    case gracetime_ms(info) do
      {:ok, ms} -> 20 + div(ms, 1000)
      :error -> @fallback_stop_timeout_s
    end
  end

  defp gracetime_ms(%{"Config" => %{"Env" => env}}) when is_list(env) do
    env
    |> Enum.find_value(fn
      @gracetime_env_prefix <> rest -> Integer.parse(rest)
      _other -> nil
    end)
    |> case do
      {ms, _rest} -> {:ok, ms}
      _not_found_or_unparseable -> :error
    end
  end

  defp gracetime_ms(_info), do: :error

  defp health_gate(opts) do
    health = Keyword.get(opts, :health, fn -> Health.await_healthy() end)

    case health.() do
      :healthy -> refresh_http_config(opts)
      :timeout -> {:error, :health_timeout}
    end
  end

  # Always `:ok` — see the moduledoc's "HTTP-config refresh" section for why
  # a failed pull never fails the op that triggered it.
  defp refresh_http_config(opts) do
    refresh = Keyword.get(opts, :http_config, fn -> HttpConfig.refresh() end)
    _result = refresh.()
    :ok
  end

  defp image_of(%{"Config" => %{"Image" => image}}), do: image
  defp image_of(_info), do: nil

  # `nil` for a container created before spec fingerprinting existed (or by
  # hand) — never equal to a real fingerprint, so it always recreates.
  defp fingerprint_of(%{"Config" => %{"Labels" => labels}}) when is_map(labels) do
    Map.get(labels, Container.spec_fingerprint_label())
  end

  defp fingerprint_of(_info), do: nil

  defp running?(%{"State" => %{"Running" => running}}), do: running == true
  defp running?(_info), do: false

  defp create_config_opts(opts) do
    case Keyword.get(opts, :token) do
      nil -> []
      token -> [token: token]
    end
  end

  defp docker_opts(opts), do: Keyword.get(opts, :docker, [])

  defp versions_server(opts), do: Keyword.get(opts, :versions, Versions)

  defp resolve_start_version(opts) do
    version = Keyword.get(opts, :version) || Versions.installed(versions_server(opts))
    version_or_no_version(version)
  end

  defp resolve_installed_version(opts) do
    version_or_no_version(Versions.installed(versions_server(opts)))
  end

  defp version_or_no_version(nil), do: {:error, :no_version}
  defp version_or_no_version(version), do: {:ok, version}
end
