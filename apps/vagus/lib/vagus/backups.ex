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
         {:ok, %{config: config}} <- state_get(slug),
         {:ok, %{addon: addon, data: files}} <- Vagus.Backup.extract_addon_file(path, slug) do
      {:ok, {slug, config, addon, files}}
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

  defp restore_apps(prepared, data_root, opts) do
    Enum.reduce_while(prepared, :ok, fn {slug, config, addon, files}, :ok ->
      case restore_app(slug, config, addon, files, data_root, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:restore, slug, reason}}}
      end
    end)
  end

  # An op that never ran (the app busy or gone) leaves the staging dir
  # behind; one that ran has swapped it in or removed it.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp restore_app(slug, config, addon, files, data_root, opts) do
    data_dir = Path.join([data_root, "addons", "data", slug])

    with {:ok, staging_dir} <- stage_files(data_dir, files) do
      options = restorable_options(slug, config, addon)
      result = App.restore(slug, staging_dir, options, addon["state"] == "started", opts)
      File.rm_rf(staging_dir)
      result
    end
  end

  # A sibling of `data_dir`, so the app's swap is a rename on one filesystem
  # and a write that fails here (disk full) leaves its data untouched.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp stage_files(data_dir, files) do
    parent = Path.dirname(data_dir)
    unique = System.unique_integer([:positive])
    staging_dir = Path.join(parent, ".restore-#{Path.basename(data_dir)}-#{unique}")

    with :ok <- File.mkdir_p(staging_dir),
         :ok <- materialize(staging_dir, files) do
      {:ok, staging_dir}
    else
      {:error, _reason} = error ->
        File.rm_rf(staging_dir)
        error
    end
  end

  # The tar's `user.options` validated against the installed schema, as a
  # save to `POST /addons/{slug}/options` is: a `hassio_role: backup` app can
  # upload a tar and restore it onto another app, so the tar is the less
  # trusted input. This bounds the options only, and only as far as the
  # schema is narrow: an app without one accepts anything, as upstream's
  # does, and the tar's data is swapped in as it is. Options that do not
  # validate are dropped and the current ones kept, rather than failing the
  # restore: a schema that tightened since the backup (back up at v1, update
  # to v2, restore) must not cost the user the data they restored. The raw
  # map is kept, as a save keeps it.
  defp restorable_options(slug, config, addon) do
    options = get_in(addon, ["user", "options"]) || %{}

    case OptionsSchema.effective(config.schema, config.options, options) do
      {:ok, _validated} ->
        options

      {:error, reason} ->
        Logger.warning(
          "Vagus.Backups: #{slug}'s backed-up options do not validate against its " <>
            "installed schema (#{reason}) — keeping the current options, restore continuing"
        )

        nil
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

  defp data_root(opts),
    do:
      Keyword.get(
        opts,
        :data_root,
        Application.get_env(:vagus, :addon_data_root, @default_data_root)
      )
end
