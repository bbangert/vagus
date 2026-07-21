defmodule Vagus.Addon.ConfigTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Config

  @required %{
    "name" => "Test",
    "version" => "1.0.0",
    "slug" => "test_addon",
    "description" => "an add-on",
    "arch" => ["aarch64", "amd64"]
  }

  describe "required fields + defaults" do
    test "minimal config parses with documented defaults" do
      assert {:ok, c} = Config.parse(@required)
      assert c.slug == "test_addon"
      assert c.arch == ["aarch64", "amd64"]
      # defaults
      assert c.startup == "application"
      assert c.boot == "auto"
      assert c.init == true
      assert c.hassio_role == "default"
      assert c.ingress_port == 8099
      assert c.apparmor == true
      assert c.backup == "hot"
      assert c.timeout == 10
      assert c.image == nil
      assert c.ports == %{}
      assert c.map == []
      assert c.schema == %{}
      assert c.services == []
    end

    for field <- ~w(name version slug description arch) do
      test "missing required '#{field}' is an error" do
        assert {:error, msg} = Config.parse(Map.delete(@required, unquote(field)))
        assert msg =~ unquote(field)
      end
    end

    test "non-map input is an error, never a raise" do
      assert {:error, _} = Config.parse("not a map")
    end
  end

  describe "validation" do
    test "invalid slug characters rejected" do
      assert {:error, msg} = Config.parse(%{@required | "slug" => "bad slug!"})
      assert msg =~ "slug"
    end

    test "unknown arch rejected" do
      assert {:error, msg} = Config.parse(%{@required | "arch" => ["sparc"]})
      assert msg =~ "arch"
    end

    test "bad service format rejected" do
      assert {:error, msg} = Config.parse(Map.put(@required, "services", ["mqtt:sometimes"]))
      assert msg =~ "service"
    end

    test "bad enum (startup) rejected" do
      assert {:error, msg} = Config.parse(Map.put(@required, "startup", "whenever"))
      assert msg =~ "startup"
    end

    test "wrong-typed field rejected (init not bool)" do
      assert {:error, msg} = Config.parse(Map.put(@required, "init", "yes"))
      assert msg =~ "init"
    end
  end

  describe "map: normalization (string + dict forms)" do
    test "bare type string → read_only true" do
      assert {:ok, c} = Config.parse(Map.put(@required, "map", ["ssl"]))
      assert c.map == [%{type: "ssl", read_only: true, path: nil}]
    end

    test "type:rw / type:ro migrate access" do
      assert {:ok, c} = Config.parse(Map.put(@required, "map", ["share:rw", "ssl:ro"]))

      assert c.map == [
               %{type: "share", read_only: false, path: nil},
               %{type: "ssl", read_only: true, path: nil}
             ]
    end

    test "dict form with explicit read_only + path" do
      entry = %{"type" => "addon_config", "read_only" => false, "path" => "/cfg"}
      assert {:ok, c} = Config.parse(Map.put(@required, "map", [entry]))
      assert c.map == [%{type: "addon_config", read_only: false, path: "/cfg"}]
    end

    test "bad access suffix rejected" do
      assert {:error, msg} = Config.parse(Map.put(@required, "map", ["ssl:maybe"]))
      assert msg =~ "rw"
    end
  end

  describe "ports + schema" do
    test "ports normalize keys to strings; null host is kept" do
      raw = Map.put(@required, "ports", %{"1883/tcp" => 1883, "1884/tcp" => nil})
      assert {:ok, c} = Config.parse(raw)
      assert c.ports == %{"1883/tcp" => 1883, "1884/tcp" => nil}
    end

    test "schema: false passes through" do
      assert {:ok, c} = Config.parse(Map.put(@required, "schema", false))
      assert c.schema == false
    end
  end

  describe "Mosquitto config.yaml (v7.1.0) shape" do
    @mosquitto %{
      "name" => "Mosquitto broker",
      "version" => "7.1.0",
      "slug" => "core_mosquitto",
      "description" => "An Open Source MQTT broker",
      "arch" => ["aarch64", "amd64", "armhf", "armv7", "i386"],
      "image" => "homeassistant/{arch}-addon-mosquitto",
      "startup" => "system",
      "boot" => "auto",
      "init" => false,
      "ports" => %{"1883/tcp" => 1883, "1884/tcp" => 1884, "8883/tcp" => 8883, "8884/tcp" => 8884},
      "map" => ["ssl", "share"],
      "auth_api" => true,
      "services" => ["mqtt:provide"],
      "discovery" => ["mqtt"],
      "watchdog" => "tcp://[HOST]:1883",
      "schema" => %{"require_certificate" => "bool", "certfile" => "str"},
      "options" => %{"require_certificate" => false, "certfile" => "fullchain.pem"}
    }

    test "parses to the fields the Spec builder needs" do
      assert {:ok, c} = Config.parse(@mosquitto)
      assert c.slug == "core_mosquitto"
      assert c.image == "homeassistant/{arch}-addon-mosquitto"
      assert c.init == false
      assert c.startup == "system"
      assert c.auth_api == true
      assert c.services == ["mqtt:provide"]
      assert c.discovery == ["mqtt"]
      assert c.ports["8883/tcp"] == 8883

      assert c.map == [
               %{type: "ssl", read_only: true, path: nil},
               %{type: "share", read_only: true, path: nil}
             ]

      assert c.watchdog == "tcp://[HOST]:1883"
      assert c.schema["require_certificate"] == "bool"
      assert c.options["certfile"] == "fullchain.pem"
      refute c.host_network
    end
  end
end
