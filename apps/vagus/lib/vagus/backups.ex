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

  alias Vagus.Addon.Config
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
  Names a partial backup and creates its staging directory under
  `staging_root/1`, where each app's snapshot writes `<slug>.tar.gz`. Ended
  by `finish_partial/2` or `discard_partial/1`.
  """
  @spec begin_partial(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def begin_partial(name, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    date = Keyword.get(opts, :date) || iso8601_now()
    name = name || "Partial backup #{date}"
    slug = derive_slug(date, name)
    root = staging_root(dir(server))
    # Unique: two backups of one name in one second share a slug.
    unique = Keyword.get_lazy(opts, :unique, fn -> System.unique_integer([:positive]) end)
    staging_dir = Path.join(root, "backup-#{slug}-#{unique}")

    # `mkdir`, not `mkdir_p`: a name already there is not this backup's.
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(staging_dir) do
      handle = %{slug: slug, name: name, date: date, extra: Keyword.get(opts, :extra)}
      {:ok, Map.merge(handle, %{server: server, staging_dir: staging_dir})}
    else
      {:error, reason} -> {:error, {:staging, reason}}
    end
  end

  @doc """
  Where backups are staged: beside the data root (`backup_dir` is
  `<data_root>/backup`), so outside every tree a `map:` key mounts into an
  app. Vagus writes, reads and removes there as root, and a symlink an app
  planted would be followed.
  """
  @spec staging_root(Path.t()) :: Path.t()
  def staging_root(backup_dir),
    do: backup_dir |> Path.dirname() |> Path.dirname() |> Path.join("staging")

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
  Restores `addon_slugs` from `backup_slug` (`"ALL"` is never accepted,
  §A4). Every slug is checked before any app is touched: installed, and
  present and parseable in the tar. Each app's data is then staged beside its
  data dir and handed to its own `restore` operation (`Vagus.App.restore/5`).
  The first failure aborts the rest as `{:error, {:restore, slug, reason}}`,
  a busy app's `reason` being `:busy`.
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
          restore_apps(prepared, data_root, opts)
        end

      :error ->
        {:error, {:not_found, backup_slug}}
    end
  end

  @doc """
  Removes the staging a backup or restore left when its caller died before
  finishing it, which nothing else removes. Only safe while no backup or
  restore can be in flight, so `Vagus.App.Units.sweep/0` runs it once per
  VM, at the first boot before any app is started.
  """
  @spec sweep_stale(keyword()) :: :ok
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  def sweep_stale(opts \\ []) do
    File.rm_rf(staging_root(backup_dir(opts)))
    sweep_restores(Path.join([data_root(opts), "addons", "data"]))
    :ok
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    dir = backup_dir(opts)
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

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_restores(parent) do
    for path <- Path.wildcard(Path.join(parent, ".restore-*"), match_dot: true) do
      case Regex.run(~r/\A\.restore-(.+)-\d+\.old\z/, Path.basename(path)) do
        [_all, slug] -> sweep_aside(path, Path.join(parent, slug), slug)
        nil -> File.rm_rf(path)
      end
    end
  end

  # A restore halted between its two renames left the app's data only in the
  # aside: it goes only once a data dir is back, and one that cannot move
  # back waits for the next boot.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_aside(path, data_dir, slug) do
    if File.dir?(data_dir) do
      File.rm_rf(path)
    else
      case File.rename(path, data_dir) do
        :ok ->
          Logger.warning("Vagus.Backups: #{slug}'s data moved back from #{path}")

        {:error, reason} ->
          Logger.error(
            "Vagus.Backups: #{slug}'s data could not move back from #{path} " <>
              "(#{inspect(reason)}); kept there"
          )
      end
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
         :ok <- installed(slug),
         {:ok, %{addon: addon, data: files}} <- Vagus.Backup.extract_addon_file(path, slug),
         {:ok, options, start?} <- addon_fields(addon) do
      {:ok, {slug, options, start?, files}}
    else
      {:error, {:invalid_slug, _}} -> {:error, "Addon #{slug} not in backup"}
      {:error, :not_installed} -> {:error, "Addon #{slug} is not installed"}
      {:error, :not_in_backup} -> {:error, "Addon #{slug} not in backup"}
      {:error, :too_large} -> {:error, "Addon #{slug}'s backup data exceeds the restore size cap"}
      {:error, :malformed} -> {:error, "Addon #{slug}'s backup is malformed"}
      {:error, %Jason.DecodeError{}} -> {:error, "Addon #{slug}'s backup is malformed"}
    end
  end

  # An uploaded backup's `addon.json` is any JSON the uploader wrote; read
  # here, before anything is staged, a wrong shape fails the whole restore.
  defp addon_fields(%{} = addon) do
    with {:ok, user} <- optional(addon["user"], &is_map/1),
         {:ok, options} <- optional(user && user["options"], &is_map/1),
         {:ok, state} <- optional(addon["state"], &is_binary/1) do
      {:ok, options || %{}, state == "started"}
    end
  end

  defp addon_fields(_addon), do: {:error, :malformed}

  defp optional(nil, _valid?), do: {:ok, nil}

  defp optional(value, valid?),
    do: if(valid?.(value), do: {:ok, value}, else: {:error, :malformed})

  defp installed(slug) do
    if App.installed?(slug), do: :ok, else: {:error, :not_installed}
  end

  defp validate_slug(slug) do
    if Config.valid_slug?(slug),
      do: :ok,
      else: {:error, {:invalid_slug, slug}}
  end

  ## Internals — restore_partial: apply

  defp restore_apps(prepared, data_root, opts) do
    Enum.reduce_while(prepared, :ok, fn {slug, options, start?, files}, :ok ->
      case restore_app(slug, {options, start?}, files, data_root, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:restore, slug, reason}}}
      end
    end)
  end

  # The staging dir is a sibling of the data dir, so the app's swap is a
  # rename on one filesystem and a write that fails here (disk full) leaves
  # its data untouched; the parent is mounted into no app. It is removed here
  # on every exit, a raise included, since an op that never ran (the app busy
  # or gone) leaves it and otherwise only the boot sweep would. The old data a
  # swap set aside is the op's own to remove: once it replies, the app is free
  # for an uninstall this could race. `opts[:app]` stands in for `Vagus.App`
  # in tests.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp restore_app(slug, {options, start?}, files, data_root, opts) do
    data_dir = Path.join([data_root, "addons", "data", slug])
    app = Keyword.get(opts, :app, App)

    with {:ok, staging_dir} <- restore_dir(data_dir, 3) do
      try do
        case materialize(staging_dir, files) do
          :ok -> app.restore(slug, staging_dir, options, start?, opts)
          {:error, reason} -> {:error, {:staging, reason}}
        end
      after
        File.rm_rf(staging_dir)
      end
    end
  end

  # `mkdir`, not `mkdir_p`: the counter restarts at every boot, and one left
  # by an earlier boot must not be merged into this restore.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp restore_dir(data_dir, tries) do
    parent = Path.dirname(data_dir)
    unique = System.unique_integer([:positive])
    staging_dir = Path.join(parent, ".restore-#{Path.basename(data_dir)}-#{unique}")

    case with(:ok <- File.mkdir_p(parent), do: File.mkdir(staging_dir)) do
      :ok -> {:ok, staging_dir}
      {:error, :eexist} when tries > 1 -> restore_dir(data_dir, tries - 1)
      {:error, reason} -> {:error, {:staging, reason}}
    end
  end

  # `Vagus.Backup.extract_addon/2` already zip-slip-guards these relative
  # paths, so materializing them under `dir` is safe. Non-bang `File` calls,
  # so a disk-full or permission failure is an error rather than a 500.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp materialize(dir, files) do
    Enum.reduce_while(files, :ok, fn {rel, content}, :ok ->
      path = Path.join(dir, rel)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, content) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp backup_dir(opts), do: Keyword.get(opts, :dir) || Path.join(data_root(opts), "backup")

  defp data_root(opts),
    do:
      Keyword.get(
        opts,
        :data_root,
        Application.get_env(:vagus, :addon_data_root, @default_data_root)
      )
end
