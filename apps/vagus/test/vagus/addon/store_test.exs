defmodule Vagus.Addon.StoreTest do
  @moduledoc "P2-T3: the add-on store — catalog building, GenServer, and store views."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.{Store, StoreView}
  alias Vagus.Addon.Store.Assets

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

  @esphome_yaml """
  name: ESPHome
  version: "2025.1.0"
  slug: esphome
  description: ESPHome dashboard
  arch:
    - aarch64
  image: esphome/{arch}-addon
  ingress: true
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
         {"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}
       ]}
    end

    def fetch(%{slug: "broken"}), do: {:error, :nxdomain}
  end

  def mosquitto_yaml, do: @mosquitto_yaml
  def esphome_yaml, do: @esphome_yaml
  def png, do: @png

  @repos [%{slug: "core", url: "https://github.com/home-assistant/addons"}]

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
    assert s["version"] == "7.1.0"
    assert s["version_latest"] == "7.1.0"
    assert s["arch"] == ["aarch64", "amd64"]
    assert s["build"] == false
    assert s["installed"] == false
    refute Map.has_key?(s, "auth_api")
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
               %{icon: true, logo: true, changelog: true, documentation: true}

      assert catalog["core_esphome"].assets ==
               %{icon: false, logo: false, changelog: false, documentation: false}

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
             {"mqtt_broker/icon.png", "icon from core"}
           ]}
        end

        def fetch(%{slug: "core_mqtt"}) do
          {:ok,
           [
             {"broker/config.yaml", String.replace(@yaml, "SLUG", "broker")},
             {"broker/icon.png", "icon from core_mqtt"}
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

      assert Assets.get(Assets.id(entry), :icon, assets) == {:ok, "icon from #{entry.repository}"}

      # Both repos' bytes survive independently; neither clobbered the other.
      assert {:ok, "icon from core"} = Assets.get({"core", "mqtt_broker"}, :icon, assets)
      assert {:ok, "icon from core_mqtt"} = Assets.get({"core_mqtt", "broker"}, :icon, assets)
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
end
