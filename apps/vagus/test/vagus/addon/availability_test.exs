defmodule Vagus.Addon.AvailabilityTest do
  @moduledoc """
  G1 (audit B2) — arch/machine/Home Assistant-version gating, driven at the
  pure `check/4` level (device facts supplied explicitly) so this suite
  doesn't depend on `Vagus.API.StaticData`'s configured `:test` values or on
  `Vagus.Core.Versions`'s live state. `check/1`/`available?/1` (the
  zero-arg variants `Info`/`StoreView`/the router actually call) are
  covered indirectly by `info_test.exs` and the router install-refusal
  test, which run against the real device facts.
  """
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Availability, Config}

  defp config(overrides \\ %{}) do
    base = %{
      "name" => "Test Addon",
      "version" => "1",
      "slug" => "test",
      "description" => "d",
      "arch" => ["aarch64", "amd64"]
    }

    {:ok, c} = Config.parse(Map.merge(base, overrides))
    c
  end

  describe "architecture" do
    test "the device's arch is in config.arch -> available" do
      c = config(%{"arch" => ["aarch64"]})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
    end

    test "the device's arch is NOT in config.arch -> unavailable, reason names both" do
      c = config(%{"arch" => ["amd64"]})
      assert {false, reason} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
      assert reason =~ "not supported on this platform"
      assert reason =~ "amd64"
    end
  end

  describe "machine (a positive whitelist — see the module's moduledoc on '!' semantics)" do
    test "no machine: restriction -> available on every device" do
      c = config()
      assert {true, nil} = Availability.check(c, "aarch64", "qemux86", nil)
    end

    test "the device's machine is positively listed -> available" do
      c = config(%{"machine" => ["raspberrypi3-64", "qemux86"]})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
    end

    test "the device's machine is absent from the whitelist -> unavailable" do
      c = config(%{"machine" => ["qemux86"]})
      assert {false, reason} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
      assert reason =~ "not supported on this machine"
      assert reason =~ "qemux86"
    end

    test "the device's machine is explicitly negated -> unavailable even if also listed positively" do
      c = config(%{"machine" => ["raspberrypi3-64", "!raspberrypi3-64"]})
      assert {false, _reason} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
    end

    test "an ONLY-negated list matches upstream's real (non-obvious) behavior: unavailable everywhere" do
      # Verified directly against home-assistant/supervisor @ 2026.07.5
      # `apps/model.py`'s `has_supported_machine` — NOT the "exclude this
      # machine, allow everything else" reading a casual description of
      # `!` suggests. See `Vagus.Addon.Availability`'s moduledoc.
      c = config(%{"machine" => ["!qemux86"]})
      refute match?({true, nil}, Availability.check(c, "aarch64", "raspberrypi3-64", nil))
      refute match?({true, nil}, Availability.check(c, "aarch64", "qemux86", nil))
    end

    test "negation alongside a matching positive entry for a DIFFERENT machine is available" do
      c = config(%{"machine" => ["raspberrypi3-64", "!qemux86"]})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
      assert {false, _reason} = Availability.check(c, "aarch64", "qemux86", nil)
    end
  end

  describe "Home Assistant version floor" do
    test "no floor declared -> available regardless of installed version" do
      c = config()
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", "2020.1.0")
    end

    test "installed >= floor -> available" do
      c = config(%{"homeassistant" => "2026.7.0"})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", "2026.7.0")
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", "2026.7.2")
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", "2027.1.0")
    end

    test "installed < floor -> unavailable, reason names the floor" do
      c = config(%{"homeassistant" => "2026.7.0"})
      assert {false, reason} = Availability.check(c, "aarch64", "raspberrypi3-64", "2026.6.9")
      assert reason =~ "Home Assistant"
      assert reason =~ "2026.7.0"
    end

    test "a shorter installed version compares as zero-padded (2026.7 == 2026.7.0)" do
      c = config(%{"homeassistant" => "2026.7.0"})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", "2026.7")
    end

    test "unknown installed version (nil, Core not yet adopted) -> floor satisfied" do
      c = config(%{"homeassistant" => "2026.7.0"})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", nil)
    end

    test "an unparseable installed or floor version -> indeterminate, treated as satisfied" do
      c = config(%{"homeassistant" => "2026.7.0"})
      assert {true, nil} = Availability.check(c, "aarch64", "raspberrypi3-64", "2026.7.0-beta1")

      beta_floor = config(%{"homeassistant" => "unstable"})

      assert {true, nil} =
               Availability.check(beta_floor, "aarch64", "raspberrypi3-64", "2020.1.0")
    end
  end

  describe "check order (arch, then machine, then Home Assistant version)" do
    test "an arch mismatch is reported even when machine/homeassistant would also fail" do
      c =
        config(%{
          "arch" => ["amd64"],
          "machine" => ["qemux86"],
          "homeassistant" => "9999.1.0"
        })

      assert {false, reason} = Availability.check(c, "aarch64", "raspberrypi3-64", "1.0.0")
      assert reason =~ "not supported on this platform"
    end

    test "a machine mismatch is reported once arch is satisfied" do
      c = config(%{"machine" => ["qemux86"], "homeassistant" => "9999.1.0"})
      assert {false, reason} = Availability.check(c, "aarch64", "raspberrypi3-64", "1.0.0")
      assert reason =~ "not supported on this machine"
    end
  end

  describe "available?/1" do
    test "true/false mirror check/4's verdict" do
      available = config()
      unavailable = config(%{"arch" => ["amd64"]})

      assert Availability.available?(available)
      refute Availability.available?(unavailable)
    end
  end
end
