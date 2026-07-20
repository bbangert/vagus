defmodule Vagus.Backend.Host.HostStubTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.API.Models.HostInfo
  alias Vagus.Backend.Host.HostStub

  describe "info/0" do
    test "passes Vagus.API.Models.HostInfo.build!/1 in strict mode" do
      attrs = HostStub.info()
      assert HostInfo.build!(attrs) == attrs
    end

    test "hostname is the real dev machine hostname" do
      {:ok, expected} = :inet.gethostname()
      assert HostStub.info().hostname == List.to_string(expected)
    end

    test "features lists reboot/shutdown/network" do
      assert HostStub.info().features == ["reboot", "shutdown", "network"]
    end

    test "disk_free/total/used are real (non-negative) floats, never nil" do
      attrs = HostStub.info()

      assert is_float(attrs.disk_free)
      assert is_float(attrs.disk_total)
      assert is_float(attrs.disk_used)
    end

    test "fields this emulator doesn't track are honest nil" do
      attrs = HostStub.info()

      assert attrs.agent_version == nil
      assert attrs.kernel == nil
      assert attrs.operating_system == nil
      assert attrs.boot_timestamp == nil
      assert attrs.startup_time == nil
    end
  end

  describe "reboot/0 and shutdown/0" do
    test "reboot/0 logs a warning and returns :ok, never touching the dev machine" do
      assert capture_log(fn -> assert HostStub.reboot() == :ok end) =~ "reboot requested"
    end

    test "shutdown/0 logs a warning and returns :ok" do
      assert capture_log(fn -> assert HostStub.shutdown() == :ok end) =~ "shutdown requested"
    end
  end
end
