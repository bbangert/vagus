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
    # G1: real, not the previous hardcoded true/[]/nil — see the "availability"
    # describe block below for the full matrix.
    assert info["available"] == true
    assert info["machine"] == []
    assert info["homeassistant"] == nil
    # E1/E2: honest defaults with no settings supplied at all.
    assert info["boot"] == "auto"
    assert info["boot_config"] == "auto"
    assert info["auto_update"] == false
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

  describe "asset advertisement (the installed-add-ons page fetches nothing it isn't told about)" do
    test "the store entry's flags reach the payload", %{config: c} do
      info =
        Info.render(c, :started, %{}, %{
          assets: %{icon: true, logo: true, changelog: true, documentation: false}
        })

      assert info["icon"] == true
      assert info["logo"] == true
      assert info["changelog"] == true
      assert info["documentation"] == false
    end

    test "a detached add-on (no store entry, so no assets) advertises none", %{config: c} do
      info = Info.render(c, :started, %{}, %{version_latest: nil, assets: %{}})

      assert info["icon"] == false
      assert info["logo"] == false
      assert info["changelog"] == false
      assert info["documentation"] == false
    end

    test "settings without an :assets key at all behave the same", %{config: c} do
      info = Info.render(c, :started, %{})

      assert info["icon"] == false
      assert info["documentation"] == false
    end

    test "stage/advanced/url come from the installed config", %{config: c} do
      # The install-time config is the source — an installed add-on's badge
      # must not silently follow the store's newer entry.
      assert Info.render(c, :started, %{})["stage"] == "stable"

      {:ok, beta} =
        Config.parse(%{
          "name" => "ESPHome (beta)",
          "version" => "1",
          "slug" => "esphome_beta",
          "description" => "d",
          "arch" => ["aarch64"],
          "stage" => "experimental",
          "advanced" => true,
          "url" => "https://beta.esphome.io/"
        })

      info = Info.render(beta, :started, %{})
      assert info["stage"] == "experimental"
      assert info["advanced"] == true
      assert info["url"] == "https://beta.esphome.io/"
    end
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

  describe "boot + auto_update (phase 6 chunk A, audit E1/E2)" do
    test "boot reflects the persisted override, not just the config default", %{config: c} do
      assert Info.render(c, :started, %{})["boot"] == "auto"
      assert Info.render(c, :started, %{}, %{boot: "manual"})["boot"] == "manual"
      assert Info.render(c, :started, %{}, %{boot: "auto"})["boot"] == "auto"
    end

    test "a manual_only config always reports boot: manual, override or not" do
      {:ok, c} =
        Config.parse(%{
          "name" => "Locked Boot",
          "version" => "1",
          "slug" => "locked_boot",
          "description" => "d",
          "arch" => ["amd64"],
          "boot" => "manual_only"
        })

      assert Info.render(c, :started, %{})["boot"] == "manual"
      assert Info.render(c, :started, %{}, %{boot: "auto"})["boot"] == "manual"
    end

    test "boot_config always reports the config's raw 3-way value", %{config: c} do
      assert Info.render(c, :started, %{})["boot_config"] == "auto"

      {:ok, manual_only} =
        Config.parse(%{
          "name" => "Locked Boot",
          "version" => "1",
          "slug" => "locked_boot",
          "description" => "d",
          "arch" => ["amd64"],
          "boot" => "manual_only"
        })

      assert Info.render(manual_only, :started, %{})["boot_config"] == "manual_only"
    end

    test "auto_update reflects the persisted setting; unset renders false, never fakes an updater",
         %{config: c} do
      assert Info.render(c, :started, %{})["auto_update"] == false
      assert Info.render(c, :started, %{}, %{auto_update: true})["auto_update"] == true
      assert Info.render(c, :started, %{}, %{auto_update: false})["auto_update"] == false
    end
  end

  describe "availability (phase 6 chunk A, audit G1)" do
    test "available/machine/homeassistant read off the config, not hardcoded", %{config: c} do
      # Fixture config declares arch ["aarch64", "amd64"]; StaticData.arch/0
      # is "aarch64" in :test, so this is available with no restrictions.
      info = Info.render(c, :started, %{})
      assert info["available"] == true
      assert info["machine"] == []
      assert info["homeassistant"] == nil
    end

    test "an arch this device doesn't have renders available: false" do
      {:ok, c} =
        Config.parse(%{
          "name" => "x86 Only",
          "version" => "1",
          "slug" => "x86only",
          "description" => "d",
          "arch" => ["amd64"]
        })

      assert Info.render(c, :started, %{})["available"] == false
    end

    test "machine renders the config's real declared list, negated entries included" do
      {:ok, c} =
        Config.parse(%{
          "name" => "Test",
          "version" => "1",
          "slug" => "test",
          "description" => "d",
          "arch" => ["amd64"],
          "machine" => ["raspberrypi3-64", "!qemux86"]
        })

      assert Info.render(c, :started, %{})["machine"] == ["raspberrypi3-64", "!qemux86"]
    end

    test "homeassistant renders the config's declared floor verbatim" do
      {:ok, c} =
        Config.parse(%{
          "name" => "Test",
          "version" => "1",
          "slug" => "test",
          "description" => "d",
          "arch" => ["amd64"],
          "homeassistant" => "2026.7.0"
        })

      assert Info.render(c, :started, %{})["homeassistant"] == "2026.7.0"
    end
  end
end
