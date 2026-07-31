defmodule Vagus.Addon.RegistryTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, Registry}

  setup do
    reg = start_supervised!({Registry, name: :"reg_#{System.unique_integer([:positive])}"})
    %{reg: reg}
  end

  test "register + lookup", %{reg: reg} do
    id = %{
      slug: "core_mosquitto",
      services_role: %{"mqtt" => "provide"},
      auth_api: true,
      discovery: ["mqtt"]
    }

    assert :ok = Registry.register("tok-a", id, reg)
    assert {:ok, ^id} = Registry.identity_for_token("tok-a", reg)
    assert :error = Registry.identity_for_token("unknown", reg)
  end

  test "re-register for a slug drops the old token", %{reg: reg} do
    id = %{slug: "x", services_role: %{}, auth_api: false, discovery: []}
    Registry.register("old", id, reg)
    Registry.register("new", id, reg)
    assert :error = Registry.identity_for_token("old", reg)
    assert {:ok, ^id} = Registry.identity_for_token("new", reg)
  end

  test "unregister_slug removes the token", %{reg: reg} do
    id = %{slug: "y", services_role: %{}, auth_api: false, discovery: []}
    Registry.register("t", id, reg)
    assert :ok = Registry.unregister_slug("y", reg)
    assert :error = Registry.identity_for_token("t", reg)
  end

  test "identity_from_config derives grants from config.yaml fields" do
    {:ok, config} =
      Config.parse(%{
        "name" => "M",
        "version" => "1",
        "slug" => "core_mosquitto",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "services" => ["mqtt:provide"],
        "auth_api" => true,
        "discovery" => ["mqtt"],
        "hassio_api" => true,
        "hassio_role" => "manager",
        "homeassistant_api" => true
      })

    assert Registry.identity_from_config(config) == %{
             slug: "core_mosquitto",
             services_role: %{"mqtt" => "provide"},
             auth_api: true,
             discovery: ["mqtt"],
             hassio_api: true,
             hassio_role: "manager",
             homeassistant_api: true
           }
  end

  # `.claude/plans/vagus-core-api-proxy/plan.md` phase 1: `homeassistant_api`
  # is what the Core-API proxy's `_check_access` equivalent grades a caller
  # with, and it's the same shape of gap `hassio_api`/`hassio_role` were
  # before the 2026-07-29 audit — `Vagus.Addon.Config` parsed it, but
  # `identity_from_config/1` dropped it because nothing consumed it yet.
  test "identity_from_config carries homeassistant_api through" do
    {:ok, config} =
      Config.parse(%{
        "name" => "M",
        "version" => "1",
        "slug" => "core_ha_api",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "homeassistant_api" => true
      })

    assert %{homeassistant_api: true} = Registry.identity_from_config(config)
  end

  # `hassio_api`/`hassio_role` are what `Vagus.API.Tiers` grades a caller
  # with, and `Vagus.Addon.Config`'s defaults are the closed ones. An add-on
  # that declares neither must arrive here as "no API access, default role" —
  # if this silently became `hassio_api: true`, every installed add-on would
  # regain the manager-tier reach the 2026-07-29 audit found (A1/A2).
  test "identity_from_config defaults an add-on that declares no API access to closed" do
    {:ok, config} =
      Config.parse(%{
        "name" => "M",
        "version" => "1",
        "slug" => "quiet",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y"
      })

    assert %{hassio_api: false, hassio_role: "default", homeassistant_api: false} =
             Registry.identity_from_config(config)
  end
end
