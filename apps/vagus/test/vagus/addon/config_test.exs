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
      assert c.ingress_entry == nil
      assert c.ingress_stream == false
      assert c.panel_icon == "mdi:puzzle"
      assert c.panel_title == nil
      assert c.panel_admin == true
      assert c.apparmor == true
      assert c.backup == "hot"
      assert c.timeout == 10
      assert c.image == nil
      assert c.ports == %{}
      assert c.map == []
      assert c.schema == %{}
      assert c.services == []
      assert c.homeassistant == nil
      assert c.machine == []
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

    test "invalid version characters rejected (W1 — docker tag charset)" do
      for bad <- ["1.0/../etc", "1.0 beta", "1.0?x", "1.0#frag", "../1.0"] do
        assert {:error, msg} = Config.parse(%{@required | "version" => bad})
        assert msg =~ "version"
      end
    end

    test "legitimate version shapes accepted" do
      for good <- ["1.0.0", "7.1.0", "2026.7.2", "1.0.0-beta.1", "v1-2"] do
        assert {:ok, c} = Config.parse(%{@required | "version" => good})
        assert c.version == good
      end
    end
  end

  describe "ingress + panel config (§B3.1)" do
    test "new fields parse with their documented defaults" do
      assert {:ok, c} = Config.parse(@required)
      assert c.ingress == false
      assert c.ingress_port == 8099
      assert c.ingress_entry == nil
      assert c.ingress_stream == false
      assert c.panel_icon == "mdi:puzzle"
      assert c.panel_title == nil
      assert c.panel_admin == true
    end

    test "new fields parse when set explicitly" do
      raw =
        Map.merge(@required, %{
          "ingress" => true,
          "ingress_port" => 8123,
          "ingress_entry" => "dashboard",
          "ingress_stream" => true,
          "panel_icon" => "mdi:chip",
          "panel_title" => "My Panel",
          "panel_admin" => false
        })

      assert {:ok, c} = Config.parse(raw)
      assert c.ingress == true
      assert c.ingress_port == 8123
      assert c.ingress_entry == "dashboard"
      assert c.ingress_stream == true
      assert c.panel_icon == "mdi:chip"
      assert c.panel_title == "My Panel"
      assert c.panel_admin == false
    end

    test "ingress_port accepts exactly 0 (dynamic assignment)" do
      assert {:ok, c} = Config.parse(Map.put(@required, "ingress_port", 0))
      assert c.ingress_port == 0
    end

    test "ingress_port accepts the upper bound 65535" do
      assert {:ok, c} = Config.parse(Map.put(@required, "ingress_port", 65_535))
      assert c.ingress_port == 65_535
    end

    test "ingress_port rejects negative values" do
      assert {:error, msg} = Config.parse(Map.put(@required, "ingress_port", -1))
      assert msg =~ "ingress_port"
    end

    test "ingress_port rejects values above 65535" do
      assert {:error, msg} = Config.parse(Map.put(@required, "ingress_port", 70_000))
      assert msg =~ "ingress_port"
    end

    test "panel_icon rejects a non-string value" do
      assert {:error, msg} = Config.parse(Map.put(@required, "panel_icon", 123))
      assert msg =~ "panel_icon"
    end

    # §B3.2 last paragraph: ingress_port: 0 + a ports: host value in the
    # dynamic ingress range (62000-65500) would let a client bypass the
    # ingress session-cookie check by hitting the add-on directly.
    test "ingress_port: 0 + a ports: host value in 62000-65500 is a parse error" do
      raw =
        Map.merge(@required, %{
          "ingress_port" => 0,
          "ports" => %{"8099/tcp" => 62_500}
        })

      assert {:error, msg} = Config.parse(raw)
      assert msg =~ "ingress_port"
    end

    test "ingress_port: 0 + a ports: host value outside the dynamic range parses fine" do
      raw =
        Map.merge(@required, %{
          "ingress_port" => 0,
          "ports" => %{"8099/tcp" => 8123}
        })

      assert {:ok, c} = Config.parse(raw)
      assert c.ingress_port == 0
    end

    test "a non-zero ingress_port alongside a ports: value in the dynamic range is fine" do
      raw =
        Map.merge(@required, %{
          "ingress_port" => 8099,
          "ports" => %{"8099/tcp" => 62_500}
        })

      assert {:ok, c} = Config.parse(raw)
      assert c.ingress_port == 8099
    end

    test "round-trips through to_persistable/1 with every new field set" do
      raw =
        Map.merge(@required, %{
          "ingress" => true,
          "ingress_port" => 0,
          "ingress_entry" => "dashboard",
          "ingress_stream" => true,
          "panel_icon" => "mdi:chip",
          "panel_title" => "My Panel",
          "panel_admin" => false
        })

      assert {:ok, c} = Config.parse(raw)
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end
  end

  describe "homeassistant + machine (phase 6 chunk A, audit G1)" do
    test "homeassistant is nil by default and parses as an opaque version string" do
      assert {:ok, c} = Config.parse(@required)
      assert c.homeassistant == nil

      assert {:ok, c} = Config.parse(Map.put(@required, "homeassistant", "2026.7.0"))
      assert c.homeassistant == "2026.7.0"
    end

    test "a non-string homeassistant is rejected" do
      assert {:error, msg} = Config.parse(Map.put(@required, "homeassistant", 2026))
      assert msg =~ "homeassistant"
    end

    test "machine defaults to [] and parses as a plain string list, negated entries included" do
      assert {:ok, c} = Config.parse(@required)
      assert c.machine == []

      raw = Map.put(@required, "machine", ["raspberrypi3-64", "!qemux86"])
      assert {:ok, c} = Config.parse(raw)
      assert c.machine == ["raspberrypi3-64", "!qemux86"]
    end

    test "a non-list machine is rejected" do
      assert {:error, msg} = Config.parse(Map.put(@required, "machine", "raspberrypi3-64"))
      assert msg =~ "machine"
    end

    test "round-trips through to_persistable/1 with homeassistant + machine set" do
      raw =
        Map.merge(@required, %{
          "homeassistant" => "2026.7.0",
          "machine" => ["raspberrypi3-64", "!qemux86"]
        })

      assert {:ok, c} = Config.parse(raw)
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end
  end

  describe "effective_boot/2 (audit E1)" do
    defp boot_config(boot) do
      {:ok, c} = Config.parse(Map.put(@required, "boot", boot))
      c
    end

    test "no persisted override falls back to the config's own boot" do
      assert Config.effective_boot(boot_config("auto"), nil) == "auto"
      assert Config.effective_boot(boot_config("manual"), nil) == "manual"
    end

    test "a persisted auto/manual override wins over the config default" do
      assert Config.effective_boot(boot_config("auto"), "manual") == "manual"
      assert Config.effective_boot(boot_config("manual"), "auto") == "auto"
    end

    test "manual_only always wins, override or not" do
      assert Config.effective_boot(boot_config("manual_only"), nil) == "manual"
      assert Config.effective_boot(boot_config("manual_only"), "auto") == "manual"
      assert Config.effective_boot(boot_config("manual_only"), "manual") == "manual"
    end
  end

  describe "valid_slug?/1 (W3 — the shared rm_rf/restore guard)" do
    test "accepts everything parse/1's own slug charset accepts" do
      assert Config.valid_slug?("core_mosquitto")
      assert Config.valid_slug?("Core.Mosquitto")
      assert Config.valid_slug?("a-b_c.d")
    end

    test "rejects the degenerate . and .. tokens even though the charset allows them" do
      refute Config.valid_slug?(".")
      refute Config.valid_slug?("..")
    end

    test "rejects anything containing a slash" do
      refute Config.valid_slug?("../evil")
      refute Config.valid_slug?("a/b")
    end

    test "rejects non-binary input" do
      refute Config.valid_slug?(nil)
      refute Config.valid_slug?(123)
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

    test "round-trips through to_persistable/1 (M4-P8-T1 persistence)" do
      assert {:ok, c} = Config.parse(@mosquitto)
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end
  end

  describe "to_persistable/1 round-trip (M4-P8-T1 — parse/1 stays the single validator)" do
    test "a maximal fixture exercising every field round-trips" do
      raw = %{
        "name" => "Maximal",
        "version" => "1.2.3-beta.4",
        "slug" => "maximal_addon",
        "description" => "exercises every Config field",
        "arch" => ["aarch64", "amd64", "armhf", "armv7", "i386"],
        "startup" => "once",
        "boot" => "manual",
        "init" => false,
        "image" => "homeassistant/{arch}-addon-maximal",
        "ports" => %{"1234/tcp" => 1234, "5678/udp" => nil},
        "map" => [
          %{"type" => "share", "read_only" => false, "path" => "/share"},
          %{"type" => "ssl", "read_only" => true, "path" => nil},
          "addons:rw"
        ],
        "hassio_api" => true,
        "hassio_role" => "manager",
        "homeassistant_api" => true,
        "auth_api" => true,
        "docker_api" => true,
        "services" => ["mqtt:provide", "mysql:want"],
        "discovery" => ["mqtt", "mysql"],
        "host_network" => false,
        "host_dbus" => true,
        "host_pid" => true,
        "host_ipc" => true,
        "host_uts" => true,
        "privileged" => ["SYS_ADMIN", "NET_ADMIN"],
        "full_access" => true,
        "devices" => ["/dev/ttyUSB0"],
        "apparmor" => false,
        "ingress" => true,
        "ingress_port" => 8123,
        "ingress_entry" => "dashboard",
        "ingress_stream" => true,
        "panel_icon" => "mdi:chip",
        "panel_title" => "My Panel",
        "panel_admin" => false,
        "watchdog" => "tcp://[HOST]:1234",
        "webui" => "http://[HOST]:8123",
        "options" => %{"greeting" => "hi", "count" => 3, "nested" => %{"a" => [1, 2, 3]}},
        "schema" => %{"greeting" => "str", "count" => "int"},
        "backup" => "cold",
        "backup_pre" => "pre.sh",
        "backup_post" => "post.sh",
        "backup_exclude" => ["**/*.log"],
        "timeout" => 30,
        "homeassistant" => "2026.7.0",
        "machine" => ["raspberrypi3-64", "!qemux86"]
      }

      assert {:ok, c} = Config.parse(raw)
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end

    test "a config with nil optional fields (image/watchdog/webui/backup hooks) round-trips" do
      assert {:ok, c} = Config.parse(@required)
      assert c.image == nil
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end

    test "schema: false round-trips" do
      assert {:ok, c} = Config.parse(Map.put(@required, "schema", false))
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end

    test "backend defaults to :container and round-trips (M5)" do
      assert {:ok, c} = Config.parse(@required)
      assert c.backend == :container
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end

    test "backend: native parses to :native and round-trips (M5)" do
      assert {:ok, c} = Config.parse(Map.put(@required, "backend", "native"))
      assert c.backend == :native
      assert Config.parse(Config.to_persistable(c)) == {:ok, c}
    end

    test "an unknown backend value is rejected (strict, like other enum fields)" do
      assert {:error, msg} = Config.parse(Map.put(@required, "backend", "wasm"))
      assert msg =~ "backend"
    end
  end
end
