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
  `config :vagus, :store_repositories` (`%{slug, url, ref}` maps), followed
  by any runtime-added ones persisted at `:path`/`config :vagus,
  :store_repositories_path` — a JSON list of the raw source strings a user
  posted, decoded through `Vagus.Addon.Store.RepositorySpec.parse/1` and
  layered *after* the config-declared list, so `repository_views`'
  dedup-by-slug always favors a config/built-in repo over a persisted one
  sharing its slug.

  ## Runtime repository mutation

  `add_repository/2`, `remove_repository/2` and `repair_repository/2` mutate
  that list at runtime (`POST`/`DELETE /store/repositories`,
  `POST /store/repositories/{slug}/repair`) and each one ends in a full
  reload. They observe `reload/1`'s discipline exactly: the candidate fetch
  and the reload run in the **caller's** process under the **same** mutex,
  and only the append/pop-plus-persist goes through the server. A mutation
  that finds the mutex held therefore returns `{:error, :busy}` rather than
  queueing behind a network-bound reload — unlike `reload/1`, which can
  honestly report the current catalog as success, a change that didn't
  happen cannot be reported as one.

  `remove_repository/2`'s in-use guard reads installed add-ons from
  `Vagus.Addon.State` — `:addon_state`/`init/1` names the server (default
  `Vagus.Addon.State`), the same injection point `Vagus.Ingress` uses.

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

  alias Vagus.Addon.{Config, State}
  alias Vagus.Addon.Store.{AssetMode, Assets, RepositorySpec}

  @default_fetcher Vagus.Addon.Store.HTTPFetcher

  # Cap on RUNTIME-ADDED (persisted) repositories. Config/built-in repos don't
  # count. Every mutation ends in a full reload that fetches all N sources
  # sequentially (≤33 MB + ≤60 s each) under the global reload mutex, so an
  # unbounded persisted set is a self-inflicted reload-cost DoS. 50 is far above
  # any real home deployment (upstream users run a handful) while bounding the
  # worst-case reload.
  @max_repositories 50

  # A repository's own display metadata, at the archive root. Upstream accepts
  # the same three names (`FILE_SUFFIX_CONFIGURATION` against `repository`) and
  # will not even treat a git repository as valid without one.
  @repository_files ~w(repository.json repository.yaml repository.yml)

  # Upstream's `supervisor/store/built-in.json`, in V1 wording. The core and
  # local repositories are the two that ship no `repository.*` of their own —
  # `home-assistant/addons` genuinely has none — so Supervisor carries their
  # names in-tree rather than deriving them. Without this the frontend, which
  # titles each store section with the repository's `name`, shows the slug.
  #
  # Only `name`/`maintainer`: upstream's table also carries a `url` (the docs
  # page, distinct from the clone source), but Vagus renders `url` and `source`
  # from where it actually fetches, and a display URL that isn't the source
  # would make `source` lie.
  @builtin_repository_meta %{
    "core" => %{name: "Official add-ons", maintainer: "Home Assistant"},
    "local" => %{name: "Local add-ons", maintainer: "you"}
  }

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

  Only one reload runs at a time. Before assets existed, overlapping reloads
  raced only on an idempotent catalog swap and the loser was harmless. Now each
  reload *writes* assets before it swaps and *prunes* after, so interleaving
  two produces a torn store — one call's prune deleting the assets the other
  has just written and is about to advertise, leaving `entry.assets.icon ==
  true` with no bytes behind it until something reloads again.

  A second caller **does not wait**: it logs and returns the current catalog
  size, having changed nothing. That is what the real Supervisor does —
  `GitRepo.pull` opens with `if self.lock.locked(): return False` ("There is
  already a task in progress"), and `StoreManager.reload` reads that `False`
  as "this repository wasn't updated", not as an error, so the HTTP caller
  still gets a success. Blocking instead would pin a Bandit worker for the
  length of a network-bound reload (up to `receive_timeout` per repository),
  the same worker-exhaustion exposure `Vagus.Core.Lifecycle` designed around
  with its `retries: 0` → `{:error, :busy}` → 409.
  """
  @spec reload(GenServer.server()) :: {:ok, non_neg_integer()}
  def reload(server \\ __MODULE__) do
    case with_reload_lock(server, fn -> do_reload(server) end) do
      :aborted ->
        Logger.warning("Vagus.Addon.Store: reload already in progress, skipping")
        {:ok, map_size(catalog(server))}

      {:ok, count, _errors} ->
        {:ok, count}
    end
  end

  # `retries: 0` — take the lock or give up immediately, never queue. Keyed
  # on the server so async tests running their own stores never contend.
  # Every repository mutation takes this same lock, because each one ends in a
  # reload: interleaving two tears the store's assets exactly the way two
  # reloads would (see `reload/1`).
  defp with_reload_lock(server, fun) do
    :global.trans({{:store_reload, server}, self()}, fun, [node()], 0)
  end

  # The three repository operations' entry point: `{:error, :busy}` on
  # contention, because an add/remove/repair that never ran must not be
  # reported as one (`reload/1`'s honest-success answer doesn't transfer), and
  # blocking would pin a Bandit worker for the length of a network-bound reload
  # (`Vagus.Core.Lifecycle`'s `retries: 0` → `:busy` → 409 precedent).
  defp exclusive(server, operation, fun) do
    case with_reload_lock(server, fun) do
      :aborted ->
        Logger.warning(
          "Vagus.Addon.Store: #{operation} skipped, a reload or repository change " <>
            "is already in progress"
        )

        {:error, :busy}

      result ->
        result
    end
  end

  # `{:ok, count, errors}` — the per-repository fetch failures ride along for
  # `repair_repository/2`, which is the only caller that needs to know whether
  # *this* reload actually brought a given repository down. `reload/1` drops
  # them.
  defp do_reload(server) do
    {repositories, fetcher, assets} = GenServer.call(server, :snapshot)
    {catalog, repository_meta, errors} = build_with_errors(repositories, fetcher, assets)
    :ok = GenServer.call(server, {:put_catalog, catalog})
    :ok = GenServer.call(server, {:put_repository_meta, repository_meta})

    # After the swap, not before: until the new catalog is live, the old
    # entries are still the ones being served, and pruning their assets first
    # would blank icons for the length of the reload.
    {:ok, pruned} = Assets.prune(Enum.map(catalog, fn {_slug, e} -> Assets.id(e) end), assets)

    if pruned > 0 do
      Logger.info("Vagus.Addon.Store: pruned assets for #{pruned} add-on(s) no longer in catalog")
    end

    {:ok, map_size(catalog), errors}
  end

  @doc """
  The asset id for `store_slug` and the handle to read it from, in ONE call.

  Exists because the asset routes are the only unauthenticated surface in the
  API: asking the singleton for the catalog entry and the handle separately
  meant two synchronous `GenServer.call/2`s per token-less request, all
  contending with the same process that serves `/store` and runs catalog
  reloads. `:error` when the slug is not in the catalog — which is also how a
  detached add-on and a bogus slug arrive here.
  """
  @spec asset_lookup(String.t(), GenServer.server()) :: {:ok, Assets.id(), Assets.t()} | :error
  def asset_lookup(store_slug, server \\ __MODULE__) do
    GenServer.call(server, {:asset_lookup, store_slug})
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

  @doc """
  The repositories as the wire sees them: **one entry per slug**, each carrying
  `name`/`url`/`maintainer` resolved from the repository's own
  `repository.{json,yaml,yml}`, then the built-in table, then defaults.

  Deduplication is not cosmetic. Vagus can configure several *sources* under
  one repository slug — the built-in mqtt repo rides `core` alongside
  `home-assistant/addons`, which is what puts `core_mqtt` in the catalog — but
  the frontend renders one titled section per entry in this list and fills it
  by matching `addon.repository` against the slug. Two entries slugged `core`
  therefore render the same add-ons twice, under two identical headings.
  Upstream never hits this because only `core` and `local` get literal slugs;
  every other repository is keyed by a hash of its URL.

  The `url` for a slug is the first non-nil one across its sources, so the
  built-in repo (which has none) doesn't blank out the git URL it shares a slug
  with. `source` — the raw string a runtime-added repository was added with —
  resolves the same way and is `nil` for config-declared repos, which never had
  one; `Vagus.Addon.StoreView.repository/1` prefers it over `url` so a
  `#branch` suffix survives to the wire instead of being flattened away.
  """
  @spec repositories(GenServer.server()) :: [map()]
  def repositories(server \\ __MODULE__) do
    GenServer.call(server, :repositories)
  end

  @doc """
  Adds the repository a user posted as `repository_string`
  (`POST /store/repositories`) and reloads the catalog, so the new repo's
  add-ons are already in the store when this returns `:ok`.

  Caller-side under `reload/1`'s mutex (see the moduledoc) — `{:error, :busy}`
  when a reload or another mutation holds it. Nothing is appended or persisted
  unless all three gates pass:

    * `{:error, :invalid_format}` — not a `url[#branch]` repository string
      (`Vagus.Addon.Store.RepositorySpec.parse/1`), or one that parses but fails
      the runtime fetchability/integrity gate
      (`Vagus.Addon.Store.RepositorySpec.ensure_safe/1`: non-`github.com` host,
      a ref that path-traverses, or an over-length string)
    * `{:error, :repo_limit}` — the persisted (runtime-added) repository count
      is already at `@max_repositories`; config/built-in repos don't count
    * `{:error, {:duplicate, url}}` — its derived slug matches an existing
      repository's, or its URL matches one's `:url` case-insensitively. The
      URL half is what catches re-adding a *built-in* by URL: Vagus's
      built-ins keep human slugs (`core`, …) where upstream hashes every
      repository's URL into one, so slug comparison alone would miss it.
    * `{:error, {:invalid_repository, url}}` — the candidate didn't fetch, or
      ships no parseable `repository.{json,yaml,yml}` at its root. That file is
      upstream's own bar for "this is an add-on repository" (a git repo without
      one is never accepted) and is what titles the store section the frontend
      renders.

  The candidate is fetched twice on the happy path — once to validate, once by
  the reload that follows. Upstream clones then reloads the whole store for the
  same reason: threading one repository's already-fetched files into a full
  rebuild would fork the reload path for an operation a user performs by hand.
  """
  @spec add_repository(GenServer.server(), String.t()) ::
          :ok
          | {:error,
             :busy
             | :invalid_format
             | :repo_limit
             | {:duplicate, String.t()}
             | {:invalid_repository, String.t()}}
  def add_repository(server \\ __MODULE__, repository_string) do
    exclusive(server, "add_repository", fn -> do_add_repository(server, repository_string) end)
  end

  @doc """
  Removes the repository `slug` was added under (`DELETE
  /store/repositories/{slug}`) and reloads the catalog, so its add-ons are
  already gone when this returns `:ok`.

  Caller-side under `reload/1`'s mutex (see the moduledoc) — `{:error, :busy}`
  when a reload or another mutation holds it. Guards, in order:

    * `{:error, :not_found}` — no repository under that slug
    * `{:error, :builtin}` — the slug is config-declared. "Built-in" is
      decided by absence from the persisted source list, not by re-reading
      `config :vagus, :store_repositories`: the state is what the running
      store actually serves, and a config change under a live node would
      otherwise be able to make a persisted repo unremovable.
    * `{:error, {:in_use, source}}` — an installed add-on came from it.
      `source` is the repository's own source string (else its url, else the
      slug), the same precedence the wire's `source` field uses, because that
      string is what the user typed and what the error message quotes back.
  """
  @spec remove_repository(GenServer.server(), String.t()) ::
          :ok | {:error, :busy | :not_found | :builtin | {:in_use, String.t()}}
  def remove_repository(server \\ __MODULE__, slug) do
    exclusive(server, "remove_repository", fn -> do_remove_repository(server, slug) end)
  end

  @doc """
  Re-fetches everything and reports honestly on `slug`
  (`POST /store/repositories/{slug}/repair`).

  Vagus holds no git checkout to repair, so a repair *is* a full reload —
  caller-side under `reload/1`'s mutex, `{:error, :busy}` when it's held. What
  makes it a repair rather than an alias for `reload/1` is the verdict
  afterwards: `{:error, {:fetch_failed, reason}}` carries the actual fetch
  error when this reload could not bring `slug` down, `{:error, :not_found}`
  when no repository has that slug, `:ok` otherwise.

  "Fetched" is not "non-empty": a repository that legitimately ships no add-ons
  (or no `repository.json`) contributes nothing to the catalog or the metadata
  map and is still healthy, which is why the verdict reads the reload's
  per-repository fetch errors rather than looking for its entries.
  """
  @spec repair_repository(GenServer.server(), String.t()) ::
          :ok | {:error, :busy | :not_found | {:fetch_failed, term()}}
  def repair_repository(server \\ __MODULE__, slug) do
    exclusive(server, "repair_repository", fn -> do_repair_repository(server, slug) end)
  end

  ## Repository mutation (caller-side; see the moduledoc)

  defp do_add_repository(server, repository_string) do
    {repositories, fetcher, _assets} = GenServer.call(server, :snapshot)

    with {:ok, entry} <- parse_candidate(repository_string),
         :ok <- refute_duplicate(entry, repositories),
         :ok <- within_capacity(repositories),
         :ok <- fetch_candidate(entry, fetcher) do
      :ok = GenServer.call(server, {:add_repository, entry})
      {:ok, _count, _errors} = do_reload(server)
      :ok
    end
  end

  # `parse/1` is the upstream-parity format gate; `ensure_safe/1` is the
  # stricter, runtime-only fetchability/integrity gate that keeps a
  # runtime-added repository's displayed url pinned to the repo the fetcher
  # would actually pull (github-host, no ref path-traversal, bounded length).
  defp parse_candidate(repository_string) do
    with {:ok, spec} <- RepositorySpec.parse(repository_string),
         :ok <- RepositorySpec.ensure_safe(spec) do
      {:ok, repository_entry(spec)}
    end
  end

  defp refute_duplicate(entry, repositories) do
    if Enum.any?(repositories, &duplicate?(entry, &1)) do
      {:error, {:duplicate, entry.url}}
    else
      :ok
    end
  end

  # Only the persisted (runtime-added) entries carry a `:source`; config/built-in
  # repos don't and are exempt from the cap.
  defp within_capacity(repositories) do
    if Enum.count(repositories, &Map.has_key?(&1, :source)) >= @max_repositories do
      {:error, :repo_limit}
    else
      :ok
    end
  end

  defp duplicate?(candidate, existing) do
    candidate.slug == existing.slug or same_url?(candidate.url, Map.get(existing, :url))
  end

  # A url-less repository (the built-in mqtt source) can only collide by slug.
  defp same_url?(_candidate, nil), do: false
  defp same_url?(candidate, url), do: normalize_url(candidate) == normalize_url(url)

  # Collapses the trivial variants (`…/addons`, `…/addons/`, `…/addons.git`,
  # mixed case) that would otherwise re-add the same repo under a fresh hash
  # slug. Deliberately conservative: no percent-decoding and no host
  # canonicalization, so e.g. `%61ddons` vs `addons` is a known residual that
  # still slips through — closing it would need a full URL canonicalizer.
  defp normalize_url(url) do
    url
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
    |> String.downcase()
  end

  # Parsed with `repository_metadata/1` — the exact reader a reload uses — so a
  # candidate accepted here can never fail to parse there.
  defp fetch_candidate(entry, fetcher) do
    case fetcher.fetch(entry) do
      {:ok, files} ->
        if repository_metadata(files),
          do: :ok,
          else: {:error, {:invalid_repository, entry.url}}

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.Store: candidate repository #{entry.url} did not fetch: #{inspect(reason)}"
        )

        {:error, {:invalid_repository, entry.url}}
    end
  end

  defp do_remove_repository(server, slug) do
    context = GenServer.call(server, :removal_context)

    with :ok <- removable(context, slug),
         :ok <- unused(context, slug) do
      :ok = GenServer.call(server, {:remove_repository, slug})
      {:ok, _count, _errors} = do_reload(server)
      :ok
    end
  end

  defp removable(context, slug) do
    cond do
      not Enum.any?(context.repositories, &(&1.slug == slug)) ->
        {:error, :not_found}

      slug not in Enum.map(context.persisted_sources, &RepositorySpec.slug/1) ->
        {:error, :builtin}

      true ->
        :ok
    end
  end

  # "In use" is the installed add-on's *repository association*, never its
  # slug's prefix: an installed add-on is recorded under its store slug
  # (`<repo>_<addon>`), and the catalog entry that slug resolves to carries the
  # repository it was built from — the same `:repository` field
  # `Vagus.Backups`' `repository_of/1` reads. Prefix-matching would refuse to
  # remove a repo slugged `core2` because `core_mqtt` is installed.
  #
  # A *detached* add-on (installed, but in no catalog entry — its repository
  # currently fails to fetch, or stopped listing it) has no association to read
  # and so holds nothing back. Honest: nothing in the store claims it either.
  defp unused(context, slug) do
    installed = State.list(context.addon_state)

    if Enum.any?(installed, &installed_from?(&1, slug, context.catalog)) do
      {:error, {:in_use, repository_source(context.repositories, slug)}}
    else
      :ok
    end
  end

  defp installed_from?(%{config: %Config{slug: store_slug}}, repo_slug, catalog) do
    match?(%{repository: ^repo_slug}, Map.get(catalog, store_slug))
  end

  # `Vagus.Addon.StoreView.repository/1`'s `source` precedence, for the slug's
  # first (canonical) entry.
  defp repository_source(repositories, slug) do
    repo = Enum.find(repositories, %{}, &(&1.slug == slug))
    Map.get(repo, :source) || Map.get(repo, :url) || slug
  end

  defp do_repair_repository(server, slug) do
    if GenServer.call(server, {:known_repository?, slug}) do
      {:ok, _count, errors} = do_reload(server)

      case Map.fetch(errors, slug) do
        {:ok, reason} -> {:error, {:fetch_failed, reason}}
        :error -> :ok
      end
    else
      {:error, :not_found}
    end
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    # Resolved here, once, rather than per reload: the answer can't change
    # while the node is up, and the `:info` line it logs is the field-debug
    # anchor for "which mode did this board pick, and why".
    mode = AssetMode.resolve(Keyword.get(opts, :asset_mode))

    path = Keyword.get(opts, :path, repositories_path())
    persisted_sources = read_persisted(path)
    configured = Keyword.get(opts, :repositories, configured_repositories())

    state = %{
      fetcher: Keyword.get(opts, :fetcher, configured_fetcher()),
      # Persisted repos layered AFTER config: `repository_views`'s
      # dedup-by-slug keeps the first entry for a given slug, so a persisted
      # repo can never shadow a config/built-in one sharing its slug.
      repositories: configured ++ derive_repositories(persisted_sources),
      path: path,
      persisted_sources: persisted_sources,
      # Read (caller-side) only by `remove_repository/2`'s in-use guard.
      addon_state: Keyword.get(opts, :addon_state, State),
      catalog: %{},
      repository_meta: %{},
      assets: Assets.init(mode, opts)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.repositories, state.fetcher, state.assets}, state}
  end

  def handle_call(:assets, _from, state), do: {:reply, state.assets, state}

  def handle_call({:asset_lookup, slug}, _from, state) do
    reply =
      case Map.fetch(state.catalog, slug) do
        {:ok, entry} -> {:ok, Assets.id(entry), state.assets}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:put_catalog, catalog}, _from, state) do
    {:reply, :ok, %{state | catalog: catalog}}
  end

  # Its own message rather than a third element on `{:put_catalog, …}`:
  # repository metadata is display-only and swapping it is independent of the
  # catalog swap, so tests that seed a catalog by hand keep saying exactly what
  # they mean. A reload sends both; a brief disagreement between them can only
  # mistitle a store section for the width of two GenServer calls.
  def handle_call({:put_repository_meta, repository_meta}, _from, state) do
    {:reply, :ok, %{state | repository_meta: repository_meta}}
  end

  def handle_call(:catalog, _from, state), do: {:reply, state.catalog, state}
  def handle_call({:get, slug}, _from, state), do: {:reply, Map.fetch(state.catalog, slug), state}

  def handle_call(:repositories, _from, state) do
    {:reply, repository_views(state.repositories, state.repository_meta), state}
  end

  def handle_call({:known_repository?, slug}, _from, state) do
    {:reply, Enum.any?(state.repositories, &(&1.slug == slug)), state}
  end

  # Everything `remove_repository/2`'s guards decide from, in ONE call: the
  # repositories, which sources were persisted (i.e. which slugs are removable
  # at all), and — for the in-use guard, which runs in the caller — the catalog
  # plus the `Vagus.Addon.State` server to resolve installed add-ons against.
  def handle_call(:removal_context, _from, state) do
    {:reply, Map.take(state, [:repositories, :persisted_sources, :catalog, :addon_state]), state}
  end

  # The whole mutation: appended to the served list and written to disk in one
  # server call, so no reader can observe a repository the file doesn't know
  # about (or the reverse). The caller has already validated + fetched it.
  def handle_call({:add_repository, entry}, _from, state) do
    state = %{
      state
      | repositories: state.repositories ++ [entry],
        persisted_sources: state.persisted_sources ++ [entry.source]
    }

    persist(state.path, state.persisted_sources)
    {:reply, :ok, state}
  end

  # Drops exactly the entries derived from the removed source strings, rather
  # than everything slugged `slug`: a config-declared repo sharing the slug is
  # not the caller's to remove (`removable/2` refuses that case anyway), and it
  # carries no `:source` to match.
  def handle_call({:remove_repository, slug}, _from, state) do
    {removed, kept} =
      Enum.split_with(state.persisted_sources, &(RepositorySpec.slug(&1) == slug))

    state = %{
      state
      | repositories: Enum.reject(state.repositories, &(Map.get(&1, :source) in removed)),
        persisted_sources: kept
    }

    persist(state.path, kept)
    {:reply, :ok, state}
  end

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
    repositories |> build(fetcher, assets) |> elem(0)
  end

  @doc """
  `build_catalog/3` plus the repository display metadata parsed out of the very
  same fetch: `{catalog, %{repo_slug => %{name, url, maintainer}}}`.

  It rides the catalog build rather than getting its own pass because the
  metadata lives in the archive the catalog was just built from — a second
  fetch would double the network cost of every reload to read one small file
  per repository.

  A repository that ships no `repository.{json,yaml,yml}` contributes nothing
  and falls back at render time (`repository_views/2`). That is the normal
  case for the core repository, which genuinely has no such file upstream
  either — hence Supervisor's in-tree `built-in.json`.
  """
  @spec build([map()], module(), Assets.t()) ::
          {%{optional(String.t()) => map()}, %{optional(String.t()) => map()}}
  def build(repositories, fetcher, assets \\ Assets.none()) do
    {catalog, meta, _errors} = build_with_errors(repositories, fetcher, assets)
    {catalog, meta}
  end

  # `build/3` plus `%{repo_slug => fetch error}`, which is the only way
  # `repair_repository/2` can tell a repository that came down and is
  # legitimately empty from one that never came down at all — both contribute
  # nothing to the catalog and nothing to the metadata map. Not part of
  # `build/3`'s contract because every other caller (and its tests) wants the
  # two maps and nothing else.
  #
  # First error per slug wins, mirroring `put_repository_meta/3`'s
  # first-file-wins rule: several sources can share one slug (the built-in mqtt
  # repo rides `core`), and a slug any of whose sources failed did not fully
  # refresh.
  defp build_with_errors(repositories, fetcher, assets) do
    Enum.reduce(repositories, {%{}, %{}, %{}}, fn repo, {catalog, meta, errors} ->
      case fetcher.fetch(repo) do
        {:ok, files} ->
          {Map.merge(catalog, entries_from_files(files, repo, assets)),
           put_repository_meta(meta, repo, files), errors}

        {:error, reason} ->
          Logger.warning(
            "Vagus.Addon.Store: fetch #{inspect(repo[:slug])} failed: #{inspect(reason)}"
          )

          {catalog, meta, Map.put_new(errors, repo.slug, reason)}
      end
    end)
  end

  # First parsed `repository.*` for a slug wins. Two configured repositories
  # can share one slug (the built-in mqtt repo rides `core`), and only the
  # git-backed one of the pair carries the file.
  defp put_repository_meta(meta, repo, files) do
    case repository_metadata(files) do
      nil -> meta
      parsed -> Map.put_new(meta, repo.slug, parsed)
    end
  end

  # One view per distinct slug, first appearance wins for ordering. Metadata
  # precedence: the repository's own file, then the built-in table, then the
  # slug itself — `nil` fields in a parsed file fall through the same way, so a
  # `repository.json` carrying only a name still gets its maintainer defaulted
  # rather than rendering `null` into a required wire field.
  defp repository_views(repositories, meta) do
    by_slug = Enum.group_by(repositories, & &1.slug)

    repositories
    |> Enum.uniq_by(& &1.slug)
    |> Enum.map(fn %{slug: slug} = repo ->
      fields =
        Map.merge(
          Map.get(@builtin_repository_meta, slug, %{}),
          reject_nils(Map.get(meta, slug, %{}))
        )

      %{
        slug: slug,
        ref: Map.get(repo, :ref),
        url: by_slug |> Map.fetch!(slug) |> Enum.find_value(&Map.get(&1, :url)),
        source: by_slug |> Map.fetch!(slug) |> Enum.find_value(&Map.get(&1, :source)),
        name: Map.get(fields, :name) || slug,
        maintainer: Map.get(fields, :maintainer) || ""
      }
    end)
  end

  defp reject_nils(fields), do: Map.reject(fields, fn {_k, v} -> is_nil(v) end)

  defp repository_metadata(files) do
    Enum.find_value(files, fn {path, content} ->
      if Path.basename(path) in @repository_files and Path.dirname(path) == "." do
        case decode(path, content) do
          {:ok, raw} when is_map(raw) ->
            %{name: raw["name"], maintainer: raw["maintainer"]}

          _ ->
            nil
        end
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

  ## Persisted repositories (issue #5 / D4)

  # `%{slug, url, ref, source}` per persisted source string, ready to append
  # to `state.repositories` alongside the config-declared entries. A source
  # was already validated by `RepositorySpec.parse/1` in `read_persisted/1`
  # before it reached the persisted list, so this can't fail — but `parse/1`
  # is called again rather than trusted-through, because the two functions
  # have no shared state to prove that invariant across a refactor.
  defp derive_repositories(sources) do
    Enum.map(sources, fn source ->
      {:ok, spec} = RepositorySpec.parse(source)
      repository_entry(spec)
    end)
  end

  # The one shape a runtime-added repository takes in `state.repositories`,
  # from a parsed spec — shared by the boot-time derivation above and
  # `add_repository/2`'s candidate, so the two can never disagree about the
  # slug a source string lands on.
  defp repository_entry(%{source: source, url: url, ref: ref}) do
    %{slug: RepositorySpec.slug(source), url: url, ref: ref, source: source}
  end

  # `path` is the compile/config-time store-repositories path, never request
  # input — no user-controlled traversal is possible.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_persisted(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} when is_list(decoded) <- Jason.decode(contents) do
      decode_sources(decoded)
    else
      _not_found_or_invalid -> []
    end
  end

  # Mirrors `Vagus.API.SupervisorOptions`' decode discipline: a hand-edited
  # or partially written `store_repositories.json` is not trusted verbatim.
  # A non-binary entry, or a binary that doesn't parse as a repository
  # string, is dropped (logged) rather than reaching `derive_repositories/1`
  # and crashing boot.
  defp decode_sources(decoded) do
    Enum.filter(decoded, fn entry ->
      case entry do
        source when is_binary(source) ->
          case RepositorySpec.parse(source) do
            {:ok, _} -> true
            {:error, :invalid_format} -> log_dropped(entry)
          end

        other ->
          log_dropped(other)
      end
    end)
  end

  defp log_dropped(entry) do
    Logger.warning(
      "Vagus.Addon.Store: dropping persisted repository entry #{inspect(entry)} " <>
        "(not a valid repository string)"
    )

    false
  end

  # Writes `sources` (the raw persisted source-string list) to `path` as JSON,
  # from inside the mutation `handle_call`s — the same shape
  # `Vagus.API.SupervisorOptions.put/2` uses. A failed write is logged, not
  # raised: losing one repository change to a flash write error must not take
  # the process that serves `GET /store` down with it.
  #
  # `path` is the compile/config-time store-repositories path, not request
  # input.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, sources) do
    :ok = File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(sources)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Vagus.Addon.Store: failed to persist #{path} (#{inspect(reason)}) — " <>
            "repository change was not written to disk"
        )
    end
  end

  defp repositories_path do
    Application.get_env(:vagus, :store_repositories_path) ||
      raise "config :vagus, :store_repositories_path is not set " <>
              "(expected from config/host.exs or config/target.exs)"
  end
end
