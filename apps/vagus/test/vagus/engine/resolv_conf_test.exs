defmodule Vagus.Engine.ResolvConfTest do
  use ExUnit.Case, async: true

  alias Vagus.Engine.ResolvConf

  describe "build/1" do
    test "renders one nameserver line per plain IP tuple" do
      assert ResolvConf.build([{1, 1, 1, 1}, {8, 8, 8, 8}]) ==
               "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
    end

    test "renders VintageNet's [\"name_servers\"] map shape (address key)" do
      servers = [
        %{address: {192, 168, 1, 1}, from: ["eth0"]},
        %{address: {1, 1, 1, 1}, from: [:global]}
      ]

      assert ResolvConf.build(servers) ==
               "nameserver 192.168.1.1\nnameserver 1.1.1.1\n"
    end

    test "falls back to the static resolvers when given an empty list" do
      assert ResolvConf.build([]) == ResolvConf.build(ResolvConf.fallback_servers())
      assert ResolvConf.build([]) == "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
    end

    test "supports IPv6 addresses" do
      assert ResolvConf.build([{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]) ==
               "nameserver 2606:4700:4700::1111\n"
    end
  end

  test "path/0 is /run/resolv.conf" do
    assert ResolvConf.path() == "/run/resolv.conf"
  end
end
