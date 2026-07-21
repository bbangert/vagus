defmodule Vagus.Addon.InfoTest do
  @moduledoc "AddonInfo (InstalledAddonComplete) rendering."
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, Info}

  setup do
    {:ok, c} =
      Config.parse(%{
        "name" => "Mosquitto broker",
        "version" => "7.1.0",
        "slug" => "core_mosquitto",
        "description" => "An Open Source MQTT broker",
        "arch" => ["aarch64", "amd64"],
        "auth_api" => true,
        "services" => ["mqtt:provide"],
        "discovery" => ["mqtt"],
        "startup" => "system",
        "watchdog" => "tcp://[HOST]:1883",
        "ports" => %{"1883/tcp" => 1883}
      })

    %{config: c}
  end

  test "renders the fields Core's discovery + the model need", %{config: c} do
    info = Info.render(c, :started, %{"require_certificate" => false})

    assert info["name"] == "Mosquitto broker"
    assert info["slug"] == "core_mosquitto"
    assert info["hostname"] == "core-mosquitto"
    assert info["state"] == "started"
    assert info["version"] == "7.1.0"
    assert info["arch"] == ["aarch64", "amd64"]
    assert info["auth_api"] == true
    assert info["services"] == ["mqtt:provide"]
    assert info["discovery"] == ["mqtt"]
    assert info["startup"] == "system"
    assert info["options"] == %{"require_certificate" => false}
    assert info["network"] == %{"1883/tcp" => 1883}
    assert info["watchdog"] == true
    assert info["ip_address"] == "0.0.0.0"
    # wire alias keys (not the model's supervisor_* names)
    assert Map.has_key?(info, "hassio_api")
    assert Map.has_key?(info, "hassio_role")
    # nullable-but-required fields are present as nil
    assert Map.has_key?(info, "webui")
    assert Map.has_key?(info, "system_managed_config_entry")
  end

  test "enum-typed fields use accepted string values", %{config: c} do
    info = Info.render(c, :started, %{})
    assert info["stage"] in ["stable", "experimental", "deprecated"]
    assert info["boot"] in ["auto", "manual"]
    assert info["apparmor"] in ["default", "disable", "profile"]
    assert info["hassio_role"] in ["admin", "backup", "default", "homeassistant", "manager"]
  end
end
