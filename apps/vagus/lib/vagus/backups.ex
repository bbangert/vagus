defmodule Vagus.Backups do
  @moduledoc """
  Owns the on-disk backup store (`<data_root>/backup/*.tar`) and the
  create/restore orchestration on top of `Vagus.Backup`'s pure tar format —
  the M4-P6-T2 wiring `docs/contract-2026.7-m4-addendum.md` §A4 calls for.

  A `GenServer` only for the directory listing (an in-memory `slug =>
  %{backup, path, size_bytes}` index, built by scanning `*.tar` at `init/1`
  and kept current via `reload/1`/`put_file/2`/`delete/2`); the actual file
  I/O and `Vagus.Addon.Manager`/`Vagus.Addon.State` orchestration in
  `create_partial/3` and `restore_partial/3` runs in the caller's process
  (mirroring `Vagus.Addon.Store.reload/1`'s own rationale — a slow backup
  shouldn't block a concurrent `list/1`/`get/2` read).

  Data root resolves exactly like `Vagus.Addon.Manager`'s: `config :vagus,
  :addon_data_root` (default `/data`), overridable via `opts[:data_root]`
  (host tests point it at a tmp dir); `opts[:dir]` overrides the backup
  directory outright.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.{Config, Manager, State}
  alias Vagus.Runtime.Docker

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
  `Vagus.Addon.Manager`, which re-resolves `data_root` from `opts`/
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
  is what both `create_partial/3` and the `POST /backups/new/upload` handler
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
  Builds + stores a partial backup of `addon_slugs` (already resolved by the
  caller — `"ALL"` is a router-level concern). `name` defaults to `"Partial
  backup <ISO8601 date>"`. Each add-on must already be installed
  (`Vagus.Addon.State`); the first missing slug aborts with
  `{:error, {:not_installed, slug}}` before anything is stopped/snapshotted.

  Hot/cold handling (§A4, `AppBackupMode`): a **cold** add-on that's running
  is `Manager.stop`'d before the snapshot and `Manager.start_slug`'d back
  after (restart failure is logged + tolerated — the backup itself already
  succeeded by that point); a **hot** add-on with `backup_pre`/`backup_post`
  runs those commands via `Vagus.Runtime.Docker.exec/3` before/after (a
  failing `backup_pre` aborts the whole backup and rolls back any add-ons
  already stopped/exec'd ahead of it). A stopped add-on is snapshotted as-is
  either way (§A4: "not running → skip").
  """
  @spec create_partial(String.t() | nil, [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_partial(name, addon_slugs, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    date = Keyword.get(opts, :date) || iso8601_now()
    name = name || "Partial backup #{date}"
    data_root = data_root(opts)

    with {:ok, prepared} <- prepare_addons(addon_slugs),
         {:ok, _} <- run_begin_phase(prepared, opts) do
      addon_specs = Enum.map(prepared, &build_addon_spec(&1, data_root))
      slug = derive_slug(date, name)

      spec = %{slug: slug, name: name, addons: addon_specs, supervisor_version: "vagus"}
      result = Vagus.Backup.create(spec, date: date)

      Enum.each(prepared, &end_backup(&1, opts))

      case result do
        {:ok, tar} -> put_file(tar, server)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Restores `addon_slugs` from `backup_slug` (already resolved by the caller
  — restore never accepts `"ALL"`, §A4). Two phases (W2):

    1. PRE-FLIGHT (no side effects): every requested slug is validated,
       confirmed installed (`Vagus.Addon.State`), and confirmed present +
       parseable in the backup tar (`Vagus.Backup.extract_addon/2`) — absent
       from the backup → `{:error, "Addon <slug> not in backup"}`; not
       currently installed → `{:error, "Addon <slug> is not installed"}`
       (restoring onto a fresh install would need a store re-install first —
       out of M4 scope). A failure here aborts the whole call before ANY
       add-on has been stopped or touched — a multi-slug restore no longer
       stops/wipes slugs 1..N-1 only to discover slug N is missing.
    2. APPLY, per add-on: `Manager.stop` (tolerates not-running); the
       backup's `data/` files are staged into a temp sibling of the data dir
       first (`stage_files/3`) and only swapped in via `File.rename/2` once
       staging fully succeeds — a mid-write failure (disk full) leaves the
       existing data dir completely untouched instead of half-wiped;
       `State.put_options/2` the backed-up user options (tolerating a
       concurrent uninstall having removed the slug — logged, restart
       skipped, not a raise); then `Manager.start_slug` iff the backup
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
        with {:ok, tar} <- File.read(path),
             {:ok, prepared} <- preflight_restore(tar, addon_slugs) do
          apply_restore(prepared, data_root, opts)
        end

      :error ->
        {:error, {:not_found, backup_slug}}
    end
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    dir = Keyword.get(opts, :dir) || Path.join(data_root(opts), "backup")
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
  # unlike `Vagus.Addon.Manager`'s data-dir writes (only reached via an
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

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp index_file(path, acc) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{backup: backup}} <- Vagus.Backup.read(bin) do
      Map.put(acc, backup["slug"], %{backup: backup, path: path, size_bytes: byte_size(bin)})
    else
      {:error, reason} ->
        Logger.warning("Vagus.Backups: skipping unreadable backup #{path}: #{inspect(reason)}")
        acc
    end
  end

  ## Internals — create_partial

  # Resolves every slug's installed State entry up front (before anything is
  # stopped) so a not-installed slug aborts cleanly with nothing touched yet.
  defp prepare_addons(addon_slugs) do
    Enum.reduce_while(addon_slugs, {:ok, []}, fn slug, {:ok, acc} ->
      case State.get(slug) do
        {:ok, %{config: config, state: state, user_options: user_options}} ->
          {:cont, {:ok, [{config, state, user_options} | acc]}}

        :error ->
          {:halt, {:error, {:not_installed, slug}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp build_addon_spec({config, state, user_options}, data_root) do
    %{
      slug: config.slug,
      name: config.name,
      version: config.version,
      data_dir: Path.join([data_root, "addons", "data", config.slug]),
      user: %{"options" => user_options, "version" => config.version},
      system: %{},
      state: state_string(state)
    }
  end

  defp state_string(:started), do: "started"
  defp state_string(_other), do: "stopped"

  # Runs `begin_backup/2` over every prepared add-on; on the first failure,
  # rolls back (`end_backup/2`) whichever add-ons were already begun so a
  # failed `backup_pre` doesn't leave an earlier add-on stopped indefinitely.
  defp run_begin_phase(prepared, opts) do
    Enum.reduce_while(prepared, {:ok, []}, fn item, {:ok, done} ->
      case begin_backup(item, opts) do
        :ok ->
          {:cont, {:ok, [item | done]}}

        {:error, reason} ->
          Enum.each(done, &end_backup(&1, opts))
          {:halt, {:error, reason}}
      end
    end)
  end

  # §A4 `begin_backup`: not running → skip regardless of mode; COLD → stop;
  # else (HOT) → run `backup_pre` if the add-on declares one.
  defp begin_backup({_config, :stopped, _user_options}, _opts), do: :ok

  defp begin_backup({config, :started, _user_options}, opts) do
    cond do
      config.backup == "cold" ->
        case Manager.stop(config.slug, opts) do
          :ok -> :ok
          {:error, reason} -> {:error, {:cold_stop_failed, config.slug, reason}}
        end

      # A native add-on has no container to `docker_exec` a backup_pre in. Its
      # snapshot-able state (the `addons` creds) is already persisted to
      # `<data_dir>/broker_state.json` by `Vagus.Mqtt.Broker.Provider`, so it
      # rides along in the tar with nothing to prepare (MQ-P4-T2).
      config.backend == :native ->
        :ok

      is_binary(config.backup_pre) ->
        case docker_exec(config, config.backup_pre, opts) do
          :ok -> :ok
          {:error, reason} -> {:error, {:backup_pre_failed, config.slug, reason}}
        end

      true ->
        :ok
    end
  end

  # §A4 `end_backup`: COLD → start back up; else (HOT) → run `backup_post`.
  # Tolerant (logged, never fails the whole backup) — the tar has already
  # been (or is about to be) written by the time this runs.
  defp end_backup({_config, :stopped, _user_options}, _opts), do: :ok

  defp end_backup({config, :started, _user_options}, opts) do
    cond do
      config.backup == "cold" ->
        case Manager.start_slug(config.slug, opts) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Vagus.Backups: restart after cold backup of #{config.slug} failed: #{inspect(reason)}"
            )

            :ok
        end

      # Native add-on: nothing to run post-tar (see begin_backup/2, MQ-P4-T2).
      config.backend == :native ->
        :ok

      is_binary(config.backup_post) ->
        case docker_exec(config, config.backup_post, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Vagus.Backups: backup_post for #{config.slug} failed: #{inspect(reason)}"
            )

            :ok
        end

      true ->
        :ok
    end
  end

  defp docker_exec(config, cmd, opts),
    do: Docker.exec("addon_#{config.slug}", cmd, Keyword.take(opts, [:socket]))

  # Mirrors the real Supervisor's slug derivation (§A4/plan): first 8 hex
  # chars of sha1(date <> name).
  defp derive_slug(date, name) do
    :crypto.hash(:sha, date <> name) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  ## Internals — restore_partial: pre-flight

  # Validates every requested slug — charset, installed, present + parseable
  # in the backup — before returning; nothing has been stopped or written
  # yet at this point, whichever slug (if any) fails.
  defp preflight_restore(tar, addon_slugs) do
    addon_slugs
    |> Enum.reduce_while({:ok, []}, fn slug, {:ok, acc} ->
      case preflight_addon(tar, slug) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp preflight_addon(tar, slug) do
    with :ok <- validate_slug(slug),
         {:ok, _entry} <- state_get(slug),
         {:ok, %{addon: addon, data: files}} <- Vagus.Backup.extract_addon(tar, slug) do
      {:ok, {slug, addon, files}}
    else
      {:error, {:invalid_slug, _}} -> {:error, "Addon #{slug} not in backup"}
      {:error, :not_installed} -> {:error, "Addon #{slug} is not installed"}
      {:error, :not_in_backup} -> {:error, "Addon #{slug} not in backup"}
    end
  end

  defp state_get(slug) do
    case State.get(slug) do
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

  defp restore_one(slug, addon, files, data_root, opts) do
    Manager.stop(slug, opts)

    data_dir = Path.join([data_root, "addons", "data", slug])

    case stage_files(data_dir, files, slug) do
      {:ok, staging_dir} -> swap_and_finish(slug, addon, data_dir, staging_dir, opts)
      {:error, _reason} = error -> error
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

  # `State.put_options/2` returning `:error` means a concurrent uninstall
  # removed the slug's `State` entry between pre-flight and here — tolerated
  # (logged, restart skipped for this slug) rather than the old `:ok = ...`
  # match, which would raise (surfacing as a 500) instead of the honest
  # partial-failure this already is.
  defp finish_restore(slug, addon, opts) do
    case State.put_options(slug, get_in(addon, ["user", "options"]) || %{}) do
      :ok ->
        maybe_start(slug, addon, opts)

      :error ->
        Logger.warning(
          "Vagus.Backups: #{slug} was uninstalled mid-restore — options not restored, restart skipped"
        )

        :ok
    end
  end

  defp maybe_start(slug, addon, opts) do
    if addon["state"] == "started" do
      case Manager.start_slug(slug, opts) do
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
