defmodule Vagus.Backend.Network.HostStubTest do
  use ExUnit.Case, async: true

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

    test "any other name is an honest not-found error" do
      assert {:error, message} = HostStub.interface_info("wlan0")
      assert message =~ "not found"
    end
  end

  describe "access_points/1" do
    test "a wireless-looking name gets an empty, valid (honest) shape" do
      assert {:ok, []} = HostStub.access_points("wlan0")
    end

    test "the non-wireless eth-host interface is an honest error" do
      assert {:error, message} = HostStub.access_points("eth-host")
      assert message =~ "not a wireless interface"
    end
  end

  describe "configure/2" do
    test "accepts whitelisted fields and no-ops" do
      assert HostStub.configure("eth-host", %{"ipv4" => %{"method" => "dhcp"}}) == :ok
    end

    test "rejects unsupported fields with a message listing them" do
      assert {:error, message} = HostStub.configure("eth-host", %{"ipv6" => %{}, "vlan" => 1})
      assert message =~ "ipv6"
      assert message =~ "vlan"
    end
  end
end
