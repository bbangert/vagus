defmodule Vagus.Addon.Store do
  @moduledoc """
  The add-on store (`docs/contract-2026.7-m4-addendum.md` §A1 store routes) —
  fetches add-on repositories, parses each add-on's `config.yaml`/`config.json`
  into a `Vagus.Addon.Config`, and serves the catalog behind `GET /store`,
  `GET /store/addons`, `GET /store/addons/{slug}`, `POST /store/reload`.

  A store slug is `"<repo>_<config-slug>"` (the official repo is `core`, so
  Mosquitto → `core_mosquitto`), matching the Supervisor's naming.

  Fetching is injectable (`:fetcher`, default `Vagus.Addon.Store.HTTPFetcher`):
  a fetcher takes a repository map and returns `{:ok, [{path, content}]}` (the
  repo's files) or `{:error, reason}`, so the catalog logic is unit-testable
  without the network. Repositories come from `:repositories`/
  `config :vagus, :store_repositories` (`%{slug, url, ref}` maps).

  ## Store assets

  Besides configs, each add-on directory may ship `icon.png`, `logo.png`,
  `CHANGELOG.md` and `DOCS.md`, which the frontend fetches per add-on. Those
  bytes are retained by `Vagus.Addon.Store.Assets`, in memory or on disk
  depending on the mode `Vagus.Addon.Store.AssetMode` resolves once in
  `init/1`. The catalog entry carries only presence booleans
  (`assets: %{icon: bool, ...}`), never the bytes — mirroring the real
  Supervisor's cached `with_icon` flag.

  **Disk mode reduces steady-state retention, not peak fetch memory.** The
  fetcher still downloads a whole repository archive (≤33 MB) and inflates it
  (≤256 MB cap) entirely in memory before a single byte could be written out;
  every entry is resident by the time asset storage sees it. Making a reload
  cheap on a small board needs streaming extraction, which this is not. Do
  not read `:disk` as "the fetch got lighter".
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Config
  alias Vagus.Addon.Store.{AssetMode, Assets}

  @default_fetcher Vagus.Addon.Store.HTTPFetcher

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Re-fetches every repository and rebuilds the catalog. Returns `{:ok, count}`.

  The (slow, network-bound) fetch runs in the **caller's** process, not the
  GenServer — only a fast snapshot read and catalog swap touch the server — so a
  concurrent `catalog/0`/`get/1` (e.g. Core polling `/store`) is never blocked
  behind a reload.

  Asset retention rides along in the caller's process for the same reason: the
  `Assets` handle is read from the snapshot and written to directly, so the
  server never blocks behind a filesystem write either. Only the finished
  catalog goes through the server.
  """
  @spec reload(GenServer.server()) :: {:ok, non_neg_integer()}
  def reload(server \\ __MODULE__) do
    {repositories, fetcher, assets} = GenServer.call(server, :snapshot)
    catalog = build_catalog(repositories, fetcher, assets)
    :ok = GenServer.call(server, {:put_catalog, catalog})

    # After the swap, not before: until the new catalog is live, the old
    # entries are still the ones being served, and pruning their assets first
    # would blank icons for the length of the reload.
    {:ok, pruned} = Assets.prune(Enum.map(catalog, fn {_slug, e} -> Assets.id(e) end), assets)

    if pruned > 0 do
      Logger.info("Vagus.Addon.Store: pruned assets for #{pruned} add-on(s) no longer in catalog")
    end

    {:ok, map_size(catalog)}
  end

  @doc """
  The store's asset handle, for reading retained icon/logo/changelog/
  documentation bytes (`Vagus.Addon.Store.Assets.get/3`).
  """
  @spec assets(GenServer.server()) :: Assets.t()
  def assets(server \\ __MODULE__) do
    GenServer.call(server, :assets)
  end

  @doc "All catalog entries as `%{store_slug => %{config, repository, assets}}`."
  @spec catalog(GenServer.server()) :: %{optional(String.t()) => map()}
  def catalog(server \\ __MODULE__) do
    GenServer.call(server, :catalog)
  end

  @doc "The catalog entry for a store slug, or `:error`."
  @spec get(String.t(), GenServer.server()) :: {:ok, map()} | :error
  def get(slug, server \\ __MODULE__) do
    GenServer.call(server, {:get, slug})
  end

  @doc "The configured repositories (`%{slug, url, ref}`)."
  @spec repositories(GenServer.server()) :: [map()]
  def repositories(server \\ __MODULE__) do
    GenServer.call(server, :repositories)
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    # Resolved here, once, rather than per reload: the answer can't change
    # while the node is up, and the `:info` line it logs is the field-debug
    # anchor for "which mode did this board pick, and why".
    mode = AssetMode.resolve(Keyword.get(opts, :asset_mode))

    state = %{
      fetcher: Keyword.get(opts, :fetcher, configured_fetcher()),
      repositories: Keyword.get(opts, :repositories, configured_repositories()),
      catalog: %{},
      assets: Assets.init(mode, opts)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.repositories, state.fetcher, state.assets}, state}
  end

  def handle_call(:assets, _from, state), do: {:reply, state.assets, state}

  def handle_call({:put_catalog, catalog}, _from, state) do
    {:reply, :ok, %{state | catalog: catalog}}
  end

  def handle_call(:catalog, _from, state), do: {:reply, state.catalog, state}
  def handle_call({:get, slug}, _from, state), do: {:reply, Map.fetch(state.catalog, slug), state}
  def handle_call(:repositories, _from, state), do: {:reply, state.repositories, state}

  ## Catalog building (pure given the fetcher)

  @doc """
  Builds the catalog from `repositories` using `fetcher`. Exposed for tests.
  A repo that fails to fetch is logged and skipped (the rest still load) —
  so a network blip costs that repository's entries, not the whole catalog.

  `assets` is the `Vagus.Addon.Store.Assets` handle the retained icon/logo/
  changelog/documentation bytes are written to; it defaults to
  `Assets.none/0`, which parses configs and reports asset presence without
  retaining anything.
  """
  @spec build_catalog([map()], module(), Assets.t()) :: %{optional(String.t()) => map()}
  def build_catalog(repositories, fetcher, assets \\ Assets.none()) do
    Enum.reduce(repositories, %{}, fn repo, acc ->
      case fetcher.fetch(repo) do
        {:ok, files} ->
          Map.merge(acc, entries_from_files(files, repo, assets))

        {:error, reason} ->
          Logger.warning(
            "Vagus.Addon.Store: fetch #{inspect(repo[:slug])} failed: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  # Every `config.yaml`/`config.json` in the repo is one add-on. Parse each and
  # key it by its store slug; a config that won't parse is skipped (logged).
  # The add-on's icon/logo/changelog/documentation are whatever sits in the
  # same directory as its config — the layout the real Supervisor reads out of
  # its git checkout.
  defp entries_from_files(files, repo, assets) do
    by_dir = Enum.group_by(files, fn {path, _content} -> Path.dirname(path) end)

    files
    |> Enum.filter(fn {path, _} -> config_file?(path) end)
    |> Enum.reduce(%{}, fn {path, content}, acc ->
      case parse_config(path, content) do
        {:ok, config} ->
          siblings = Map.get(by_dir, Path.dirname(path), [])

          Map.put(acc, store_slug(repo, config.slug), %{
            config: config,
            repository: repo.slug,
            assets: retain_assets({repo.slug, config.slug}, siblings, assets)
          })

        {:error, reason} ->
          Logger.warning("Vagus.Addon.Store: bad config at #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  # Returns the presence map that goes in the catalog entry. A kind the repo
  # no longer ships (or that we refuse to retain) is actively deleted, not
  # just reported absent: in `:disk` mode a previous reload's bytes would
  # otherwise outlive the file that produced them and keep being served.
  defp retain_assets(id, siblings, assets) do
    Map.new(Assets.kinds(), fn kind ->
      {kind, retain_asset(id, kind, find_asset(siblings, kind), assets)}
    end)
  end

  defp retain_asset(id, kind, nil, assets) do
    Assets.delete(id, kind, assets)
    false
  end

  defp retain_asset({repo, addon} = id, kind, content, assets) do
    case Assets.put(id, kind, content, assets) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.Store: dropping #{kind} for #{repo}/#{addon} (#{inspect(reason)}; " <>
            "#{byte_size(content)} bytes, cap #{Assets.max_bytes(kind)})"
        )

        Assets.delete(id, kind, assets)
        false
    end
  end

  defp find_asset(siblings, kind) do
    filename = Assets.filename(kind)

    Enum.find_value(siblings, fn {path, content} ->
      if Path.basename(path) == filename and is_binary(content), do: content
    end)
  end

  defp config_file?(path) do
    base = Path.basename(path)
    base in ["config.yaml", "config.yml", "config.json"]
  end

  defp parse_config(path, content) do
    with {:ok, raw} <- decode(path, content),
         true <- is_map(raw) do
      Config.parse(raw)
    else
      false -> {:error, :not_a_map}
      other -> other
    end
  end

  defp decode(path, content) do
    case Path.extname(path) do
      ".json" -> Jason.decode(content)
      _ -> YamlElixir.read_from_string(content)
    end
  end

  defp store_slug(%{slug: repo_slug}, config_slug), do: "#{repo_slug}_#{config_slug}"

  defp configured_repositories do
    Application.get_env(:vagus, :store_repositories, [])
  end

  # `:store_fetcher` lets a target select `BuiltinFetcher` (embeds Vagus's native
  # virtual add-ons + delegates git repos to HTTPFetcher) without a bespoke child
  # spec; defaults to plain HTTP fetching.
  defp configured_fetcher do
    Application.get_env(:vagus, :store_fetcher, @default_fetcher)
  end
end
