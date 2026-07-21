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

  alias Vagus.Addon.{Manager, State}
  alias Vagus.Runtime.Docker

  @default_data_root "/data"
  # Same charset as `Vagus.Addon.Manager`'s `@slug_dir_re` — a backup slug is
  # interpolated straight into both the `<dir>/<slug>.tar` store path and the
  # `<data_root>/addons/data/<slug>` restore target, so an upload (attacker-
  # controlled `backup.json`) or a hand-built restore request can't use a
  # `/`/`..`-laced slug to escape either directory.
  @slug_re ~r/^[-_a-z0-9]+$/

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
  — restore never accepts `"ALL"`, §A4). Per add-on: absent from the backup
  → `{:error, "Addon <slug> not in backup"}`; not currently installed →
  `{:error, "Addon <slug> is not installed"}` (restoring onto a fresh
  install would need a store re-install first — out of M4 scope). Otherwise:
  `Manager.stop` (tolerates not-running), replace the data dir wholesale
  with the backup's `data/` files, `State.put_options/2` the backed-up user
  options, and `Manager.start_slug` iff the backup recorded the add-on as
  `"started"`. The first per-addon error aborts the whole call (no
  partial-success reporting).
  """
  @spec restore_partial(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def restore_partial(backup_slug, addon_slugs, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    data_root = data_root(opts)

    case get(backup_slug, server) do
      {:ok, %{path: path}} ->
        with {:ok, tar} <- File.read(path) do
          Enum.reduce_while(addon_slugs, :ok, fn slug, :ok ->
            case restore_addon(tar, slug, data_root, opts) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
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

  ## Internals — restore_partial

  defp restore_addon(tar, slug, data_root, opts) do
    with :ok <- validate_slug(slug),
         {:ok, %{addon: addon, data: files}} <- Vagus.Backup.extract_addon(tar, slug) do
      case State.get(slug) do
        {:ok, _entry} -> do_restore(slug, addon, files, data_root, opts)
        :error -> {:error, "Addon #{slug} is not installed"}
      end
    else
      {:error, :not_in_backup} -> {:error, "Addon #{slug} not in backup"}
      {:error, {:invalid_slug, _}} -> {:error, "Addon #{slug} not in backup"}
    end
  end

  defp do_restore(slug, addon, files, data_root, opts) do
    Manager.stop(slug, opts)

    data_dir = Path.join([data_root, "addons", "data", slug])
    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)
    materialize(data_dir, files)

    :ok = State.put_options(slug, get_in(addon, ["user", "options"]) || %{})

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
  # paths, so materializing them under `data_dir` is safe.
  defp materialize(data_dir, files) do
    Enum.each(files, fn {rel, content} ->
      path = Path.join(data_dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)
  end

  defp validate_slug(slug) do
    if is_binary(slug) and Regex.match?(@slug_re, slug),
      do: :ok,
      else: {:error, {:invalid_slug, slug}}
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
