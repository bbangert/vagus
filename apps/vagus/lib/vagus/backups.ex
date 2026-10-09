defmodule Vagus.Backups do
  @moduledoc """
  Owns the on-disk backup store (`<data_root>/backup/*.tar`) and the
  create/restore orchestration on top of `Vagus.Backup`'s pure tar format —
  the M4-P6-T2 wiring `docs/contract-2026.7-m4-addendum.md` §A4 calls for.

  A `GenServer` only for the directory listing (an in-memory `slug =>
  %{backup, path, size_bytes}` index, built by scanning `*.tar` at `init/1`
  and kept current via `reload/1`/`put_file/2`/`delete/2`); the actual file
  I/O and `Vagus.App` orchestration in
  `create_partial/3` and `restore_partial/3` runs in the caller's process
  (mirroring `Vagus.Addon.Store.reload/1`'s own rationale — a slow backup
  shouldn't block a concurrent `list/1`/`get/2` read).

  Data root resolves exactly like `Vagus.App.Steps`': `config :vagus,
  :addon_data_root` (default `/data`), overridable via `opts[:data_root]`
  (host tests point it at a tmp dir); `opts[:dir]` overrides the backup
  directory outright.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.{Config, OptionsSchema}
  alias Vagus.API.StaticData
  alias Vagus.App

  @default_data_root "/data"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The resolved backup directory (for callers that need the raw path)."
  @spec dir(GenServer.server()) :: String.t()
  def dir(server \\ __MODULE__), do: GenServer.call(server, :dir)

  @doc "All indexed backup entries (`%{backup, path, size_bytes}`)."
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "The entry for `slug`, or `:error` if unknown."
  @spec get(String.t(), GenServer.server()) :: {:ok, map()} | :error
  def get(slug, server \\ __MODULE__), do: GenServer.call(server, {:get, slug})

  @doc "Rescans the backup directory from scratch."
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload)

  @doc """
  Test/ops seam: repoints the running server at a different backup directory
  and rescans it. `init/1` only resolves the directory once at boot (unlike
  `Vagus.App.Steps`, which re-resolves `data_root` from `opts`/
  `Application.get_env` on every call) — a router-level test that needs the
  supervised singleton `Vagus.Backups` pointed at a tmp dir has to call this,
  the same way `Vagus.Addon.Store`'s tests seed its catalog directly via
  `{:put_catalog, ...}`. Tolerant of a `dir` that can't be created (logs +
  starts with an empty index) so an unwritable path never crashes the caller.
  """
  @spec set_dir(String.t(), GenServer.server()) :: :ok
  def set_dir(dir, server \\ __MODULE__), do: GenServer.call(server, {:set_dir, dir})

  @doc "Removes `slug`'s tar file + index entry. `:error` if `slug` isn't tracked."
  @spec delete(String.t(), GenServer.server()) :: :ok | :error
  def delete(slug, server \\ __MODULE__), do: GenServer.call(server, {:delete, slug})

  @doc """
  Validates `tar` (`Vagus.Backup.read/1`), writes it as `<slug>.tar` (the
  slug is read from the tar's own `backup.json`, not caller-supplied — this
  is what both `finish_partial/2` and the `POST /backups/new/upload` handler
  call), and indexes it. Returns `{:ok, slug}`.
  """
  @spec put_file(binary(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def put_file(tar, server \\ __MODULE__) when is_binary(tar) do
    with {:ok, %{backup: backup}} <- Vagus.Backup.read(tar),
         slug <- backup["slug"],
         :ok <- validate_slug(slug),
         path <- Path.join(dir(server), "#{slug}.tar"),
         :ok <- File.write(path, tar) do
      entry = %{backup: backup, path: path, size_bytes: byte_size(tar)}
      :ok = GenServer.call(server, {:put_index, slug, entry})
      {:ok, slug}
    end
  end

  @doc """
  `put_file/2` for a tar already on disk (the upload route's
  `Plug.Upload` spool file — audit C6): validated via
  `Vagus.Backup.read_file/1` (only `backup.json` is loaded, never the
  multi-GB tar) and `File.cp/2`'d into the backup dir rather than read
  into a BEAM binary and rewritten. The source file is the caller's to
  clean up (Plug deletes its spool after the request).
  """
  @spec put_path(Path.t(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def put_path(src, server \\ __MODULE__) do
    with {:ok, %{backup: backup}} <- Vagus.Backup.read_file(src),
         slug <- backup["slug"],
         :ok <- validate_slug(slug),
         path <- Path.join(dir(server), "#{slug}.tar"),
         :ok <- File.cp(src, path),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      entry = %{backup: backup, path: path, size_bytes: size}
      :ok = GenServer.call(server, {:put_index, slug, entry})
      {:ok, slug}
    end
  end

  @doc """
  Builds + stores a partial backup of `addon_slugs` (already resolved by the
  caller — `"ALL"` is a router-level concern). `name` defaults to `"Partial
  backup <ISO8601 date>"`. The first slug that is not installed aborts with
  `{:error, {:not_installed, slug}}` before any app is touched.

  Each app is snapshotted in turn by its own `backup` operation
  (`Vagus.App.backup/3`), which stops and starts a cold app itself, so
  nothing here stops or starts anything. A busy app fails the whole backup as
  `{:error, {:busy, slug}}`; the apps snapshotted before it need nothing
  undone.
  """
  @spec create_partial(String.t() | nil, [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_partial(name, addon_slugs, opts \\ []) do
    with :ok <- check_installed(addon_slugs),
         {:ok, handle} <- begin_partial(name, opts) do
      case snapshot_apps(addon_slugs, handle.staging_dir, opts) do
        :ok ->
          finish_partial(handle, addon_slugs)

        {:error, _reason} = error ->
          discard_partial(handle)
          error
      end
    end
  end

  @doc """
  Names a partial backup and creates its staging directory,
  `<backup dir>/.staging/<backup slug>/`, where each app's snapshot writes
  `<slug>.tar.gz`. Ended by `finish_partial/2` or `discard_partial/1`.
  """
  @spec begin_partial(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def begin_partial(name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    date = Keyword.get(opts, :date) || iso8601_now()
    name = name || "Partial backup #{date}"
    slug = derive_slug(date, name)
    staging_dir = Path.join([dir(server), ".staging", slug])
    File.rm_rf(staging_dir)

    case File.mkdir_p(staging_dir) do
      :ok ->
        handle = %{slug: slug, name: name, date: date, extra: Keyword.get(opts, :extra)}
        {:ok, Map.merge(handle, %{server: server, staging_dir: staging_dir})}

      {:error, reason} ->
        {:error, {:staging, reason}}
    end
  end

  @doc """
  Assembles and indexes the backup from the staged snapshot of every slug in
  `addon_slugs`; one missing is `{:error, {:not_staged, slug}}` and nothing
  is stored. The staging directory is removed either way.
  """
  @spec finish_partial(map(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def finish_partial(handle, addon_slugs) do
    with {:ok, inner} <- staged(handle.staging_dir, addon_slugs) do
      # `supervisor_version` is the emulated version the whole wire claims
      # (`StaticData`): a restoring HAOS compares it as a version, which the
      # old `"vagus"` literal made raise (C2). `extra` (C5) is the caller's
      # dict — Core keys automatic-backup identity + its own request date
      # off it.
      spec = %{
        slug: handle.slug,
        name: handle.name,
        addons: inner,
        supervisor_version: StaticData.supervisor_version(),
        extra: handle.extra
      }

      with {:ok, tar} <- Vagus.Backup.create(spec, date: handle.date),
           do: put_file(tar, handle.server)
    end
  after
    discard_partial(handle)
  end

  @spec discard_partial(map()) :: :ok
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def discard_partial(%{staging_dir: staging_dir}) do
    File.rm_rf(staging_dir)
    :ok
  end

  @doc """
  Restores `addon_slugs` from `backup_slug` (already resolved by the caller
  — restore never accepts `"ALL"`, §A4). Two phases (W2):

    1. PRE-FLIGHT (no side effects): every requested slug is validated,
       confirmed installed (`Vagus.App`), and confirmed present +
       parseable in the backup tar (`Vagus.Backup.extract_addon/2`) — absent
       from the backup → `{:error, "Addon <slug> not in backup"}`; not
       currently installed → `{:error, "Addon <slug> is not installed"}`
       (restoring onto a fresh install would need a store re-install first —
       out of M4 scope). A failure here aborts the whole call before ANY
       add-on has been stopped or touched — a multi-slug restore no longer
       stops/wipes slugs 1..N-1 only to discover slug N is missing.
    2. APPLY, per add-on: `App.stop_for_backup` (tolerates not-running); the
       backup's `data/` files are staged into a temp sibling of the data dir
       first (`stage_files/3`) and only swapped in via `File.rename/2` once
       staging fully succeeds — a mid-write failure (disk full) leaves the
       existing data dir completely untouched instead of half-wiped;
       `App.set/2` the backed-up user options (tolerating a
       concurrent uninstall having removed the slug — logged, restart
       skipped, not a raise); then `App.start_after_backup` iff the backup
       recorded the add-on as `"started"`.

  The first per-addon apply-phase error aborts the whole call (no
  partial-success reporting) as `{:error, {:restore, slug, reason}}`; a
  disk-full/permission `File` failure during staging is caught and returned
  the same way, never raised (which would otherwise surface as a generic
  500 instead of an honest error envelope).
  """
  @spec restore_partial(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def restore_partial(backup_slug, addon_slugs, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    data_root = data_root(opts)

    case get(backup_slug, server) do
      {:ok, %{path: path}} ->
        # File-based extraction (audit C6): only each requested add-on's own
        # inner tar is ever loaded, so restoring one add-on out of a
        # multi-GB backup no longer reads the whole tar into memory.
        with {:ok, prepared} <- preflight_restore(path, addon_slugs) do
          apply_restore(prepared, data_root, opts)
        end

      :error ->
        {:error, {:not_found, backup_slug}}
    end
  end

  ## GenServer

  @impl GenServer
  # A staging dir outlives a backup whose caller died before finishing it;
  # nothing else removes it.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    dir = Keyword.get(opts, :dir) || Path.join(data_root(opts), "backup")
    File.rm_rf(Path.join(dir, ".staging"))
    {:ok, %{dir: dir, index: ensure_and_scan(dir)}}
  end

  @impl GenServer
  def handle_call(:dir, _from, %{dir: dir} = state), do: {:reply, dir, state}

  def handle_call(:list, _from, %{index: index} = state), do: {:reply, Map.values(index), state}

  def handle_call({:get, slug}, _from, %{index: index} = state),
    do: {:reply, Map.fetch(index, slug), state}

  def handle_call(:reload, _from, %{dir: dir} = state),
    do: {:reply, :ok, %{state | index: ensure_and_scan(dir)}}

  def handle_call({:set_dir, dir}, _from, state),
    do: {:reply, :ok, %{state | dir: dir, index: ensure_and_scan(dir)}}

  def handle_call({:put_index, slug, entry}, _from, %{index: index} = state),
    do: {:reply, :ok, %{state | index: Map.put(index, slug, entry)}}

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def handle_call({:delete, slug}, _from, %{index: index} = state) do
    case Map.fetch(index, slug) do
      {:ok, %{path: path}} ->
        File.rm(path)
        {:reply, :ok, %{state | index: Map.delete(index, slug)}}

      :error ->
        {:reply, :error, state}
    end
  end

  ## Internals — directory scan

  # `File.mkdir_p/1` is tolerated (logged, empty index) rather than raised —
  # unlike `Vagus.App.Steps`' data-dir writes (only reached via an
  # explicit `install`/`start` call), this runs unconditionally at
  # `Vagus.Application` boot, and a `/data` that isn't writable yet (or ever,
  # e.g. a sandboxed `mix test` run) must not crash the whole app.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_and_scan(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        scan(dir)

      {:error, reason} ->
        Logger.warning("Vagus.Backups: could not create backup dir #{dir}: #{inspect(reason)}")
        %{}
    end
  end

  defp scan(dir) do
    dir
    |> Path.join("*.tar")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, acc -> index_file(path, acc) end)
  end

  # `read_file/1`, not `File.read` + `read/1` (audit C6): the boot-time scan
  # used to load every tar in the directory into memory — with one real
  # HAOS-sized backup on disk that was an OOM at `Vagus.Application` start.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp index_file(path, acc) do
    with {:ok, %{backup: backup}} <- Vagus.Backup.read_file(path),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      Map.put(acc, backup["slug"], %{backup: backup, path: path, size_bytes: size})
    else
      {:error, reason} ->
        Logger.warning("Vagus.Backups: skipping unreadable backup #{path}: #{inspect(reason)}")
        acc
    end
  end

  ## Internals — create_partial

  defp check_installed(addon_slugs) do
    case Enum.reject(addon_slugs, &App.installed?/1) do
      [] -> :ok
      [slug | _rest] -> {:error, {:not_installed, slug}}
    end
  end

  defp snapshot_apps(addon_slugs, staging_dir, opts) do
    Enum.reduce_while(addon_slugs, :ok, fn slug, :ok ->
      case App.backup(slug, staging_dir, opts) do
        {:ok, _path} -> {:cont, :ok}
        {:error, :busy} -> {:halt, {:error, {:busy, slug}}}
        {:error, :not_found} -> {:halt, {:error, {:not_installed, slug}}}
        {:error, reason} -> {:halt, {:error, {:backup_failed, slug, reason}}}
      end
    end)
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp staged(staging_dir, addon_slugs) do
    inner = Enum.map(addon_slugs, &%{slug: &1, inner: Path.join(staging_dir, "#{&1}.tar.gz")})

    case Enum.find(inner, &(not File.regular?(&1.inner))) do
      nil -> {:ok, inner}
      %{slug: slug} -> {:error, {:not_staged, slug}}
    end
  end

  # Mirrors the real Supervisor's slug derivation (§A4/plan): first 8 hex
  # chars of sha1(date <> name).
  defp derive_slug(date, name) do
    :crypto.hash(:sha, date <> name) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  ## Internals — restore_partial: pre-flight

  # Validates every requested slug — charset, installed, present + parseable
  # in the backup — before returning; nothing has been stopped or written
  # yet at this point, whichever slug (if any) fails.
  defp preflight_restore(path, addon_slugs) do
    addon_slugs
    |> Enum.reduce_while({:ok, []}, fn slug, {:ok, acc} ->
      case preflight_addon(path, slug) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp preflight_addon(path, slug) do
    with :ok <- validate_slug(slug),
         {:ok, _entry} <- state_get(slug),
         {:ok, %{addon: addon, data: files}} <- Vagus.Backup.extract_addon_file(path, slug) do
      {:ok, {slug, addon, files}}
    else
      {:error, {:invalid_slug, _}} -> {:error, "Addon #{slug} not in backup"}
      {:error, :not_installed} -> {:error, "Addon #{slug} is not installed"}
      {:error, :not_in_backup} -> {:error, "Addon #{slug} not in backup"}
      {:error, :too_large} -> {:error, "Addon #{slug}'s backup data exceeds the restore size cap"}
    end
  end

  defp state_get(slug) do
    case App.info(slug) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_installed}
    end
  end

  defp validate_slug(slug) do
    if Config.valid_slug?(slug),
      do: :ok,
      else: {:error, {:invalid_slug, slug}}
  end

  ## Internals — restore_partial: apply

  defp apply_restore(prepared, data_root, opts) do
    Enum.reduce_while(prepared, :ok, fn {slug, addon, files}, :ok ->
      case restore_one(slug, addon, files, data_root, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # `App.stop_for_backup/2`'s result is checked, not discarded: swapping the data
  # dir out from under a still-running container gives the add-on a
  # half-old/half-new view of its own `/data` and can corrupt what it writes
  # next. `:not_running`/`:not_found` are the expected benign cases (the
  # add-on was already stopped, or the container is gone) and proceed; a real
  # engine failure aborts this slug before anything is touched.
  defp restore_one(slug, addon, files, data_root, opts) do
    with :ok <- stop_for_restore(slug, opts) do
      data_dir = Path.join([data_root, "addons", "data", slug])

      case stage_files(data_dir, files, slug) do
        {:ok, staging_dir} -> swap_and_finish(slug, addon, data_dir, staging_dir, opts)
        {:error, _reason} = error -> error
      end
    end
  end

  defp stop_for_restore(slug, opts) do
    case App.stop_for_backup(slug, opts) do
      :ok ->
        :ok

      {:error, reason} when reason in [:not_running, :not_found] ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Vagus.Backups: refusing to restore #{slug} — it could not be stopped " <>
            "(#{inspect(reason)}); its data dir is untouched"
        )

        {:error, {:restore, slug, {:stop_failed, reason}}}
    end
  end

  # Stages the backup's `data/` files into a temp dir SIBLING of `data_dir`
  # (same parent, so the swap below is a same-filesystem, near-instant
  # `File.rename/2`) — nothing under `data_dir` itself is touched until
  # staging fully succeeds, so a mid-write failure (disk full) leaves the
  # existing data dir intact rather than half-wiped.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp stage_files(data_dir, files, slug) do
    parent = Path.dirname(data_dir)
    unique = System.unique_integer([:positive])
    staging_dir = Path.join(parent, ".restore-#{Path.basename(data_dir)}-#{unique}")

    with :ok <- safe_mkdir_p(staging_dir, slug),
         :ok <- materialize(staging_dir, files, slug) do
      {:ok, staging_dir}
    else
      {:error, _reason} = error ->
        File.rm_rf(staging_dir)
        error
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp swap_and_finish(slug, addon, data_dir, staging_dir, opts) do
    File.rm_rf(data_dir)

    case File.rename(staging_dir, data_dir) do
      :ok ->
        finish_restore(slug, addon, opts)

      {:error, reason} ->
        File.rm_rf(staging_dir)
        {:error, {:restore, slug, reason}}
    end
  end

  # `App.set/2` returning `:error` means a concurrent uninstall
  # removed the slug's entry between pre-flight and here — tolerated
  # (logged, restart skipped for this slug) rather than the old `:ok = ...`
  # match, which would raise (surfacing as a 500) instead of the honest
  # partial-failure this already is.
  defp finish_restore(slug, addon, opts) do
    case restorable_options(slug, addon) do
      {:ok, options} ->
        case App.set(slug, options: options) do
          :ok ->
            maybe_start(slug, addon, opts)

          :error ->
            Logger.warning(
              "Vagus.Backups: #{slug} was uninstalled mid-restore — options not restored, restart skipped"
            )

            :ok
        end

      :reject ->
        maybe_start(slug, addon, opts)
    end
  end

  # The tar's `user.options` validated against the INSTALLED add-on's schema,
  # exactly as `POST /addons/{slug}/options` validates a save
  # (`Vagus.API.Router`'s `validate_options_key/2`). A save path and a restore
  # path that disagree about what is a legal option map is the same class of
  # bug the save-side validation was written to prevent, and the tar is the
  # less trustworthy of the two inputs: since the 2026-07-29 audit's A4 the
  # `/backups` family is reachable by a `hassio_role: backup` add-on, and both
  # the tar's bytes and the slug it names are then caller-controlled.
  #
  # Scope, stated precisely because an earlier version of this comment claimed
  # more (review round 2). This closes the *options* half only, and only as
  # far as the victim's own schema is narrow: `OptionsSchema.validate/3`
  # returns options unchanged for `schema: false`, so an add-on that declares
  # no schema still accepts anything — by its own declaration, and matching
  # upstream. The larger half of a hostile restore is the `/data` swap in
  # `swap_and_finish/5`, which this does not touch at all. Bounding *that*
  # needs the restore surface itself gated, not the options validated.
  #
  # Invalid options are dropped with a warning rather than failing the
  # restore: the data dir has already been swapped by this point, and an
  # add-on whose schema legitimately tightened between the backup and now
  # (back up at v1, upgrade to v2, restore) must not be left half-restored by
  # a hard failure. The add-on keeps the options it already had, which is the
  # conservative end of both cases.
  defp restorable_options(slug, addon) do
    options = get_in(addon, ["user", "options"]) || %{}

    case App.info(slug) do
      # Not installed. Pass through — `App.set/2` reports
      # `:error` itself and the caller logs the uninstalled-mid-restore case.
      :error ->
        {:ok, options}

      {:ok, %{config: config}} ->
        case OptionsSchema.effective(config.schema, config.options, options) do
          {:ok, _validated} ->
            # Persist the RAW map, not the validated one — same as the save
            # path, which stores what the caller sent and re-validates on
            # every read.
            {:ok, options}

          {:error, reason} ->
            Logger.warning(
              "Vagus.Backups: #{slug}'s backed-up options do not validate against its " <>
                "installed schema (#{reason}) — keeping the current options, restore continuing"
            )

            :reject
        end
    end
  end

  defp maybe_start(slug, addon, opts) do
    if addon["state"] == "started" do
      case App.start_after_backup(slug, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # `Vagus.Backup.extract_addon/2` already zip-slip-guards these relative
  # paths, so materializing them under `dir` is safe. Non-bang `File` calls
  # + `reduce_while` (not `File.mkdir_p!`/`File.write!`) so a disk-full/
  # permission failure returns an honest `{:error, {:restore, slug, reason}}`
  # instead of raising and 500ing the router.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp materialize(dir, files, slug) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(dir, rel)

      case safe_mkdir_p(Path.dirname(path), slug) do
        :ok ->
          case File.write(path, content) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:restore, slug, reason}}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp safe_mkdir_p(dir, slug) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:restore, slug, reason}}
    end
  end

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp data_root(opts),
    do:
      Keyword.get(
        opts,
        :data_root,
        Application.get_env(:vagus, :addon_data_root, @default_data_root)
      )
end
