defmodule Vagus.Backend.OS.HostStubTest do
  use ExUnit.Case, async: true

  alias Vagus.API.Models.OSInfo
  alias Vagus.Backend.OS.HostStub

  describe "info/0" do
    test "passes Vagus.API.Models.OSInfo.build!/1 in strict mode" do
      attrs = HostStub.info()
      assert OSInfo.build!(attrs) == attrs
    end

    test "version/board come from the InMemory KV, boot is the active slot" do
      attrs = HostStub.info()

      assert attrs.version == "0.0.0"
      assert attrs.version_latest == "0.0.0"
      assert attrs.board == "host"
      assert attrs.boot == "A"
      assert attrs.update_available == false
      # No real /data device to report on a dev host.
      assert attrs.data_disk == nil
    end

    test "boot_slots has both A and B, each a conformant BootSlot" do
      %{boot_slots: slots} = HostStub.info()

      assert Map.keys(slots) |> Enum.sort() == ["A", "B"]
      assert slots["A"].state == "active"
      assert slots["B"].state == "inactive"
    end
  end

  describe "datadisk_list/0" do
    test "is an honest empty list" do
      assert HostStub.datadisk_list() == []
    end
  end
end
