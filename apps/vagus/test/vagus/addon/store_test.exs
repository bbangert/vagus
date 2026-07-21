defmodule Vagus.Addon.StoreTest do
  @moduledoc "P2-T3: the add-on store — catalog building, GenServer, and store views."
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Store, StoreView}

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

  # A fetcher returning an in-memory repo tree (config.yaml at add-on dirs, plus
  # noise that must be ignored). Matches the `fetch/1` contract.
  defmodule FixtureFetcher do
    def fetch(%{slug: "core"}) do
      {:ok,
       [
         {"README.md", "ignore me"},
         {"mosquitto/config.yaml", Vagus.Addon.StoreTest.mosquitto_yaml()},
         {"mosquitto/Dockerfile", "FROM scratch"},
         {"esphome/config.yaml", Vagus.Addon.StoreTest.esphome_yaml()}
       ]}
    end

    def fetch(%{slug: "broken"}), do: {:error, :nxdomain}
  end

  def mosquitto_yaml, do: @mosquitto_yaml
  def esphome_yaml, do: @esphome_yaml

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
    s = StoreView.summary("core_mosquitto", catalog["core_mosquitto"])

    assert s["slug"] == "core_mosquitto"
    assert s["repository"] == "core"
    assert s["name"] == "Mosquitto broker"
    assert s["version"] == "7.1.0"
    assert s["version_latest"] == "7.1.0"
    assert s["arch"] == ["aarch64", "amd64"]
    assert s["build"] == false
    refute Map.has_key?(s, "auth_api")
  end

  test "StoreView.detail adds the ext fields (StoreAddonComplete)" do
    catalog = Store.build_catalog(@repos, FixtureFetcher)
    d = StoreView.detail("core_mosquitto", catalog["core_mosquitto"])

    assert d["slug"] == "core_mosquitto"
    assert d["auth_api"] == true
    assert d["hassio_role"] == "default"
    assert d["apparmor"] in ["default", "disable", "profile"]
    assert d["detached"] == false
  end
end
