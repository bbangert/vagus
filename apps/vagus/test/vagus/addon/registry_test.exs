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
        "discovery" => ["mqtt"]
      })

    assert Registry.identity_from_config(config) == %{
             slug: "core_mosquitto",
             services_role: %{"mqtt" => "provide"},
             auth_api: true,
             discovery: ["mqtt"]
           }
  end
end
