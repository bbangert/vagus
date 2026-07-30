defmodule Vagus.Backend.Network.WireConfigTest do
  use ExUnit.Case, async: true

  alias Vagus.Backend.Network.WireConfig

  # -- the four verbatim frontend bodies (docstring in the plan, from
  # supervisor-network.ts::_updateNetwork, tag 20260624.6) -------------------

  describe "translate/1 with real frontend bodies" do
    test "plain ethernet save (auto/auto/enabled)" do
      body = %{
        "ipv4" => %{"method" => "auto", "nameservers" => []},
        "ipv6" => %{"method" => "auto", "nameservers" => []},
        "enabled" => true
      }

      assert {:ok, %{ipv4: %{method: :dhcp}, wifi: nil}} = WireConfig.translate(body)
    end

    test "static save" do
      body = %{
        "ipv4" => %{
          "method" => "static",
          "nameservers" => ["1.1.1.1"],
          "address" => ["192.168.2.5/24"],
          "gateway" => "192.168.2.1"
        },
        "ipv6" => %{"method" => "auto", "nameservers" => []},
        "enabled" => true
      }

      assert {:ok, %{ipv4: ipv4, wifi: nil}} = WireConfig.translate(body)

      assert ipv4 == %{
               method: :static,
               address: "192.168.2.5",
               prefix_length: 24,
               gateway: "192.168.2.1",
               name_servers: ["1.1.1.1"]
             }
    end

    test "open wifi join (no psk key at all)" do
      body = %{
        "ipv4" => %{"method" => "auto", "nameservers" => []},
        "ipv6" => %{"method" => "auto", "nameservers" => []},
        "enabled" => true,
        "wifi" => %{"ssid" => "MyNet", "mode" => "infrastructure", "auth" => "open"}
      }

      assert {:ok, %{ipv4: %{method: :dhcp}, wifi: wifi}} = WireConfig.translate(body)
      assert wifi == %{ssid: "MyNet", key_mgmt: :none}
      refute Map.has_key?(wifi, :psk)
    end

    test "wpa wifi join" do
      body = %{
        "ipv4" => %{"method" => "auto", "nameservers" => []},
        "ipv6" => %{"method" => "auto", "nameservers" => []},
        "enabled" => true,
        "wifi" => %{
          "ssid" => "MyNet",
          "mode" => "infrastructure",
          "auth" => "wpa-psk",
          "psk" => "secret123"
        }
      }

      assert {:ok, %{ipv4: %{method: :dhcp}, wifi: wifi}} = WireConfig.translate(body)
      assert wifi == %{ssid: "MyNet", psk: "secret123", key_mgmt: :wpa_psk}
    end
  end

  describe "translate/1 method/shape coverage" do
    test "ipv4 method disabled" do
      body = %{"ipv4" => %{"method" => "disabled"}}
      assert {:ok, %{ipv4: %{method: :disabled}, wifi: nil}} = WireConfig.translate(body)
    end

    test "ipv4 with nameservers absent entirely (both shapes accepted)" do
      body = %{"ipv4" => %{"method" => "auto"}}
      assert {:ok, %{ipv4: %{method: :dhcp}, wifi: nil}} = WireConfig.translate(body)
    end

    test "ipv4 method defaults to static when absent" do
      body = %{"ipv4" => %{"address" => ["10.0.0.5/24"]}}

      assert {:ok, %{ipv4: %{method: :static, address: "10.0.0.5", prefix_length: 24}}} =
               WireConfig.translate(body)
    end

    test "only ignored keys (enabled alone) is valid and yields nil/nil" do
      assert {:ok, %{ipv4: nil, wifi: nil}} = WireConfig.translate(%{"enabled" => true})
    end

    test "only ipv6 present is valid and yields nil/nil" do
      body = %{"ipv6" => %{"method" => "auto"}}
      assert {:ok, %{ipv4: nil, wifi: nil}} = WireConfig.translate(body)
    end
  end

  describe "translate/1 error paths" do
    test "empty body -> upstream's verbatim message" do
      assert WireConfig.translate(%{}) ==
               {:error, "You need to supply at least one option to update"}
    end

    test "unknown top-level key" do
      assert {:error, message} = WireConfig.translate(%{"foo" => 1, "bar" => 2})
      assert message == "unknown field(s): bar, foo"
    end

    test "unknown nested ipv4 key" do
      assert {:error, message} = WireConfig.translate(%{"ipv4" => %{"frobnicate" => true}})
      assert message == "unknown ipv4 field(s): frobnicate"
    end

    test "unknown nested wifi key" do
      body = %{"wifi" => %{"ssid" => "x", "frobnicate" => true}}
      assert {:error, message} = WireConfig.translate(body)
      assert message == "unknown wifi field(s): frobnicate"
    end

    test "non-map ipv4" do
      assert {:error, message} = WireConfig.translate(%{"ipv4" => "nope"})
      assert message =~ "ipv4 must be an object"
    end

    test ~S(method "dhcp" is rejected — it's a vintage_net-internal name, never sent on the wire) do
      assert {:error, message} = WireConfig.translate(%{"ipv4" => %{"method" => "dhcp"}})
      assert message =~ ~s(invalid ipv4 method "dhcp")
      assert message =~ "disabled, static or auto"
    end

    test "static without address" do
      assert {:error, message} = WireConfig.translate(%{"ipv4" => %{"method" => "static"}})
      assert message == "static ipv4 configuration needs at least one address"
    end

    test "static with empty address list" do
      body = %{"ipv4" => %{"method" => "static", "address" => []}}
      assert {:error, message} = WireConfig.translate(body)
      assert message == "static ipv4 configuration needs at least one address"
    end

    test "malformed CIDR" do
      body = %{"ipv4" => %{"method" => "static", "address" => ["not-an-ip"]}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid address"
    end

    test "CIDR missing prefix length" do
      body = %{"ipv4" => %{"method" => "static", "address" => ["192.168.2.5"]}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid address"
    end

    test "bad gateway" do
      body = %{
        "ipv4" => %{"method" => "static", "address" => ["192.168.2.5/24"], "gateway" => "nope"}
      }

      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid ipv4 gateway"
    end

    test "bad nameserver" do
      body = %{
        "ipv4" => %{
          "method" => "static",
          "address" => ["192.168.2.5/24"],
          "nameservers" => ["not-an-ip"]
        }
      }

      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid address"
    end

    test "ssid missing" do
      body = %{"wifi" => %{"auth" => "open"}}
      assert WireConfig.translate(body) == {:error, "wifi configuration needs an ssid"}
    end

    test "psk missing for wpa-psk" do
      body = %{"wifi" => %{"ssid" => "MyNet", "auth" => "wpa-psk"}}
      assert WireConfig.translate(body) == {:error, "psk is required for wpa-psk"}
    end

    test "wep is honestly unsupported" do
      body = %{"wifi" => %{"ssid" => "MyNet", "auth" => "wep"}}
      assert WireConfig.translate(body) == {:error, "auth method wep is not supported"}
    end

    test "wifi mode ap is honestly unsupported (not silently applied as wpa-psk)" do
      body = %{"wifi" => %{"ssid" => "MyNet", "mode" => "ap", "auth" => "open"}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "wifi mode"
      assert message =~ "not supported"
    end

    test "wifi mode mesh is honestly unsupported" do
      body = %{"wifi" => %{"ssid" => "MyNet", "mode" => "mesh"}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "not supported"
    end

    test "enabled non-boolean" do
      assert {:error, message} = WireConfig.translate(%{"enabled" => "yes"})
      assert message =~ "enabled must be a boolean"
    end

    test "bad mdns enum" do
      assert {:error, message} = WireConfig.translate(%{"mdns" => "bogus"})
      assert message =~ "invalid mdns"
    end

    test "bad llmnr enum" do
      assert {:error, message} = WireConfig.translate(%{"llmnr" => "bogus"})
      assert message =~ "invalid llmnr"
    end

    test "malformed ipv6 member (address)" do
      body = %{"ipv6" => %{"address" => ["not-an-ip"]}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid address"
    end

    test "malformed ipv6 member (method)" do
      body = %{"ipv6" => %{"method" => "dhcp"}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid ipv6 method"
    end

    test "malformed ipv6 member (addr_gen_mode)" do
      body = %{"ipv6" => %{"addr_gen_mode" => "bogus"}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid addr_gen_mode"
    end

    test "malformed ipv6 member (ip6_privacy)" do
      body = %{"ipv6" => %{"ip6_privacy" => "bogus"}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid ip6_privacy"
    end

    test "non-map ipv6" do
      assert {:error, message} = WireConfig.translate(%{"ipv6" => "nope"})
      assert message =~ "ipv6 must be an object"
    end

    test "non-map wifi" do
      assert {:error, message} = WireConfig.translate(%{"wifi" => "nope"})
      assert message =~ "wifi must be an object"
    end

    test "a container wrong-type value names its type instead of echoing contents (a smuggled psk stays out of the message)" do
      body = %{"wifi" => [%{"psk" => "supersecret"}]}
      assert WireConfig.translate(body) == {:error, "wifi must be an object, got a list"}
    end

    test "a map value in a list-typed slot names its type instead of echoing contents" do
      body = %{"ipv4" => %{"method" => "static", "address" => %{"psk" => "supersecret"}}}
      assert {:error, message} = WireConfig.translate(body)
      assert message == "ipv4 address must be a list, got a map"
    end

    test "extra ipv4 address beyond the first is accepted but only the first is applied" do
      body = %{
        "ipv4" => %{
          "method" => "static",
          "address" => ["192.168.2.5/24", "192.168.2.6/24"]
        }
      }

      assert {:ok, %{ipv4: %{address: "192.168.2.5", prefix_length: 24}}} =
               WireConfig.translate(body)
    end

    test "malformed extra ipv4 address (beyond first) is still rejected" do
      body = %{
        "ipv4" => %{
          "method" => "static",
          "address" => ["192.168.2.5/24", "garbage"]
        }
      }

      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid address"
    end

    test "ipv4 method auto still shape-validates address" do
      body = %{"ipv4" => %{"method" => "auto", "address" => ["not-a-cidr"]}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid address"
    end

    test "ipv4 method disabled still shape-validates gateway" do
      body = %{"ipv4" => %{"method" => "disabled", "gateway" => "not-an-ip"}}
      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "invalid ipv4 gateway"
    end

    test "ipv4 route_metric is validated even for static" do
      body = %{
        "ipv4" => %{
          "method" => "static",
          "address" => ["10.0.0.2/24"],
          "route_metric" => "high"
        }
      }

      assert {:error, message} = WireConfig.translate(body)
      assert message =~ "ipv4 route_metric must be an integer"
    end

    test "valid-but-ignored ipv4 keys under auto are shape-checked then dropped" do
      body = %{
        "ipv4" => %{
          "method" => "auto",
          "address" => ["10.0.0.5/24"],
          "gateway" => "10.0.0.1",
          "route_metric" => 5,
          "nameservers" => ["1.1.1.1"]
        }
      }

      assert {:ok, %{ipv4: %{method: :dhcp}, wifi: nil}} = WireConfig.translate(body)
    end

    test "nothing raises for a completely wrong-shaped body" do
      bodies = [
        %{"ipv4" => 1},
        %{"ipv4" => %{"address" => "not-a-list"}},
        %{"wifi" => 1},
        %{"ipv6" => %{"nameservers" => "not-a-list"}},
        %{"ipv4" => %{"nameservers" => "not-a-list"}},
        %{"ipv6" => %{"route_metric" => "not-an-int"}},
        %{"ipv6" => %{"gateway" => "not-an-ip"}}
      ]

      for body <- bodies do
        assert {:error, _message} = WireConfig.translate(body)
      end
    end

    test "non-map top-level body" do
      assert {:error, _message} = WireConfig.translate("not-a-map")
    end
  end
end
