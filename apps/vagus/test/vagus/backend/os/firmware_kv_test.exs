defmodule Vagus.Backend.OS.FirmwareKVTest do
  use ExUnit.Case, async: true

  alias Vagus.Backend.OS.FirmwareKV

  # config/host.exs pre-populates the InMemory Nerves.Runtime.KV backend
  # with exactly these keys (slot "a" only — no "b.*" keys) — this test
  # pins that fixture rather than re-deriving it.
  describe "against the InMemory KV pre-populated in config/host.exs" do
    test "active_slot/0 is \"a\"" do
      assert FirmwareKV.active_slot() == "a"
    end

    test "version/1 and platform/1 read the active slot's keys" do
      assert FirmwareKV.version("a") == "0.0.0"
      assert FirmwareKV.platform("a") == "host"
    end

    test "version/1 and platform/1 are honest nil for the unpopulated slot" do
      assert FirmwareKV.version("b") == nil
      assert FirmwareKV.platform("b") == nil
    end

    test "boot_slots/0 returns both A and B, each a valid BootSlot" do
      slots = FirmwareKV.boot_slots()

      assert Map.keys(slots) |> Enum.sort() == ["A", "B"]
      assert slots["A"] == %{state: "active", status: "good", version: "0.0.0"}
      assert slots["B"] == %{state: "inactive", status: nil, version: nil}
    end
  end
end
