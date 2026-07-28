defmodule Vagus.Addon.Store.Assets do
  @moduledoc """
  Storage for the static files an add-on repository ships alongside each
  `config.yaml`. Four are fetched by the frontend from
  `/store/addons/{slug}/icon|logo|changelog|documentation` — `icon.png`,
  `logo.png`, `CHANGELOG.md`, `DOCS.md`. The fifth, `README.md`, has no route:
  it is read for its **content** and rendered into an add-on's detail payload
  as `long_description`, which is the whole body of the store page.

  The real Supervisor keeps a permanent `git clone` per repository and
  re-reads these off disk per request, caching only existence booleans.
  Vagus fetches tarballs and holds no checkout, so the bytes have to be
  retained at catalog-build time or lost. Where they are retained is decided
  once at boot by `Vagus.Addon.Store.AssetMode`:

    * `:memory` — an ETS table owned by the `Vagus.Addon.Store` GenServer.
      Dies with it and is rebuilt by the next reload. The default.
    * `:disk` — `<dirname of :addon_state_path>/store_assets/<repo_slug>/
      <addon_slug>/<file>`, written tmp+rename per file, mirroring
      `Vagus.Addon.State`'s write discipline. For boards under 1 GiB, so a
      large community repository's assets don't sit resident for the life of
      the node.
    * `:none` — retains nothing. `build_catalog/3`'s default, for callers
      (tests, one-off catalog builds) that only want parsed configs. The
      catalog's presence flags still report honestly what the repo carried;
      only the bytes are dropped.

  ## Why assets are keyed by `{repo_slug, addon_slug}`, not by store slug

  A store slug is `"<repo>_<addon>"`, which is **not injective**: repository
  `core` shipping `mqtt_broker` and repository `core_mqtt` shipping `broker`
  both render as `core_mqtt_broker`. The catalog is a map keyed on that
  string, so one of the two configs simply wins — but if assets were keyed the
  same way, the *loser's* icon could overwrite the winner's, and the store
  would serve one repository's config beside another's artwork. Keying on the
  pair keeps every repository's bytes in their own namespace, so the read
  path — which resolves the catalog entry first, and therefore knows which
  repository won — always gets the matching assets.

  Callers hold that pair as an `t:id/0`; `id/1` derives it from a catalog
  entry, which is all a request handler needs after its catalog lookup.

  ## Sizes are capped

  Icons and logos are capped at 1 MB each, changelog and documentation at
  256 KB each. An over-cap file is dropped with a log line and reported
  absent, which downstream renders exactly like a repository that never
  shipped one. The caps exist because these bytes are retained for the life
  of the catalog on a device with no swap.

  ## Icon/logo content is checked, not just retained

  `put/4` refuses an `:icon`/`:logo` write whose bytes don't start with the
  PNG signature. These bytes come from an add-on repository (attacker-
  controlled, in the sense that any configured repository can ship anything)
  and Phase 4 serves them **unauthenticated and same-origin with the HA
  frontend**. HTML in `icon.png` that a browser content-sniffs past a wrong
  or missing `Content-Type` is stored XSS with an HA token in reach. Checked
  at write time, not read time, so a bad file never lands on disk in the
  first place — `nosniff` + a restrictive CSP on the response is defence in
  depth behind this, not a substitute for it. `changelog`/`documentation`
  are served as `text/plain` and carry no such check.

  Every path is built from a `Vagus.Addon.Config.valid_slug?/1`-gated segment
  and a compile-time filename constant. No request input reaches the
  filesystem.
  """

  require Logger

  alias Vagus.Addon.Config

  @filenames %{
    icon: "icon.png",
    logo: "logo.png",
    changelog: "CHANGELOG.md",
    documentation: "DOCS.md",
    readme: "README.md"
  }

  @caps %{
    icon: 1_048_576,
    logo: 1_048_576,
    changelog: 262_144,
    documentation: 262_144,
    readme: 262_144
  }

  # Spelled out rather than `Map.keys(@filenames)`: map key order is an
  # implementation detail, not a contract, so deriving it would make
  # `kinds/0`'s documented ordering a promise the runtime never made.
  #
  # `:readme` is the odd one: it has no route of its own. It backs the
  # `long_description` **string** in an add-on's detail payload — the body of
  # the store page, which the frontend renders as markdown under the install
  # card — so it is read for content rather than served as bytes, and its
  # presence flag never reaches the wire.
  @kinds [:icon, :logo, :changelog, :documentation, :readme]

  # ...and this keeps the explicit list honest: adding a filename or a cap
  # without adding the kind (or vice versa) fails the build rather than
  # silently dropping an asset type.
  if Enum.sort(@kinds) != Enum.sort(Map.keys(@filenames)) or
       Enum.sort(@kinds) != Enum.sort(Map.keys(@caps)) do
    raise "Vagus.Addon.Store.Assets: @kinds, @filenames and @caps disagree"
  end

  @dir "store_assets"

  @typedoc "The retained files: four served as bytes, plus the README."
  @type kind :: :icon | :logo | :changelog | :documentation | :readme

  @typedoc """
  What a set of assets belongs to: `{repo_slug, addon_slug}`, e.g.
  `{"core", "mosquitto"}`. Deliberately not the store slug — see the
  moduledoc on why `"<repo>_<addon>"` is not a safe key.
  """
  @type id :: {String.t(), String.t()}

  @typedoc """
  Where assets go. Built by `init/2` and carried in the store's state — the
  `:memory` variant holds the ETS table itself rather than a registered name,
  so concurrent `Vagus.Addon.Store` instances (async tests) never collide.
  """
  @opaque t :: {:memory, :ets.table()} | {:disk, Path.t()} | :none

  @doc "The retained kinds, in a stable order."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The repository filename a kind is read from."
  @spec filename(kind()) :: String.t()
  def filename(kind) when kind in @kinds, do: Map.fetch!(@filenames, kind)

  @doc "The size cap, in bytes, above which a kind is dropped."
  @spec max_bytes(kind()) :: pos_integer()
  def max_bytes(kind) when kind in @kinds, do: Map.fetch!(@caps, kind)

  @doc "A handle that retains nothing."
  @spec none() :: t()
  def none, do: :none

  @doc """
  The asset id of a catalog entry — everything a request handler needs after
  the catalog lookup it was going to do anyway.
  """
  @spec id(map()) :: id()
  def id(%{repository: repo_slug, config: %{slug: addon_slug}}), do: {repo_slug, addon_slug}

  @doc """
  Builds the storage handle for `mode`, to be held in
  `Vagus.Addon.Store`'s state. Call from the owning process: in `:memory`
  mode the ETS table is owned by (and dies with) the caller.

  `opts[:root]` overrides the disk root, for tests. `:disk` with no
  resolvable root — no `:addon_state_path` configured, as on `:host` —
  degrades to `:memory` with a warning rather than failing to boot the store.
  """
  @spec init(:memory | :disk | :none, keyword()) :: t()
  def init(mode, opts \\ [])

  def init(:none, _opts), do: :none

  def init(:memory, _opts) do
    {:memory, :ets.new(:vagus_store_assets, [:set, :public, read_concurrency: true])}
  end

  def init(:disk, opts) do
    case Keyword.get(opts, :root) || configured_root() do
      root when is_binary(root) ->
        {:disk, root}

      nil ->
        Logger.warning(
          "Vagus.Addon.Store.Assets: :disk mode but no :addon_state_path to anchor " <>
            "#{@dir}/ under; retaining assets in memory instead"
        )

        init(:memory, opts)
    end
  end

  # The 8-byte PNG signature (`\x89PNG\r\n\x1a\n`). `:icon`/`:logo` content
  # must start with it; `:changelog`/`:documentation` aren't checked.
  @png_signature <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

  @doc """
  Retains `binary` as `id`'s `kind`, replacing whatever was there.

  Returns `{:error, :too_large}` above the kind's cap so the caller can
  report the asset absent, `{:error, :invalid_id}` when either half of the
  id would not be a safe path segment, and `{:error, :invalid_content}` for
  an `:icon`/`:logo` binary that doesn't start with the PNG signature (see
  the moduledoc for why this is checked at write time).
  """
  @spec put(id(), kind(), binary(), t()) :: :ok | {:error, term()}
  def put(id, kind, binary, mode) when kind in @kinds and is_binary(binary) do
    cond do
      byte_size(binary) > max_bytes(kind) -> {:error, :too_large}
      not valid_id?(id) -> {:error, :invalid_id}
      not valid_content?(kind, binary) -> {:error, :invalid_content}
      true -> do_put(id, kind, binary, mode)
    end
  end

  defp valid_content?(kind, binary) when kind in [:icon, :logo] do
    byte_size(binary) >= byte_size(@png_signature) and
      binary_part(binary, 0, byte_size(@png_signature)) == @png_signature
  end

  defp valid_content?(_kind, _binary), do: true

  defp do_put(_id, _kind, _binary, :none), do: :ok

  defp do_put({repo, addon}, kind, binary, {:memory, table}) do
    true = :ets.insert(table, {{repo, addon, kind}, binary})
    :ok
  end

  # `root` is the configured asset root (derived from `:addon_state_path`),
  # never request input — and the two slug segments below it are gated by
  # `valid_slug?/1` in `put/4` and then component-checked by `asset_dir/3`.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_put(id, kind, binary, {:disk, root}) do
    with :ok <- File.mkdir_p(root),
         {:ok, dir} <- asset_dir(root, id, :create) do
      write_atomic(Path.join(dir, filename(kind)), binary)
    end
  end

  @doc "The retained bytes for `id`'s `kind`, or `:error` if none."
  @spec get(id(), kind(), t()) :: {:ok, binary()} | :error
  def get(id, kind, mode) when kind in @kinds do
    if valid_id?(id), do: do_get(id, kind, mode), else: :error
  end

  defp do_get(_id, _kind, :none), do: :error

  defp do_get({repo, addon}, kind, {:memory, table}) do
    case :ets.lookup(table, {repo, addon, kind}) do
      [{_key, binary}] -> {:ok, binary}
      [] -> :error
    end
  end

  defp do_get(id, kind, {:disk, root}) do
    case asset_dir(root, id, :existing) do
      {:ok, dir} -> read_capped(Path.join(dir, filename(kind)), kind)
      {:error, _reason} -> :error
    end
  end

  # The caps are enforced on write, so anything over one here was not written
  # by us. Refusing rather than reading keeps a tampered-with or legacy
  # oversized file from turning into a large allocation per request — Phase 4
  # serves these unauthenticated, on the <1 GiB board `:disk` mode selects.
  #
  # `lstat` also means a *file*-level symlink is refused: `asset_dir/3` checks
  # the directory components, but a symlink at `icon.png` itself would
  # otherwise be followed and read out as root.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_capped(path, kind) do
    cap = max_bytes(kind)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= cap ->
        read(path)

      {:ok, %File.Stat{type: :regular, size: size}} ->
        Logger.warning(
          "Vagus.Addon.Store.Assets: refusing to read #{path} (#{size} bytes, cap #{cap})"
        )

        :error

      {:ok, %File.Stat{type: type}} ->
        Logger.warning("Vagus.Addon.Store.Assets: refusing to read #{path} (#{inspect(type)})")
        :error

      {:error, _reason} ->
        :error
    end
  end

  @doc """
  Drops `id`'s `kind`, if retained. Called when a reload finds an add-on no
  longer shipping a file it used to, so a stale icon can't outlive the file
  that produced it.
  """
  @spec delete(id(), kind(), t()) :: :ok
  def delete(id, kind, mode) when kind in @kinds do
    if valid_id?(id), do: do_delete(id, kind, mode), else: :ok
  end

  defp do_delete(_id, _kind, :none), do: :ok

  defp do_delete({repo, addon}, kind, {:memory, table}) do
    true = :ets.delete(table, {repo, addon, kind})
    :ok
  end

  defp do_delete(id, kind, {:disk, root}) do
    case asset_dir(root, id, :existing) do
      {:ok, dir} -> rm(Path.join(dir, filename(kind)))
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Drops every retained asset whose id is not in `ids`, and returns how many
  ids were dropped.

  Run after a catalog swap: an add-on removed from its repository (or a
  repository removed from the config) otherwise leaks its assets for the life
  of the node in `:memory` mode, and forever in `:disk` mode.
  """
  @spec prune([id()], t()) :: {:ok, non_neg_integer()}
  def prune(ids, mode) do
    {:ok, do_prune(MapSet.new(ids), mode)}
  end

  defp do_prune(_keep, :none), do: 0

  defp do_prune(keep, {:memory, table}) do
    stale =
      :ets.foldl(
        fn {{repo, addon, _kind}, _binary}, acc ->
          id = {repo, addon}
          if MapSet.member?(keep, id), do: acc, else: MapSet.put(acc, id)
        end,
        MapSet.new(),
        table
      )

    for {repo, addon} <- stale, kind <- @kinds, do: :ets.delete(table, {repo, addon, kind})

    MapSet.size(stale)
  end

  defp do_prune(keep, {:disk, root}) do
    root
    |> subdirs()
    |> Enum.map(&prune_repo(root, &1, keep))
    |> Enum.sum()
  end

  # Each repository directory is pruned add-on by add-on, then removed if
  # that emptied it (`File.rmdir/1` refuses a non-empty directory, so this
  # needs no emptiness check of its own).
  defp prune_repo(root, repo, keep) do
    dir = Path.join(root, repo)
    dropped = Enum.count(subdirs(dir), &prune_addon(dir, repo, &1, keep))
    rmdir(dir)
    dropped
  end

  defp prune_addon(dir, repo, addon, keep) do
    if MapSet.member?(keep, {repo, addon}) do
      false
    else
      match?({:ok, _removed}, rm_rf(Path.join(dir, addon)))
    end
  end

  # Only entries we could have written ourselves: anything that isn't a valid
  # slug was put there by something else and is left alone rather than
  # rm_rf'd along with whatever else shares the root.
  defp subdirs(dir) do
    case ls(dir) do
      {:ok, entries} -> Enum.filter(entries, &Config.valid_slug?/1)
      {:error, _reason} -> []
    end
  end

  ## Filesystem internals — every path is root + validated slugs + constant

  defp valid_id?({repo, addon}), do: Config.valid_slug?(repo) and Config.valid_slug?(addon)
  defp valid_id?(_other), do: false

  # Walks `<root>/<repo>/<addon>` one component at a time, refusing any
  # component that is not a real directory.
  #
  # O_EXCL on the file itself is not enough. It protects the *final* path
  # component only, and by the time the open happens the kernel has already
  # traversed the directories — so a symlink at `<root>/<repo>` pointing at
  # `/etc` sends a freshly-named (therefore never-existing, therefore
  # O_EXCL-satisfying) write straight out of the asset root, as root.
  # Verified: `File.mkdir_p/1` follows symlinked components without complaint.
  #
  # Checking each component with `lstat` (which does not follow) closes that.
  # A TOCTOU window remains between the check and the open, but exploiting it
  # already requires write access inside the asset root, which is the same
  # precondition the whole class of attack needs.
  #
  # `:create` makes the directories (and refuses to adopt a non-directory that
  # is already there); `:existing` only validates, for the read and delete
  # paths — a symlinked component there is an arbitrary-file *read* as root,
  # which Phase 4 would serve unauthenticated.
  defp asset_dir(root, {repo, addon}, mode) do
    Enum.reduce_while([repo, addon], {:ok, root}, fn segment, {:ok, parent} ->
      dir = Path.join(parent, segment)

      case ensure_real_dir(dir, mode) do
        :ok -> {:cont, {:ok, dir}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_real_dir(dir, :create) do
    case File.mkdir(dir) do
      :ok -> :ok
      {:error, :eexist} -> ensure_real_dir(dir, :existing)
      {:error, _reason} = error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_real_dir(dir, :existing) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_asset_dir, dir, type}}
      {:error, _reason} = error -> error
    end
  end

  # `:store_assets` sits beside `addons.json` rather than under a config key
  # of its own: both are store/add-on state and neither should be able to
  # drift onto a different filesystem from the other.
  defp configured_root do
    case Application.get_env(:vagus, :addon_state_path) do
      path when is_binary(path) -> Path.join(Path.dirname(path), @dir)
      _other -> nil
    end
  end

  # A failed write is logged and reported, never raised: a full or read-only
  # data partition must degrade to "this add-on has no icon", not take down a
  # store reload.
  #
  # The scratch file gets a random suffix and is created with `:exclusive`
  # (O_CREAT|O_EXCL) rather than being a predictable `<path>.tmp` opened with
  # `File.write/2`. Two reasons, both real:
  #
  #   * O_EXCL refuses to open through a pre-existing symlink. Without it, an
  #     attacker who can create `<path>.tmp` under the asset root turns a
  #     hostile repository's icon bytes into an arbitrary file overwrite —
  #     this process runs as root on the device.
  #   * A fixed name lets two writers of the same asset truncate or unlink
  #     each other's scratch file mid-write. `reload/1` is serialized, so that
  #     is belt-and-braces, but the cost is one random suffix.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp write_atomic(path, binary) do
    tmp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    result =
      with :ok <- write_exclusive(tmp, binary) do
        File.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Vagus.Addon.Store.Assets: failed to write #{path}: #{inspect(reason)}")
        rm(tmp)
        error
    end
  end

  # `:raw` + `:file.write/2` rather than `IO.binwrite/2`: on Elixir 1.20
  # `IO.binwrite/2` **raises** on a write error (`:erlang.error(reason)`)
  # where the `File.write/2` this replaced returned `{:error, reason}`.
  # Using it would have turned a full or read-only data partition into an
  # exception escaping `reload/1` — breaking this module's "never raises"
  # contract and skipping the `rm(tmp)` cleanup on precisely the failure that
  # cleanup exists for. Verified by probing both on this Elixir version.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp write_exclusive(tmp, binary) do
    case File.open(tmp, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} ->
        try do
          :file.write(io, binary)
        after
          File.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, _reason} -> :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path) do
    File.rm(path)
    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ls(root), do: File.ls(root)

  # sobelow_skip ["Traversal.FileModule"]
  defp rmdir(path) do
    File.rmdir(path)
    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rm_rf(path), do: File.rm_rf(path)
end
