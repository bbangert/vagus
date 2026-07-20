defmodule Vagus.Backend.Network.BuilderTest do
  use ExUnit.Case, async: true

  alias Vagus.API.Models.NetworkInterface
  alias Vagus.Backend.Network.Builder

  # Fixtures resembling real `vintage_net` property reads — not literal
  # `VintageNet.get_by_prefix/1` tuples (this project flattens those into a
  # per-interface map before calling `Builder`, see
  # `Vagus.Backend.Network.VintageNet`), but the same field names/shapes
  # `vintage_net` itself uses for `addresses`/`config`.
  @eth0_connected %{
    connection: :internet,
    mac_address: "b8:27:eb:00:00:01",
    addresses: [
      %{address: {192, 168, 1, 50}, prefix_length: 24, family: :inet},
      %{address: {0xFE80, 0, 0, 0, 2, 0, 0, 1}, prefix_length: 64, family: :inet6}
    ],
    config: %{ipv4: %{method: :dhcp}},
    nameservers: ["1.1.1.1", "8.8.8.8"],
    wifi_signal: nil
  }

  @eth0_disconnected %{
    connection: :disconnected,
    mac_address: "b8:27:eb:00:00:01",
    addresses: [],
    config: %{ipv4: %{method: :dhcp}},
    nameservers: [],
    wifi_signal: nil
  }

  @wlan0_connected %{
    connection: :lan,
    mac_address: "b8:27:eb:00:00:02",
    addresses: [%{address: {192, 168, 1, 60}, prefix_length: 24, family: :inet}],
    config: %{
      ipv4: %{method: :dhcp},
      vintage_net_wifi: %{networks: [%{ssid: "MyWifi", psk: "secret", key_mgmt: :wpa_psk}]}
    },
    nameservers: ["192.168.1.1"],
    wifi_signal: -55
  }

  describe "build_interface/3 — ethernet, connected + primary" do
    test "produces a NetworkInterface-conformant attrs map" do
      attrs = Builder.build_interface("eth0", @eth0_connected, :internet)

      assert NetworkInterface.build!(attrs) == attrs
      assert attrs.interface == "eth0"
      assert attrs.type == "ethernet"
      assert attrs.connected == true
      assert attrs.primary == true
      assert attrs.mac == "b8:27:eb:00:00:01"
      assert attrs.wifi == nil
      assert attrs.vlan == nil
    end

    test "ipv4 reflects the configured method, addresses, and nameservers" do
      attrs = Builder.build_interface("eth0", @eth0_connected, :internet)

      assert attrs.ipv4 == %{
               method: "auto",
               ready: true,
               address: ["192.168.1.50/24"],
               nameservers: ["1.1.1.1", "8.8.8.8"],
               gateway: nil,
               route_metric: nil
             }
    end

    test "ipv6 is built from the :inet6 address when present" do
      attrs = Builder.build_interface("eth0", @eth0_connected, :internet)

      assert %{
               method: "auto",
               ready: true,
               address: [address],
               addr_gen_mode: "eui64",
               ip6_privacy: "default"
             } = attrs.ipv6

      assert address == "fe80::2:0:0:1/64"
    end
  end

  describe "build_interface/3 — disconnected, not primary" do
    test "connected/primary are both false, ipv6 nil (no :inet6 address)" do
      attrs = Builder.build_interface("eth0", @eth0_disconnected, :internet)

      assert attrs.connected == false
      assert attrs.primary == false
      assert attrs.ipv6 == nil
      assert attrs.ipv4.ready == false
    end
  end

  describe "build_interface/3 — wireless" do
    test "type is wireless and wifi attrs are populated from config + wifi_signal" do
      attrs = Builder.build_interface("wlan0", @wlan0_connected, :lan)

      assert NetworkInterface.build!(attrs) == attrs
      assert attrs.type == "wireless"
      assert attrs.connected == true
      # aggregate best_connection is :lan, matching this interface's own
      # :lan connection - so it's primary even though not :internet.
      assert attrs.primary == true

      assert attrs.wifi == %{
               mode: "infrastructure",
               auth: "wpa-psk",
               ssid: "MyWifi",
               signal: -55
             }
    end

    test "wifi is nil for a wlan interface with no configured network" do
      props = %{@wlan0_connected | config: %{ipv4: %{method: :dhcp}}}
      attrs = Builder.build_interface("wlan0", props, :lan)

      assert attrs.wifi == nil
    end
  end

  describe "build_ipv4/1" do
    test "returns nil when explicitly configured method: :disabled" do
      props = %{@eth0_connected | config: %{ipv4: %{method: :disabled}}}
      assert Builder.build_ipv4(props) == nil
    end

    test "defaults method to the wire's auto when no ipv4 config is present at all" do
      props = %{@eth0_connected | config: %{}}
      assert Builder.build_ipv4(props).method == "auto"
    end

    test "ipv4 nameservers keep only IPv4 address strings" do
      props = %{@eth0_connected | nameservers: ["1.1.1.1", "fd00::1", "8.8.8.8"]}
      assert Builder.build_ipv4(props).nameservers == ["1.1.1.1", "8.8.8.8"]
    end

    test "normalizes the real on-device name_servers shape (verified 2026-07-20)" do
      props = %{@eth0_connected | nameservers: [%{address: {192, 168, 2, 1}, from: ["eth0"]}]}
      assert Builder.build_ipv4(props).nameservers == ["192.168.2.1"]
    end

    test "normalizes a mix of map/tuple/string/ipv6/garbage entries, dropping non-ipv4" do
      props = %{
        @eth0_connected
        | nameservers: [
            %{address: {192, 168, 2, 1}, from: ["eth0"]},
            {8, 8, 8, 8},
            "1.1.1.1",
            "fd00::1",
            :garbage
          ]
      }

      assert Builder.build_ipv4(props).nameservers == ["192.168.2.1", "8.8.8.8", "1.1.1.1"]
    end
  end

  describe "interface_type/1" do
    test "wlan-prefixed names are wireless, everything else is ethernet" do
      assert Builder.interface_type("wlan0") == "wireless"
      assert Builder.interface_type("eth0") == "ethernet"
      assert Builder.interface_type("usb0") == "ethernet"
    end
  end
end
