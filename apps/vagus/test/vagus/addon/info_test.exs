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
    assert info["watchdog"] == false
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

  defp ingress_config(overrides \\ %{}) do
    base = %{
      "name" => "ESPHome",
      "version" => "1.0.0",
      "slug" => "core_esphome",
      "description" => "ESPHome dashboard",
      "arch" => ["amd64"],
      "ingress" => true,
      "ingress_port" => 0
    }

    {:ok, c} = Config.parse(Map.merge(base, overrides))
    c
  end

  describe "ingress rendering (§B3.4) + watchdog (§B8)" do
    test "ingress add-on with full settings renders entry/url/port/panel" do
      c = ingress_config(%{"ingress_entry" => "dashboard"})

      settings = %{
        ingress_token: "tok123",
        ingress_port: 63_412,
        ingress_panel: true,
        watchdog: true
      }

      info = Info.render(c, :started, %{}, settings)

      assert info["ingress"] == true
      assert info["ingress_entry"] == "/api/hassio_ingress/tok123"
      assert info["ingress_url"] == "/api/hassio_ingress/tok123/dashboard"
      assert info["ingress_port"] == 63_412
      assert info["ingress_panel"] == true
      assert info["watchdog"] == true
    end

    test "dynamic ingress_port unresolved (no allocated port yet) renders nil, not 0" do
      c = ingress_config()
      info = Info.render(c, :started, %{}, %{ingress_token: "tok123"})

      assert info["ingress_port"] == nil
      assert info["ingress_entry"] == "/api/hassio_ingress/tok123"
      assert info["ingress_url"] == "/api/hassio_ingress/tok123/"
    end

    test "static (non-zero) ingress_port is served as-is when settings doesn't override it" do
      c = ingress_config(%{"ingress_port" => 8099})
      info = Info.render(c, :started, %{}, %{ingress_token: "tok123"})
      assert info["ingress_port"] == 8099
    end

    test "no settings supplied at all: ingress add-on still renders honest nil/false" do
      c = ingress_config()
      info = Info.render(c, :started, %{})

      assert info["ingress_entry"] == nil
      assert info["ingress_url"] == nil
      assert info["ingress_port"] == nil
      assert info["ingress_panel"] == false
      assert info["watchdog"] == false
    end

    test "non-ingress add-on: ingress fields are nil/false regardless of settings" do
      {:ok, c} =
        Config.parse(%{
          "name" => "Plain",
          "version" => "1",
          "slug" => "plain",
          "description" => "d",
          "arch" => ["amd64"]
        })

      info =
        Info.render(c, :started, %{}, %{
          ingress_token: "tok123",
          ingress_port: 63_000,
          ingress_panel: true,
          watchdog: true
        })

      assert info["ingress"] == false
      assert info["ingress_entry"] == nil
      assert info["ingress_url"] == nil
      assert info["ingress_port"] == nil
      assert info["ingress_panel"] == false
      # watchdog is NOT gated on the `ingress` capability flag — it's an
      # independent per-install setting (§B8).
      assert info["watchdog"] == true
    end

    test "webui rendered with mapped port + literal [HOST]" do
      {:ok, c} =
        Config.parse(%{
          "name" => "ESPHome",
          "version" => "1.0.0",
          "slug" => "core_esphome",
          "description" => "d",
          "arch" => ["amd64"],
          "webui" => "http://[HOST]:[PORT:6052]/",
          "ports" => %{"6052/tcp" => 31_337}
        })

      info = Info.render(c, :started, %{})

      assert info["webui"] == "http://[HOST]:31337/"
    end

    test "nil webui template renders nil" do
      {:ok, c} =
        Config.parse(%{
          "name" => "Plain",
          "version" => "1",
          "slug" => "plain",
          "description" => "d",
          "arch" => ["amd64"]
        })

      assert Info.render(c, :started, %{})["webui"] == nil
    end

    test "watchdog reflects the persisted settings, not config's URL-template presence" do
      {:ok, c} =
        Config.parse(%{
          "name" => "Mosquitto broker",
          "version" => "7.1.0",
          "slug" => "core_mosquitto",
          "description" => "d",
          "arch" => ["amd64"],
          "watchdog" => "tcp://[HOST]:1883"
        })

      assert Info.render(c, :started, %{})["watchdog"] == false
      assert Info.render(c, :started, %{}, %{watchdog: true})["watchdog"] == true
      assert Info.render(c, :started, %{}, %{watchdog: false})["watchdog"] == false
    end
  end
end
