defmodule Vagus.Addon.Update do
  @moduledoc """
  Updates an installed add-on to the version its store repository currently
  advertises (`POST /store/addons/{slug}/update`).

  Structurally a mirror of `Vagus.Core.Lifecycle.do_update/2`, which does the
  same job for HA Core. Same ordering, same rollback discipline, same lock
  semantics — deliberately, so the two read alike:

    1. non-blocking `{:addon_lifecycle, slug}` lock → `{:error, :busy}` → 409
    2. resolve the installed entry (`:not_installed`) and the store entry
       (`:not_in_store` — the *detached* case: installed, but its repository
       no longer lists it)
    3. equal versions → `{:error, :no_update_available}`
    4. capture the old config **before any mutation** — it is the rollback
       target, exactly as Core captures `installed` up front
    5. re-validate the persisted `user_options` against the *new* schema
    6. optional pre-update partial backup when `backup: true`
    7. **pull the new image** — a failed pull must leave the install
       completely untouched
    8. stop if it was running (which also removes the container)
    9. commit the new config to `Vagus.Addon.State`
    10. start again **only if it was running** before
    11. remove the superseded image, but only when the tag actually changed

  ## Why the pull comes before any mutation

  Steps 2-7 are all "can this update possibly work?" checks and none of them
  touch the install. By the time anything is stopped, the new image is on disk
  and the options are known-good. The failure mode this avoids is the
  expensive one: stopping a working add-on and *then* discovering the image
  can't be fetched.

  Within that prefix the order is cheapest-first, which is why option
  validation runs *before* the backup and the pull rather than after them as
  the plan's numbering had it. All three are side-effect-free with respect to
  the install, so the observable behaviour is identical either way — but
  discovering unusable options after downloading several hundred MB, on a
  device that may be on a metered or slow link, is pure waste.

  ## Options are re-validated — a deliberate divergence

  Upstream carries `user_options` forward unchecked. Vagus validates them
  against the new version's schema first and refuses the update if they no
  longer fit, naming the offending key. `Vagus.Addon.State` re-parses config
  on load, so a persisted options blob that the new schema rejects would
  otherwise surface at next boot — far from the cause, and looking like
  corruption rather than an update that should not have happened.

  The cost is real: an add-on that tightens its schema between versions
  becomes un-updatable until its options are fixed. That is the safe
  direction to fail, and the error says which key.

  ## Job progress

  When the router passes `opts[:job]` (a `Vagus.Jobs` uuid), each step below
  reports a stage transition — that is what moves the HA UI's progress bar,
  since Core subscribes to `addon_manager_update` job events by name. The
  numbers are coarse waypoints, not measurements: byte-level pull progress
  needs the engine's layer stream and is an explicitly-recorded follow-up.
  With no `:job` every report is a no-op, so the sync/background/untracked
  paths run identical code. The router owns create/finish; this module only
  reports stages.

  This can run for minutes; on the sync path Bandit's 900 s `read_timeout` is
  what bounds the caller, and with `background: true` the router answers
  `{job_id}` immediately and runs this in a supervised task.

  ## Old images are reclaimed, best-effort

  Add-on images run to hundreds of MB, so leaving the superseded one behind
  would grow the data partition without bound across updates. After a
  successful swap the old image ref is removed via
  `Vagus.Addon.Backend.remove_image/2` — but only when the resolved ref
  actually differs, since an add-on whose version moves without its image tag
  changing would otherwise delete the image it is still running.

  Failure is logged and ignored. The update has already succeeded by that
  point, and the most likely failure is precisely the one that should not be
  fatal: the image is still referenced by another container, so the engine
  refuses. Turning that into an update error would report a failure that did
  not happen.
  """

  require Logger

  alias Vagus.Addon.{Config, Manager, OptionsSchema, State, Store}

  @typedoc "What changed, for the caller's log line."
  @type result :: %{slug: String.t(), from: String.t(), to: String.t()}

  @doc """
  Updates `slug` to the store's current version.

  `opts[:backup]` takes a partial backup of the add-on first; a backup
  failure aborts the update before anything is mutated. `opts[:backend]` and
  `opts[:data_root]` are passed straight through to `Vagus.Addon.Manager`.

  State and the store are read through their globally-named processes rather
  than injected: `Manager` resolves `Vagus.Addon.State` by name internally
  (see its `record_state/3`), so an injected server here would desync from
  the one `Manager.start/2` and `stop/2` actually write to. Tests seed the
  real processes, the same way the add-on lifecycle router tests do.
  """
  @spec update(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def update(slug, opts \\ []) when is_binary(slug) do
    # `retries: 0`, matching `Vagus.Core.Lifecycle` — a concurrent lifecycle
    # operation on this slug means "come back later" (409), not a queue of
    # Bandit workers waiting behind a multi-minute update.
    #
    # Everything inside uses `Manager`'s **unlocked** entry points
    # (`stop_holding_lock/2`, `start_holding_lock/2`). Calling the locking
    # public functions here would be a real bug and not an obvious one:
    # `:global` locks are not counted, so a nested acquire by the same
    # requester is a no-op and the nested *release* deletes the resource,
    # dropping this lock while the swap below is still mid-flight. Verified
    # empirically; `Vagus.Core.Lifecycle` avoids it the same way.
    case :global.trans(
           {{:addon_lifecycle, slug}, self()},
           fn -> do_update(slug, opts) end,
           [node()],
           0
         ) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  defp do_update(slug, opts) do
    with {:ok, installed} <- fetch_installed(slug, opts),
         {:ok, target} <- fetch_target(slug, opts),
         :ok <- check_differs(installed.config.version, target.version),
         :ok <- report_stage(opts, "validate_options", 5),
         :ok <- check_options(target, installed),
         :ok <- maybe_backup(slug, installed, opts),
         :ok <- report_stage(opts, "pull_image", 20),
         :ok <- pull(target, opts) do
      swap(slug, installed, target, opts)
    end
  end

  # Stage waypoints for the job's progress bar (moduledoc "Job progress").
  # Always `:ok`, so it can sit in a `with` chain without altering it.
  defp report_stage(opts, stage, progress) do
    Vagus.Jobs.update(
      Keyword.get(opts, :job),
      [stage: stage, progress: progress],
      Keyword.get(opts, :jobs_server, Vagus.Jobs)
    )
  end

  ## Resolution — nothing here mutates

  defp fetch_installed(slug, _opts) do
    case State.get(slug) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_installed}
    end
  end

  # The store entry's own `config.slug` is the bare add-on slug; installed
  # add-ons run under the store slug. `handle_install` does the same rename,
  # and the update has to match it or the new config would be persisted under
  # a different key than the one being updated.
  defp fetch_target(slug, _opts) do
    case Store.get(slug) do
      {:ok, %{config: config}} -> {:ok, %{config | slug: slug}}
      :error -> {:error, :not_in_store}
    end
  end

  defp check_differs(version, version), do: {:error, :no_update_available}
  defp check_differs(_installed, _target), do: :ok

  defp check_options(target, %{user_options: user_options}) do
    case OptionsSchema.effective(target.schema, target.options, user_options) do
      {:ok, _effective} -> :ok
      {:error, reason} -> {:error, {:invalid_options, reason}}
    end
  end

  defp maybe_backup(slug, installed, opts) do
    if Keyword.get(opts, :backup, false) do
      :ok = report_stage(opts, "backup", 10)
      name = "addon_#{slug}_#{installed.config.version}"

      case backups().create_partial(name, [slug], backup_opts(opts)) do
        {:ok, _backup_slug} -> :ok
        {:error, reason} -> {:error, {:backup_failed, reason}}
      end
    else
      :ok
    end
  end

  defp pull(target, opts) do
    case Manager.install(target, manager_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pull, reason}}
    end
  end

  ## The mutating half

  defp swap(slug, installed, target, opts) do
    was_running = installed.state == :started
    old_config = installed.config
    # Always a map: `State` defaults it on both the fresh-entry and
    # disk-decode paths, so there is no nil to guard against here.
    user_options = installed.user_options

    with :ok <- stop_if_running(slug, was_running, opts) do
      :ok = report_stage(opts, "commit", 80)
      commit(target, user_options, opts)
      restart_if_running(slug, was_running, target, old_config, user_options, opts)
    end
  end

  # `Manager.stop/1` removes the container as well (§A1.1 — the real
  # Supervisor's stop removes it and start always re-creates), so there is no
  # separate remove step here the way Core needs one.
  defp stop_if_running(_slug, false, _opts), do: :ok

  defp stop_if_running(slug, true, opts) do
    :ok = report_stage(opts, "stop", 70)

    case Manager.stop_holding_lock(slug, manager_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:stop, reason}}
    end
  end

  # Committed while stopped: if the start below fails, the rollback writes the
  # old config straight back, and a crash between the two leaves a coherent
  # "installed but stopped at the new version" rather than a config that
  # disagrees with the container that is actually running.
  defp commit(target, user_options, _opts) do
    State.put(target, :stopped, user_options: user_options)
  end

  defp restart_if_running(slug, false, target, old_config, _user_options, opts) do
    reclaim_old_image(old_config, target, opts)
    {:ok, result(slug, old_config, target)}
  end

  defp restart_if_running(slug, true, target, old_config, user_options, opts) do
    :ok = report_stage(opts, "start", 90)

    case Manager.start_holding_lock(
           target,
           Keyword.put(manager_opts(opts), :user_options, user_options)
         ) do
      {:ok, _started} ->
        reclaim_old_image(old_config, target, opts)
        {:ok, result(slug, old_config, target)}

      {:error, reason} ->
        rollback(slug, reason, old_config, user_options, opts)
    end
  end

  ## Rollback — mirrors `Lifecycle.rollback/2` / `recreate_failed/4`, including
  ## the distinction between "we put it back" and "we could not put it back",
  ## which is the difference between an annoying failure and a broken add-on.

  defp rollback(slug, cause, old_config, user_options, opts) do
    State.put(old_config, :stopped, user_options: user_options)

    case Manager.start_holding_lock(
           old_config,
           Keyword.put(manager_opts(opts), :user_options, user_options)
         ) do
      {:ok, _started} ->
        Logger.warning(
          "Vagus.Addon.Update: #{slug} failed to start on the new version " <>
            "(#{inspect(cause)}); rolled back to #{old_config.version}"
        )

        {:error, {:rolled_back, cause}}

      {:error, rollback_reason} ->
        Logger.error(
          "Vagus.Addon.Update: #{slug} failed to start on the new version " <>
            "(#{inspect(cause)}) AND the rollback to #{old_config.version} " <>
            "failed (#{inspect(rollback_reason)}) — it is now stopped"
        )

        {:error, {:rollback_failed, rollback_reason}}
    end
  end

  # Only after the new version is actually in place, and only when there is an
  # old ref to remove and it differs from the new one.
  #
  # In practice the refs always differ when the version does: `image_ref/2`
  # ends every ref with `:#{version}`. The guard earns its keep on the nil
  # side — `image_ref/2` returns nil for `backend: :native` add-ons, which run
  # in-VM and have no image to reclaim. The inequality check is defensive
  # against a future ref scheme that does not embed the version.
  defp reclaim_old_image(old_config, target, opts) do
    old_ref = Manager.build_spec(old_config, opts).image
    new_ref = Manager.build_spec(target, opts).image

    if old_ref && old_ref != new_ref do
      case backend(opts).remove_image(old_ref, []) do
        :ok ->
          Logger.info("Vagus.Addon.Update: removed superseded image #{old_ref}")

        {:error, reason} ->
          # Expected when another add-on still references it. The update
          # already succeeded; this is housekeeping, not a failure.
          Logger.info(
            "Vagus.Addon.Update: kept #{old_ref} (#{inspect(reason)}) — " <>
              "still in use, or the engine declined"
          )
      end
    end
  rescue
    # A backend with no image concept may raise (`Microvm` raises on every
    # callback). Reclaiming is never worth undoing a completed update.
    error ->
      Logger.warning("Vagus.Addon.Update: image reclaim skipped: #{inspect(error)}")
      :ok
  end

  defp backend(opts) do
    Keyword.get(opts, :backend) ||
      Application.get_env(:vagus, :addon_backend, Vagus.Addon.Backend.Container)
  end

  defp result(slug, %Config{version: from}, %Config{version: to}),
    do: %{slug: slug, from: from, to: to}

  ## Injected collaborators

  defp backups, do: Application.get_env(:vagus, :backups_module, Vagus.Backups)

  defp backup_opts(opts), do: Keyword.take(opts, [:server, :data_root])
  defp manager_opts(opts), do: Keyword.take(opts, [:backend, :data_root])
end
