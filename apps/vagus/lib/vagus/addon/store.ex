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
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Config

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
  """
  @spec reload(GenServer.server()) :: {:ok, non_neg_integer()}
  def reload(server \\ __MODULE__) do
    {repositories, fetcher} = GenServer.call(server, :snapshot)
    catalog = build_catalog(repositories, fetcher)
    :ok = GenServer.call(server, {:put_catalog, catalog})
    {:ok, map_size(catalog)}
  end

  @doc "All catalog entries as `%{store_slug => %{config, repository}}`."
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
    state = %{
      fetcher: Keyword.get(opts, :fetcher, @default_fetcher),
      repositories: Keyword.get(opts, :repositories, configured_repositories()),
      catalog: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.repositories, state.fetcher}, state}
  end

  def handle_call({:put_catalog, catalog}, _from, state) do
    {:reply, :ok, %{state | catalog: catalog}}
  end

  def handle_call(:catalog, _from, state), do: {:reply, state.catalog, state}
  def handle_call({:get, slug}, _from, state), do: {:reply, Map.fetch(state.catalog, slug), state}
  def handle_call(:repositories, _from, state), do: {:reply, state.repositories, state}

  ## Catalog building (pure given the fetcher)

  @doc """
  Builds the catalog from `repositories` using `fetcher`. Exposed for tests.
  A repo that fails to fetch is logged and skipped (the rest still load).
  """
  @spec build_catalog([map()], module()) :: %{optional(String.t()) => map()}
  def build_catalog(repositories, fetcher) do
    Enum.reduce(repositories, %{}, fn repo, acc ->
      case fetcher.fetch(repo) do
        {:ok, files} ->
          Map.merge(acc, entries_from_files(files, repo))

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
  defp entries_from_files(files, repo) do
    files
    |> Enum.filter(fn {path, _} -> config_file?(path) end)
    |> Enum.reduce(%{}, fn {path, content}, acc ->
      case parse_config(path, content) do
        {:ok, config} ->
          Map.put(acc, store_slug(repo, config.slug), %{config: config, repository: repo.slug})

        {:error, reason} ->
          Logger.warning("Vagus.Addon.Store: bad config at #{path}: #{inspect(reason)}")
          acc
      end
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
end
