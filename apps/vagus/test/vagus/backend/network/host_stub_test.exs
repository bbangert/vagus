defmodule Vagus.Backend.Network.HostStubTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.API.Models.NetworkInfo
  alias Vagus.Backend.Network.HostStub

  describe "info/0" do
    test "passes Vagus.API.Models.NetworkInfo.build!/1 in strict mode" do
      attrs = HostStub.info()
      assert NetworkInfo.build!(attrs) == attrs
    end

    test ~S(the single interface is "eth-host", not "eth0") do
      assert [%{interface: "eth-host"}] = HostStub.info().interfaces
    end
  end

  describe "interface_info/1" do
    test "\"eth-host\" resolves ok" do
      assert {:ok, %{interface: "eth-host"}} = HostStub.interface_info("eth-host")
    end

    test ~S["default" (case-insensitive) resolves to "eth-host", the only/primary interface] do
      assert {:ok, %{interface: "eth-host"}} = HostStub.interface_info("default")
      assert {:ok, %{interface: "eth-host"}} = HostStub.interface_info("DEFAULT")
      assert {:ok, %{interface: "eth-host"}} = HostStub.interface_info("Default")
    end

    test "any other name is an honest :not_found" do
      assert HostStub.interface_info("wlan0") == {:error, :not_found}
    end
  end

  describe "access_points/1" do
    test "the non-wireless eth-host interface is an honest error" do
      assert {:error, message} = HostStub.access_points("eth-host")
      assert message =~ "not a wireless interface"
    end

    test ~S("default" resolves before the wireless check) do
      assert {:error, message} = HostStub.access_points("default")
      assert message =~ "not a wireless interface"
    end

    test "unknown interface is an honest :not_found (resolution before the wireless check)" do
      assert HostStub.access_points("wlan0") == {:error, :not_found}
      assert HostStub.access_points("bogus0") == {:error, :not_found}
    end
  end

  describe "configure/2" do
    test "accepts the full frontend-shaped body (ipv6 + enabled no longer rejected)" do
      body = %{
        "ipv4" => %{"method" => "auto", "nameservers" => []},
        "ipv6" => %{"method" => "auto", "nameservers" => []},
        "enabled" => true
      }

      assert HostStub.configure("eth-host", body) == :ok
    end

    test ~S("default" resolves to "eth-host") do
      assert HostStub.configure("default", %{"enabled" => true}) == :ok
    end

    test "unknown interface -> :not_found" do
      assert HostStub.configure("bogus0", %{"enabled" => true}) == {:error, :not_found}
    end

    test "unknown interface with an empty body -> :not_found, not the empty-body 400 (resolution wins)" do
      assert HostStub.configure("bogus0", %{}) == {:error, :not_found}
    end

    test "empty body -> the upstream error message" do
      assert HostStub.configure("eth-host", %{}) ==
               {:error, "You need to supply at least one option to update"}
    end

    test "an invalid body -> a validation error, not a crash" do
      assert {:error, _message} =
               HostStub.configure("eth-host", %{"ipv4" => %{"method" => "dhcp"}})
    end

    test "a wifi fragment on eth-host is rejected before it's ever logged (eth-host isn't wireless)" do
      body = %{"wifi" => %{"ssid" => "MyNet", "auth" => "wpa-psk", "psk" => "supersecret"}}

      log =
        capture_log(fn ->
          assert HostStub.configure("eth-host", body) ==
                   {:error, "eth-host is not a wireless interface"}
        end)

      refute log =~ "supersecret"
    end
  end
end
