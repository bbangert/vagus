defmodule Vagus.Addon.StoreTest do
  @moduledoc "P2-T3: the add-on store — catalog building, GenServer, and store views."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.{State, Store, StoreView}
  alias Vagus.Addon.Store.{Assets, RepositorySpec}

  @mosquitto_yaml """
  name: Mosquitto broker
  version: "7.1.0"
  slug: mosquitto
  description: An Open Source MQTT broker
  arch:
    - aarch64
    - amd64
  image: homeassistant/{arch}-addon-mosquitto
  auth_api: true
  services:
    - mqtt:provide
  discovery:
    - mqtt
  """

  # Carries the display-only trio (`stage`/`advanced`/`url`) that the frontend
  # renders as the experimental badge, the advanced-mode filter and the
  # website link — the beta ESPHome entry is exactly where HAOS shows them.
  @esphome_yaml """
  name: ESPHome
  version: "2025.1.0"
  slug: esphome
  description: ESPHome dashboard
  arch:
    - aarch64
  image: esphome/{arch}-addon
  ingress: true
  stage: experimental
  advanced: true
  url: https://esphome.io
  """

  # 1x1 PNG header — real bytes, so a text-path round-trip would fail.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  # Assets are addressed by `{repo_slug, addon_slug}`, not by the store slug
  # the catalog is keyed on. See `Vagus.Addon.Store.Assets`.
  @mosquitto {"core", "mosquitto"}
  @esphome {"core", "esphome"}

  # A fetcher returning an in-memory repo tree (config.yaml at add-on dirs, plus
  # noise that must be ignored). Matches the `fetch/1` contract.
  #
  # Mosquitto ships all four store assets; ESPHome ships none — the pair that
  # makes the catalog's presence flags worth asserting. The `CHANGELOG.md` at
  # the repo root is deliberate: it is a sibling of nothing, and must not be
  # picked up by either add-on.
  defmodule FixtureFetcher do
    # Must precede the `%{slug: "core"}` clause — the built-in mqtt source
    # shares that slug, which is the collision `repositories/1` collapses.
    def fetch(%{slug: "core", builtin: :mqtt}), do: {:ok, []}

    # The only fixture repo carrying its own `repository.json`, i.e. the one
    # whose store section is titled by the repo rather than by the built-in
    # table or its slug.
    def fetch(%{slug: "community"}) do
      {:ok,
       [
         {"repository.json",
          ~s({"name": "Home Assistant Community Add-ons", "maintainer": "Franck Nijhof"})},
         {"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}
       ]}
    end

    def fetch(%{slug: "nameless"}), do: {:ok, []}

    def fetch(%{slug: "core"}) do
      {:ok,
       [
         {"README.md", "ignore me"},
         {"CHANGELOG.md", "repo-level changelog, not an add-on's"},
         {"mosquitto/config.yaml", Vagus.Addon.StoreTest.mosquitto_yaml()},
         {"mosquitto/Dockerfile", "FROM scratch"},
         {"mosquitto/icon.png", Vagus.Addon.StoreTest.png()},
         {"mosquitto/logo.png", Vagus.Addon.StoreTest.png()},
         {"mosquitto/CHANGELOG.md", "## 7.1.0\n"},
         {"mosquitto/DOCS.md", "# Mosquitto\n"},
         {"mosquitto/README.md", "# Mosquitto broker\n\nThe long description body.\n"},
         {"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}
       ]}
    end

    def fetch(%{slug: "broken"}), do: {:error, :nxdomain}
  end

  def mosquitto_yaml, do: @mosquitto_yaml
  def esphome_yaml, do: @esphome_yaml
  def png, do: @png

  @repos [%{slug: "core", url: "https://github.com/home-assistant/addons"}]

  # The runtime-mutation fixture. Matches on `url`, not `slug`: a
  # runtime-added repository is slugged by a hash of the exact string the user
  # posted, so `url` and `url#branch` are two slugs served by one fixture repo.
  defmodule MutationFetcher do
    def fetch(%{slug: "core"} = repo), do: Vagus.Addon.StoreTest.FixtureFetcher.fetch(repo)
    def fetch(%{slug: "broken"}), do: {:error, :nxdomain}

    def fetch(%{url: "https://github.com/awesome-developer/awesome-repo"}) do
      {:ok,
       [
         {"repository.json", ~s({"name": "Awesome add-ons", "maintainer": "Awesome Dev"})},
         {"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}
       ]}
    end

    # Fetches fine, ships add-ons, but has no `repository.{json,yaml,yml}` —
    # upstream's bar for "not an add-on repository". A github.com host so it
    # clears `RepositorySpec.ensure_safe/1`'s host gate and actually reaches the
    # fetch (the point under test).
    def fetch(%{url: "https://github.com/example/no-repository-file"}) do
      {:ok, [{"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}]}
    end

    def fetch(%{url: "https://github.com/example/gone"}), do: {:error, :nxdomain}
  end

  # A `Vagus.Addon.State` entry under `store_slug` — that is the key an
  # installed add-on is really recorded under (`handle_install` rewrites
  # `config.slug` to the store slug), which is what makes the catalog entry's
  # `:repository` field readable as the in-use association.
  defp install(state_server, store_slug) do
    {:ok, config} =
      Vagus.Addon.Config.parse(%{
        "name" => "Installed",
        "version" => "1.0.0",
        "slug" => store_slug,
        "description" => "an installed add-on",
        "arch" => ["aarch64"],
        "image" => "x/y"
      })

    :ok = State.put(config, :started, server: state_server)
  end

  test "build_catalog parses each config.yaml into a store-slugged entry" do
    catalog = Store.build_catalog(@repos, FixtureFetcher)

    assert map_size(catalog) == 2
    assert %{config: mqtt, repository: "core"} = catalog["core_mosquitto"]
    assert mqtt.slug == "mosquitto"
    assert mqtt.version == "7.1.0"
    assert Map.has_key?(catalog, "core_esphome")
  end

  test "a repo that fails to fetch is skipped, not fatal" do
    repos = [%{slug: "broken", url: "x"} | @repos]
    catalog = Store.build_catalog(repos, FixtureFetcher)
    assert map_size(catalog) == 2
  end

  test "a single unparseable config.yaml is skipped; the rest of the repo still loads" do
    defmodule BadFetcher do
      def fetch(%{slug: "core"}) do
        {:ok,
         [
           {"mosquitto/config.yaml", Vagus.Addon.StoreTest.mosquitto_yaml()},
           # missing required fields (name/version/slug/...) → Config.parse errors
           {"broken/config.yaml", "description: no required fields here\n"}
         ]}
      end
    end

    catalog = Store.build_catalog(@repos, BadFetcher)
    assert Map.has_key?(catalog, "core_mosquitto")
    assert map_size(catalog) == 1
  end

  test "the Store GenServer reloads + serves the catalog" do
    srv = start_supervised!({Store, name: nil, fetcher: FixtureFetcher, repositories: @repos})

    assert {:ok, 2} = Store.reload(srv)
    assert {:ok, %{config: c}} = Store.get("core_mosquitto", srv)
    assert c.slug == "mosquitto"
    assert :error = Store.get("core_nope", srv)
    assert [%{slug: "core"}] = Store.repositories(srv)
  end

  test "StoreView.summary is the StoreAddon shape with the store slug + repo" do
    catalog = Store.build_catalog(@repos, FixtureFetcher)
    s = StoreView.summary("core_mosquitto", catalog["core_mosquitto"], false)

    assert s["slug"] == "core_mosquitto"
    assert s["repository"] == "core"
    assert s["name"] == "Mosquitto broker"
    # Not installed, so no installed version — the frontend reads a non-nil
    # `version` as "this add-on is installed" and renders the whole page that
    # way. Upstream sends `installed.version if installed else None`.
    assert s["version"] == nil
    assert s["version_latest"] == "7.1.0"
    assert s["arch"] == ["aarch64", "amd64"]
    assert s["build"] == false
    assert s["installed"] == false
    refute Map.has_key?(s, "auth_api")
  end

  test "StoreView.summary reports the installed version once there is one" do
    catalog = Store.build_catalog(@repos, FixtureFetcher)
    s = StoreView.summary("core_mosquitto", catalog["core_mosquitto"], true, "7.0.0")

    assert s["version"] == "7.0.0"
    assert s["version_latest"] == "7.1.0"
    assert s["update_available"] == true
    assert s["installed"] == true
  end

  describe "what the payload advertises (the frontend fetches nothing it isn't told about)" do
    test "StoreView.summary carries the entry's asset flags, not a hardcoded false" do
      catalog = Store.build_catalog(@repos, FixtureFetcher)

      with_assets = StoreView.summary("core_mosquitto", catalog["core_mosquitto"], false)
      assert with_assets["icon"] == true
      assert with_assets["logo"] == true
      assert with_assets["changelog"] == true
      assert with_assets["documentation"] == true

      without = StoreView.summary("core_esphome", catalog["core_esphome"], false)
      assert without["icon"] == false
      assert without["logo"] == false
      assert without["changelog"] == false
      assert without["documentation"] == false
    end

    test "StoreView.detail carries them too, and stage/advanced/url come from the config" do
      catalog = Store.build_catalog(@repos, FixtureFetcher)

      d = StoreView.detail("core_esphome", catalog["core_esphome"], false)
      assert d["stage"] == "experimental"
      assert d["advanced"] == true
      assert d["url"] == "https://esphome.io"

      # The default when a config says nothing, which is most add-ons.
      stable = StoreView.detail("core_mosquitto", catalog["core_mosquitto"], false)
      assert stable["stage"] == "stable"
      assert stable["advanced"] == false
      assert stable["url"] == nil
      assert stable["icon"] == true
    end

    test "long_description is the README the caller read, and nil when absent" do
      catalog = Store.build_catalog(@repos, FixtureFetcher, Assets.init(:memory))
      readme = "# Mosquitto broker\n\nThe long description body.\n"

      d = StoreView.detail("core_mosquitto", catalog["core_mosquitto"], false, nil, readme)
      assert d["long_description"] == readme

      # No README retained (or a detached entry, which can't be looked up) —
      # upstream returns None rather than an empty string.
      assert StoreView.detail("core_esphome", catalog["core_esphome"], false)["long_description"] ==
               nil
    end

    test "an entry with no :assets key at all renders every flag false" do
      # Hand-built entries (tests, and anything predating asset retention)
      # must not crash or claim assets they never retained.
      {:ok, config} =
        Vagus.Addon.Config.parse(%{
          "name" => "X",
          "version" => "1",
          "slug" => "x",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y"
        })

      entry = %{config: config, repository: "core"}

      s = StoreView.summary("core_x", entry, false)
      assert s["icon"] == false
      assert s["documentation"] == false
    end
  end

  describe "repositories/1 — one wire entry per slug, titled the way HAOS titles it" do
    @repos_with_dupe [
      %{slug: "core", builtin: :mqtt},
      %{slug: "core", url: "https://github.com/home-assistant/addons"},
      %{slug: "community", url: "https://github.com/hassio-addons/repository"}
    ]

    test "two sources sharing a slug collapse into one entry keeping the non-nil url" do
      srv =
        start_supervised!(
          {Store, name: nil, fetcher: FixtureFetcher, repositories: @repos_with_dupe}
        )

      {:ok, _} = Store.reload(srv)
      repos = Store.repositories(srv)

      assert Enum.map(repos, & &1.slug) == ["core", "community"]

      core = Enum.find(repos, &(&1.slug == "core"))
      assert core.url == "https://github.com/home-assistant/addons"
    end

    test "names come from repository.json, else the built-in table, else the slug" do
      srv =
        start_supervised!(
          {Store,
           name: nil,
           fetcher: FixtureFetcher,
           repositories: @repos_with_dupe ++ [%{slug: "nameless", url: "https://example.test"}]}
        )

      {:ok, _} = Store.reload(srv)
      by_slug = Map.new(Store.repositories(srv), &{&1.slug, &1})

      # Parsed from the repo's own file.
      assert by_slug["community"].name == "Home Assistant Community Add-ons"
      assert by_slug["community"].maintainer == "Franck Nijhof"

      # From the built-in table: upstream's core repo ships no repository.json.
      assert by_slug["core"].name == "Official add-ons"
      assert by_slug["core"].maintainer == "Home Assistant"

      # Neither: the slug, and an empty maintainer rather than a null.
      assert by_slug["nameless"].name == "nameless"
      assert by_slug["nameless"].maintainer == ""
    end

    test "metadata only appears after a reload has actually read the repositories" do
      srv =
        start_supervised!(
          {Store, name: nil, fetcher: FixtureFetcher, repositories: @repos_with_dupe}
        )

      # Pre-reload there is no fetched metadata, but the built-in table still
      # applies and the dedupe still holds — `GET /store` is reachable before
      # any reload has run.
      by_slug = Map.new(Store.repositories(srv), &{&1.slug, &1})
      assert map_size(by_slug) == 2
      assert by_slug["core"].name == "Official add-ons"
      assert by_slug["community"].name == "community"
    end
  end

  test "StoreView.repository maps a git repo (url present) to source=url" do
    r = StoreView.repository(%{slug: "core", url: "https://github.com/home-assistant/addons"})

    assert r.slug == "core"
    assert r.url == "https://github.com/home-assistant/addons"
    assert r.source == "https://github.com/home-assistant/addons"
    assert r.name == "core"
    assert r.maintainer == ""
  end

  test "StoreView.repository tolerates a built-in repo with no :url (source=slug, url=nil)" do
    # A url-less built-in repo (M5 %{slug: "core", builtin: :mqtt}) must not
    # KeyError — that 500'd GET /store and failed the hassio config-entry setup.
    r = StoreView.repository(%{slug: "core", builtin: :mqtt})

    assert r.slug == "core"
    assert r.url == nil
    assert r.source == "core"
  end

  test "StoreView.repository prefers an explicit :source over the url (runtime-added repos)" do
    # A runtime-added repository (Vagus.Addon.Store.RepositorySpec) carries
    # the original `url#branch` string the user posted — `url` alone would
    # lose the branch suffix.
    r =
      StoreView.repository(%{
        slug: "a474bbd1",
        url: "https://github.com/awesome-developer/awesome-repo",
        source: "https://github.com/awesome-developer/awesome-repo#mybranch"
      })

    assert r.url == "https://github.com/awesome-developer/awesome-repo"
    assert r.source == "https://github.com/awesome-developer/awesome-repo#mybranch"
  end

  test "StoreView.detail adds the ext fields (StoreAddonComplete)" do
    catalog = Store.build_catalog(@repos, FixtureFetcher)
    d = StoreView.detail("core_mosquitto", catalog["core_mosquitto"], true)

    assert d["slug"] == "core_mosquitto"
    assert d["auth_api"] == true
    assert d["hassio_role"] == "default"
    assert d["apparmor"] in ["default", "disable", "profile"]
    assert d["detached"] == false
    assert d["installed"] == true
  end

  describe "store assets (P2-A P1)" do
    test "the catalog entry carries presence booleans, never bytes" do
      catalog = Store.build_catalog(@repos, FixtureFetcher, Assets.init(:memory))

      assert catalog["core_mosquitto"].assets ==
               %{icon: true, logo: true, changelog: true, documentation: true, readme: true}

      assert catalog["core_esphome"].assets ==
               %{icon: false, logo: false, changelog: false, documentation: false, readme: false}

      # The bytes live in the handle, not the entry — the whole point of a
      # presence map on a device where the catalog is held in a GenServer.
      # Assert the entry's exact shape rather than hunting for @png among its
      # values: a struct, a slug string and a booleans map can never compare
      # equal to a binary, so that search would pass even if bytes had leaked.
      entry = catalog["core_mosquitto"]
      assert Enum.sort(Map.keys(entry)) == [:assets, :config, :repository]
      assert Enum.all?(Map.values(entry.assets), &is_boolean/1)

      # And nothing nested anywhere inside it holds the bytes either.
      assert :binary.match(:erlang.term_to_binary(entry), @png) == :nomatch
    end

    test "assets are collected from the config file's own directory" do
      assets = Assets.init(:memory)
      Store.build_catalog(@repos, FixtureFetcher, assets)

      assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)
      assert {:ok, "## 7.1.0\n"} = Assets.get(@mosquitto, :changelog, assets)
      assert {:ok, "# Mosquitto\n"} = Assets.get(@mosquitto, :documentation, assets)

      # The repo-root CHANGELOG.md is nobody's sibling.
      assert :error = Assets.get(@esphome, :changelog, assets)
    end

    @tag :tmp_dir
    test "memory and disk modes are observationally identical", %{tmp_dir: tmp_dir} do
      memory = Assets.init(:memory)
      disk = Assets.init(:disk, root: Path.join(tmp_dir, "store_assets"))

      from_memory = Store.build_catalog(@repos, FixtureFetcher, memory)
      from_disk = Store.build_catalog(@repos, FixtureFetcher, disk)

      assert from_memory == from_disk

      for {_slug, entry} <- from_memory, kind <- Assets.kinds() do
        id = Assets.id(entry)
        assert Assets.get(id, kind, memory) == Assets.get(id, kind, disk)
      end
    end

    test "an over-cap asset is dropped, logged, and reported absent" do
      defmodule FatIconFetcher do
        def fetch(%{slug: "core"}) do
          over = :binary.copy("x", Vagus.Addon.Store.Assets.max_bytes(:icon) + 1)

          {:ok,
           [
             {"mosquitto/config.yaml", Vagus.Addon.StoreTest.mosquitto_yaml()},
             {"mosquitto/icon.png", over},
             {"mosquitto/logo.png", Vagus.Addon.StoreTest.png()}
           ]}
        end
      end

      assets = Assets.init(:memory)

      log =
        capture_log(fn ->
          catalog = Store.build_catalog(@repos, FatIconFetcher, assets)
          send(self(), {:catalog, catalog})
        end)

      assert_received {:catalog, catalog}

      # Indistinguishable, downstream, from a repo that shipped no icon —
      # and the logo beside it is unaffected.
      assert catalog["core_mosquitto"].assets.icon == false
      assert catalog["core_mosquitto"].assets.logo == true
      assert :error = Assets.get(@mosquitto, :icon, assets)
      assert log =~ "dropping icon for core/mosquitto"
      assert log =~ ":too_large"
    end

    test "an asset the repo stopped shipping is deleted, not left stale" do
      defmodule DeicedFetcher do
        def fetch(%{slug: "core"}) do
          {:ok, [{"mosquitto/config.yaml", Vagus.Addon.StoreTest.mosquitto_yaml()}]}
        end
      end

      assets = Assets.init(:memory)

      Store.build_catalog(@repos, FixtureFetcher, assets)
      assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)

      catalog = Store.build_catalog(@repos, DeicedFetcher, assets)

      assert catalog["core_mosquitto"].assets.icon == false
      assert :error = Assets.get(@mosquitto, :icon, assets)
    end

    test "two repos colliding into one store slug keep their own assets" do
      # `core` + `mqtt_broker` and `core_mqtt` + `broker` both render the store
      # slug "core_mqtt_broker", so the catalog's `Map.merge` keeps exactly one
      # of the two configs. This drives that real collision path (not `Assets`
      # in isolation) to prove the surviving entry's assets are its OWN — with
      # store-slug-keyed storage the loser's icon could land on the winner's
      # key and the store would serve one repo's config beside another's art.
      defmodule CollidingFetcher do
        @yaml """
        name: MQTT broker
        version: "1.0.0"
        slug: SLUG
        description: collision fixture
        arch:
          - aarch64
        """

        def fetch(%{slug: "core"}) do
          {:ok,
           [
             {"mqtt_broker/config.yaml", String.replace(@yaml, "SLUG", "mqtt_broker")},
             {"mqtt_broker/icon.png", Vagus.Addon.StoreTest.png() <> "core"}
           ]}
        end

        def fetch(%{slug: "core_mqtt"}) do
          {:ok,
           [
             {"broker/config.yaml", String.replace(@yaml, "SLUG", "broker")},
             {"broker/icon.png", Vagus.Addon.StoreTest.png() <> "core_mqtt"}
           ]}
        end
      end

      assets = Assets.init(:memory)
      repos = [%{slug: "core", url: "x"}, %{slug: "core_mqtt", url: "y"}]

      catalog = Store.build_catalog(repos, CollidingFetcher, assets)

      # Exactly one entry survives, and which one is deterministic:
      # `build_catalog/3` reduces with `Map.merge(acc, from_this_repo)`, and
      # the right-hand side wins, so the *last* repo in the list takes the
      # slug. Assert that rather than hedging — a change in merge order is
      # something this test should catch, not tolerate.
      assert map_size(catalog) == 1
      entry = catalog["core_mqtt_broker"]
      assert entry.repository == "core_mqtt"
      assert entry.config.slug == "broker"
      assert entry.assets.icon

      assert Assets.get(Assets.id(entry), :icon, assets) == {:ok, png() <> entry.repository}

      # Both repos' bytes survive independently; neither clobbered the other.
      assert {:ok, png() <> "core"} == Assets.get({"core", "mqtt_broker"}, :icon, assets)
      assert {:ok, png() <> "core_mqtt"} == Assets.get({"core_mqtt", "broker"}, :icon, assets)
    end

    test "a repo that fails to fetch leaves the other repo's assets intact" do
      assets = Assets.init(:memory)
      repos = [%{slug: "broken", url: "x"} | @repos]

      catalog = Store.build_catalog(repos, FixtureFetcher, assets)

      assert map_size(catalog) == 2
      assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)
    end

    test "reload prunes assets for add-ons that left the catalog" do
      # Reads its answer from the *calling* process — which is this test,
      # because `build_catalog/3` deliberately runs in the caller and not in
      # the GenServer. That makes a two-reload script possible without
      # reaching into the server's state, and keeps this test `async: true`.
      defmodule ScriptedFetcher do
        def fetch(%{slug: "core"}), do: Process.get(:next_fetch)
      end

      srv = start_supervised!({Store, name: nil, fetcher: ScriptedFetcher, repositories: @repos})
      assets = Store.assets(srv)

      Process.put(:next_fetch, FixtureFetcher.fetch(%{slug: "core"}))
      assert {:ok, 2} = Store.reload(srv)
      assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)

      # Second reload: the repo no longer carries mosquitto at all.
      Process.put(:next_fetch, {:ok, [{"esphome/config.yaml", esphome_yaml()}]})
      log = capture_log(fn -> assert {:ok, 1} = Store.reload(srv) end)

      assert :error = Assets.get(@mosquitto, :icon, assets)
      assert log =~ "pruned assets for 1 add-on(s)"
    end

    @tag :tmp_dir
    test "disk mode outlives the Store; memory mode does not", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")

      opts = [name: nil, fetcher: FixtureFetcher, repositories: @repos]
      disk = start_supervised!({Store, [asset_mode: :disk, root: root] ++ opts}, id: :store_disk)
      assert {:ok, 2} = Store.reload(disk)
      :ok = stop_supervised!(:store_disk)

      # A fresh store over the same root serves the icon with no reload —
      # which is the entire reason `:disk` mode exists on a small board.
      reborn = start_supervised!({Store, [asset_mode: :disk, root: root] ++ opts}, id: :reborn)
      assert {:ok, @png} = Assets.get(@mosquitto, :icon, Store.assets(reborn))

      memory = start_supervised!({Store, [asset_mode: :memory] ++ opts}, id: :store_memory)
      assert {:ok, 2} = Store.reload(memory)
      :ok = stop_supervised!(:store_memory)

      revived = start_supervised!({Store, [asset_mode: :memory] ++ opts}, id: :revived)
      assert :error = Assets.get(@mosquitto, :icon, Store.assets(revived))
    end

    test "a reload during a reload is a no-op, not a wait and not an error" do
      # Interleaving is what produces a torn store: one reload writes assets
      # for its catalog while another prunes against a different one, and the
      # survivor advertises `assets.icon == true` with no bytes behind it.
      #
      # The second caller returns immediately rather than queueing — matching
      # the real Supervisor, whose `GitRepo.pull` opens with
      # `if self.lock.locked(): return False` and whose `StoreManager.reload`
      # reports that as success, not an error. Blocking would pin a Bandit
      # worker for a whole network-bound reload.
      #
      # The fetcher parks mid-fetch so the second call lands in a known window
      # rather than a timing-dependent one. It gets the test's pid via the repo
      # map because it runs in the *caller's* process, not the test's.
      defmodule ParkingFetcher do
        def fetch(%{slug: "core", test_pid: pid}) do
          send(pid, {:fetch_started, self()})

          # No `after` clause: a hang must hang the test, not quietly resume
          # and let it pass.
          receive do
            :proceed -> :ok
          end

          {:ok, [{"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}]}
        end
      end

      repos = [%{slug: "core", url: "x", test_pid: self()}]
      srv = start_supervised!({Store, name: nil, fetcher: ParkingFetcher, repositories: repos})

      first = Task.async(fn -> Store.reload(srv) end)
      assert_receive {:fetch_started, first_caller}, 5_000

      # Returns straight away, while the first is still parked mid-fetch —
      # and reports the catalog as it currently stands (empty; the first
      # reload hasn't swapped yet).
      log = capture_log(fn -> assert {:ok, 0} = Store.reload(srv) end)
      assert log =~ "reload already in progress, skipping"

      # It really was a no-op: it never entered a fetch of its own.
      refute_received {:fetch_started, _other}

      send(first_caller, :proceed)
      assert {:ok, 1} = Task.await(first, 5_000)

      # The lock is released, so a later reload works normally.
      next = Task.async(fn -> Store.reload(srv) end)
      assert_receive {:fetch_started, next_caller}, 5_000
      send(next_caller, :proceed)
      assert {:ok, 1} = Task.await(next, 5_000)
    end

    test "the ETS table dies with the Store that owned it" do
      srv = start_supervised!({Store, name: nil, fetcher: FixtureFetcher, repositories: @repos})
      assert {:ok, 2} = Store.reload(srv)
      assets = Store.assets(srv)

      ref = Process.monitor(srv)
      :ok = stop_supervised!(Store)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      # Not merely empty — gone, so a leaked handle can't outlive its owner.
      assert catch_error(Assets.get(@mosquitto, :icon, assets))
    end
  end

  describe "file persistence across process restart (boot reload)" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "vagus_test_store_repositories_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "a persisted repo is layered after config repos, and survives a restart on the same path",
         %{path: path} do
      source = "https://github.com/awesome-developer/awesome-repo"
      File.write!(path, Jason.encode!([source]))

      srv =
        start_supervised!(
          {Store, name: nil, path: path, fetcher: FixtureFetcher, repositories: @repos}
        )

      repos = Store.repositories(srv)
      assert Enum.map(repos, & &1.slug) == ["core", "a474bbd1"]

      persisted = Enum.find(repos, &(&1.slug == "a474bbd1"))
      assert persisted.url == source
      # Pre-reload, no repository.* has been fetched for it yet — same
      # "meta needs a reload" invariant the config-declared repos observe.
      assert persisted.name == "a474bbd1"

      stop_supervised!(Store)

      srv2 =
        start_supervised!(
          {Store, name: nil, path: path, fetcher: FixtureFetcher, repositories: @repos}
        )

      repos2 = Store.repositories(srv2)
      assert Enum.map(repos2, & &1.slug) == ["core", "a474bbd1"]
    end

    test "a missing persisted file has no persisted repos, only config ones", %{path: path} do
      refute File.exists?(path)

      srv =
        start_supervised!(
          {Store, name: nil, path: path, fetcher: FixtureFetcher, repositories: @repos}
        )

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
    end

    test "a corrupt/malformed-JSON file is tolerated: config repos only, no crash", %{path: path} do
      File.write!(path, "not json { at all")

      srv =
        start_supervised!(
          {Store, name: nil, path: path, fetcher: FixtureFetcher, repositories: @repos}
        )

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
    end

    test "a JSON value that isn't a list is treated as corrupt: config repos only", %{path: path} do
      File.write!(path, Jason.encode!(%{"not" => "a list"}))

      srv =
        start_supervised!(
          {Store, name: nil, path: path, fetcher: FixtureFetcher, repositories: @repos}
        )

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
    end

    test "wrong-typed and invalid-format entries are dropped; valid siblings still load, a warning is logged",
         %{path: path} do
      valid = "https://github.com/awesome-developer/awesome-repo"
      invalid = "not-a-url-#{System.unique_integer([:positive])}"
      File.write!(path, Jason.encode!([valid, 123, %{"a" => 1}, invalid]))

      log =
        capture_log(fn ->
          started =
            start_supervised!(
              {Store, name: nil, path: path, fetcher: FixtureFetcher, repositories: @repos}
            )

          send(self(), {:started, started})
        end)

      assert_received {:started, srv}

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core", "a474bbd1"]
      assert log =~ invalid
      assert log =~ "123"
    end
  end

  describe "runtime add/remove/repair (issue #5, phase 3)" do
    @awesome "https://github.com/awesome-developer/awesome-repo"
    @awesome_slug "a474bbd1"

    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "vagus_test_store_mutation_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "add fetches, persists, and reloads before returning — catalog + meta are live",
         %{path: path} do
      srv = start_mutable_store(path)

      assert :ok = Store.add_repository(srv, @awesome)

      repos = Store.repositories(srv)
      assert Enum.map(repos, & &1.slug) == ["core", @awesome_slug]

      added = Enum.find(repos, &(&1.slug == @awesome_slug))
      # From the added repo's own repository.json — only a completed reload
      # could know it, which is the point of `add_repository/2` blocking on one.
      assert added.name == "Awesome add-ons"
      assert added.maintainer == "Awesome Dev"
      assert added.ref == "HEAD"

      # Its add-ons are in the catalog by the time `:ok` came back.
      assert {:ok, %{repository: @awesome_slug}} = Store.get("#{@awesome_slug}_esphome", srv)

      # The raw source string is what lands on disk (upstream parity, D4).
      assert Jason.decode!(File.read!(path)) == [@awesome]

      # And the wire view: the 5-key repository shape with `source` = the
      # string the user posted.
      assert StoreView.repository(added) == %{
               slug: @awesome_slug,
               name: "Awesome add-ons",
               source: @awesome,
               url: @awesome,
               maintainer: "Awesome Dev"
             }
    end

    test "a #branch suffix survives into ref, slug, and the wire's source", %{path: path} do
      srv = start_mutable_store(path)
      source = @awesome <> "#beta"

      assert :ok = Store.add_repository(srv, source)

      added = Enum.find(Store.repositories(srv), &(&1.slug == RepositorySpec.slug(source)))
      assert added.slug != @awesome_slug
      assert added.ref == "beta"
      assert added.url == @awesome
      assert StoreView.repository(added).source == source
      assert Jason.decode!(File.read!(path)) == [source]
    end

    test "re-adding the same string is a duplicate by slug", %{path: path} do
      srv = start_mutable_store(path)
      assert :ok = Store.add_repository(srv, @awesome)

      assert {:error, {:duplicate, @awesome}} = Store.add_repository(srv, @awesome)
      assert Jason.decode!(File.read!(path)) == [@awesome]
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core", @awesome_slug]
    end

    test "a decoupling payload (non-github host) is rejected on format, nothing persisted",
         %{path: path} do
      srv = start_mutable_store(path)

      assert {:error, :invalid_format} = Store.add_repository(srv, "https://notgithub.com/a/b")
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      refute File.exists?(path)
    end

    test "a decoupling payload (ref path-traversal) is rejected on format, nothing persisted",
         %{path: path} do
      srv = start_mutable_store(path)

      traversal = "https://github.com/home-assistant/addons/#../../../attacker/evil/tar.gz/main"
      assert {:error, :invalid_format} = Store.add_repository(srv, traversal)
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      refute File.exists?(path)
    end

    test "trivial url variants collapse to one repo: …, …/ , and ….git are duplicates",
         %{path: path} do
      srv = start_mutable_store(path)
      assert :ok = Store.add_repository(srv, @awesome)

      # The dedupe fires before any fetch, so these variants never reach the
      # fixture fetcher (which only matches the exact url).
      assert {:error, {:duplicate, _}} = Store.add_repository(srv, @awesome <> "/")
      assert {:error, {:duplicate, _}} = Store.add_repository(srv, @awesome <> ".git")

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core", @awesome_slug]
      assert Jason.decode!(File.read!(path)) == [@awesome]
    end

    test "adding beyond @max_repositories is rejected and nothing is persisted past the cap",
         %{path: path} do
      # Seed the persisted set at the cap (50) directly on disk — deriving these
      # at boot doesn't fetch, so it's cheap and hermetic.
      sources = for i <- 1..50, do: "https://github.com/o/r#{i}"
      File.write!(path, Jason.encode!(sources))

      srv = start_mutable_store(path)
      # The wire view always carries a `source` key (nil for config repos), so
      # count only the persisted (non-nil source) ones — the set the cap bounds.
      assert Enum.count(Store.repositories(srv), &(&1.source != nil)) == 50

      assert {:error, :repo_limit} = Store.add_repository(srv, @awesome)

      # The 51st was never appended or written.
      assert Jason.decode!(File.read!(path)) == sources
      refute Enum.any?(Store.repositories(srv), &(&1.slug == @awesome_slug))
    end

    test "a built-in's URL is a duplicate however it is cased", %{path: path} do
      # Vagus's built-ins keep human slugs where upstream hashes every URL into
      # one, so only the URL comparison catches this (D3).
      srv = start_mutable_store(path)

      assert {:error, {:duplicate, _url}} =
               Store.add_repository(srv, "HTTPS://GitHub.COM/Home-Assistant/Addons")

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      refute File.exists?(path)
    end

    test "garbage is rejected on format, before any fetch", %{path: path} do
      srv = start_mutable_store(path)

      assert {:error, :invalid_format} = Store.add_repository(srv, "not a repository at all")
      assert {:error, :invalid_format} = Store.add_repository(srv, "#only-a-branch")
      assert {:error, :invalid_format} = Store.add_repository(srv, "")
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      refute File.exists?(path)
    end

    test "a candidate that won't fetch is invalid_repository, and nothing is written",
         %{path: path} do
      srv = start_mutable_store(path)

      log =
        capture_log(fn ->
          assert {:error, {:invalid_repository, "https://github.com/example/gone"}} =
                   Store.add_repository(srv, "https://github.com/example/gone")
        end)

      assert log =~ "did not fetch"
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      refute File.exists?(path)
    end

    test "a candidate with no repository.{json,yaml,yml} is invalid_repository", %{path: path} do
      srv = start_mutable_store(path)

      assert {:error, {:invalid_repository, "https://github.com/example/no-repository-file"}} =
               Store.add_repository(srv, "https://github.com/example/no-repository-file")

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      refute File.exists?(path)
    end

    test "remove drops the repo, its catalog entries, and its persisted line", %{path: path} do
      srv = start_mutable_store(path)
      assert :ok = Store.add_repository(srv, @awesome)

      assert :ok = Store.remove_repository(srv, @awesome_slug)

      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
      assert :error = Store.get("#{@awesome_slug}_esphome", srv)
      assert Jason.decode!(File.read!(path)) == []
      # The reload that followed the removal still loaded the config repo.
      assert {:ok, _} = Store.get("core_mosquitto", srv)
    end

    test "a config-declared repository is built-in and cannot be removed", %{path: path} do
      srv = start_mutable_store(path)

      assert {:error, :builtin} = Store.remove_repository(srv, "core")
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core"]
    end

    test "an unknown slug is not_found", %{path: path} do
      srv = start_mutable_store(path)
      assert {:error, :not_found} = Store.remove_repository(srv, "deadbeef")
    end

    test "a repository an installed add-on came from is in_use, quoting its source",
         %{path: path} do
      addon_state = start_supervised!({State, name: nil, persist_path: nil})
      srv = start_mutable_store(path, addon_state: addon_state)

      assert :ok = Store.add_repository(srv, @awesome)
      install(addon_state, "#{@awesome_slug}_esphome")

      assert {:error, {:in_use, @awesome}} = Store.remove_repository(srv, @awesome_slug)
      assert Enum.map(Store.repositories(srv), & &1.slug) == ["core", @awesome_slug]
      assert Jason.decode!(File.read!(path)) == [@awesome]
    end

    test "an add-on installed from another repository does not hold this one back",
         %{path: path} do
      # The association is the catalog entry's `:repository` field, not the
      # store slug's prefix: `core_mosquitto` is installed from `core` and says
      # nothing about the runtime-added repo.
      addon_state = start_supervised!({State, name: nil, persist_path: nil})
      srv = start_mutable_store(path, addon_state: addon_state)

      assert :ok = Store.add_repository(srv, @awesome)
      install(addon_state, "core_mosquitto")

      assert :ok = Store.remove_repository(srv, @awesome_slug)
    end

    test "repair reloads and reports the target repo as healthy", %{path: path} do
      srv = start_mutable_store(path)
      assert :ok = Store.add_repository(srv, @awesome)

      assert :ok = Store.repair_repository(srv, @awesome_slug)
      assert :ok = Store.repair_repository(srv, "core")
      assert {:ok, _} = Store.get("#{@awesome_slug}_esphome", srv)
    end

    test "repairing an unknown slug is not_found", %{path: path} do
      srv = start_mutable_store(path)
      assert {:error, :not_found} = Store.repair_repository(srv, "deadbeef")
    end

    test "repair carries the real fetch error when the target repo won't come down",
         %{path: path} do
      srv =
        start_supervised!(
          {Store,
           name: nil,
           path: path,
           fetcher: MutationFetcher,
           repositories: @repos ++ [%{slug: "broken", url: "https://example.test/broken"}]}
        )

      log =
        capture_log(fn ->
          assert {:error, {:fetch_failed, :nxdomain}} = Store.repair_repository(srv, "broken")
        end)

      assert log =~ "fetch \"broken\" failed"

      # The healthy repo in the same reload is unaffected, and reports so.
      assert capture_log(fn -> assert :ok = Store.repair_repository(srv, "core") end) =~ "broken"
    end

    test "a repository that fetches but ships nothing is healthy, not fetch_failed",
         %{path: path} do
      # "Absent from the catalog" is not "failed to fetch" — the built-in mqtt
      # source returns `{:ok, []}` and must not be reported as broken.
      srv =
        start_supervised!(
          {Store,
           name: nil,
           path: path,
           fetcher: FixtureFetcher,
           repositories: [%{slug: "nameless", url: "https://example.test"}]}
        )

      assert :ok = Store.repair_repository(srv, "nameless")
    end

    test "a mutation contending with an in-flight reload is busy, never queued", %{path: path} do
      # Same `retries: 0` mutex `reload/1` takes — but a mutation that did not
      # happen cannot be reported as success, so it says so instead.
      defmodule ParkingMutationFetcher do
        def fetch(%{slug: "core", test_pid: pid}) do
          send(pid, {:fetch_started, self()})

          receive do
            :proceed -> :ok
          end

          {:ok, []}
        end
      end

      repos = [%{slug: "core", url: "https://github.com/home-assistant/addons", test_pid: self()}]

      srv =
        start_supervised!(
          {Store, name: nil, path: path, fetcher: ParkingMutationFetcher, repositories: repos}
        )

      first = Task.async(fn -> Store.reload(srv) end)
      assert_receive {:fetch_started, first_caller}, 5_000

      log =
        capture_log(fn ->
          assert {:error, :busy} = Store.add_repository(srv, @awesome)
          assert {:error, :busy} = Store.remove_repository(srv, @awesome_slug)
          assert {:error, :busy} = Store.repair_repository(srv, "core")
        end)

      assert log =~ "add_repository skipped"
      assert log =~ "remove_repository skipped"
      assert log =~ "repair_repository skipped"

      # None of the three got as far as a fetch or a write of its own.
      refute_received {:fetch_started, _other}
      refute File.exists?(path)

      send(first_caller, :proceed)
      assert {:ok, 0} = Task.await(first, 5_000)
    end
  end

  defp start_mutable_store(path, opts \\ []) do
    start_supervised!(
      {Store, [name: nil, path: path, fetcher: MutationFetcher, repositories: @repos] ++ opts}
    )
  end
end
