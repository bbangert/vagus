defmodule Vagus.NetworkTest do
  use ExUnit.Case, async: false

  alias Vagus.Network
  alias Vagus.Runtime.Docker

  describe "source_bind_opts/0 (ingress client-IP parity)" do
    # Regression guard for a device-found gap: Vagus runs on the host, so
    # without an explicit bind its add-on connections originate from the
    # bridge gateway .1 rather than the supervisor anchor .2. Add-ons that
    # filter on client IP reject that (core_configurator answered 420 and
    # banned .1, surfacing to Core as a 502).
    setup do
      original = Application.get_env(:vagus, :ingress_source_ip)
      on_exit(fn -> Application.put_env(:vagus, :ingress_source_ip, original) end)
      :ok
    end

    test "returns [] when unset, so :host/:test never bind a missing address" do
      Application.delete_env(:vagus, :ingress_source_ip)
      assert Network.source_bind_opts() == []
    end

    test "parses a configured string into an inet tuple" do
      Application.put_env(:vagus, :ingress_source_ip, "172.30.32.2")
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]
    end

    test "the configured value is the supervisor anchor, not the gateway" do
      Application.put_env(:vagus, :ingress_source_ip, Network.supervisor_ip())
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]
      refute Network.source_bind_opts() == [ip: {172, 30, 32, 1}]
    end

    test "wrong-typed config degrades to [] instead of raising" do
      # Regression: the original `case` had only nil/binary/tuple clauses, so
      # any other type raised CaseClauseError and took ingress connection
      # setup down at runtime over a config typo (Copilot, PR #14).
      for bad <- [42, [1, 2, 3], %{a: 1}, :atom, 1.5] do
        Application.put_env(:vagus, :ingress_source_ip, bad)
        assert Network.source_bind_opts() == [], "expected [] for #{inspect(bad)}"
      end
    end

    test "rejects malformed tuples rather than deferring the failure to connect()" do
      # These are tuples, so the old clause passed them straight through as
      # socket opts; the failure then surfaced inside connect() as an opaque
      # :einval. Wrong arity and an out-of-range octet must both be caught.
      for bad <- [{1, 2}, {999, 0, 0, 1}, {-1, 0, 0, 1}, {:a, :b, :c, :d}] do
        Application.put_env(:vagus, :ingress_source_ip, bad)
        assert Network.source_bind_opts() == [], "expected [] for #{inspect(bad)}"
      end
    end

    test "still accepts a valid IPv6 tuple" do
      Application.put_env(:vagus, :ingress_source_ip, {0, 0, 0, 0, 0, 0, 0, 1})
      assert Network.source_bind_opts() == [ip: {0, 0, 0, 0, 0, 0, 0, 1}]
    end

    test "accepts a tuple as-is and ignores an unparseable string" do
      Application.put_env(:vagus, :ingress_source_ip, {172, 30, 32, 2})
      assert Network.source_bind_opts() == [ip: {172, 30, 32, 2}]

      Application.put_env(:vagus, :ingress_source_ip, "not-an-ip")
      assert Network.source_bind_opts() == []
    end
  end

  describe "IP plan (hermetic)" do
    test "config/0 pins the hassio subnet, gateway, dynamic range + bridge name" do
      cfg = Network.config()
      assert cfg["Name"] == "hassio"
      assert cfg["Driver"] == "bridge"
      assert cfg["Options"]["com.docker.network.bridge.name"] == "hassio"

      [ipam] = cfg["IPAM"]["Config"]
      assert ipam["Subnet"] == "172.30.32.0/23"
      assert ipam["Gateway"] == "172.30.32.1"
      assert ipam["IPRange"] == "172.30.33.0/24"
    end

    test "fixed anchors match the contract" do
      assert Network.anchors() == %{
               gateway: "172.30.32.1",
               supervisor: "172.30.32.2",
               dns: "172.30.32.3",
               audio: "172.30.32.4",
               cli: "172.30.32.5",
               observer: "172.30.32.6"
             }

      assert Network.supervisor_ip() == "172.30.32.2"
      assert Network.dns_ip() == "172.30.32.3"
      assert Network.name() == "hassio"
    end

    test "ensure/1 surfaces a connect error on a dead socket, never raises" do
      assert {:error, _} =
               Network.ensure(
                 socket: "/tmp/vagus-nonet-#{System.unique_integer([:positive])}.sock"
               )
    end
  end

  describe "against a live daemon" do
    @describetag :docker

    test "create_network → inspect (subnet/gateway) → remove" do
      name = "vagus-net-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> Docker.remove_network(name) end)

      cfg = %{
        "Name" => name,
        "Driver" => "bridge",
        "IPAM" => %{"Config" => [%{"Subnet" => "172.31.240.0/24", "Gateway" => "172.31.240.1"}]}
      }

      assert {:ok, id} = Docker.create_network(cfg)
      assert is_binary(id)

      assert {:ok, %{"IPAM" => %{"Config" => [ipam]}}} = Docker.inspect_network(name)
      assert ipam["Subnet"] == "172.31.240.0/24"
      assert ipam["Gateway"] == "172.31.240.1"

      assert :ok = Docker.remove_network(name)
      assert {:error, {:http, 404, _}} = Docker.inspect_network(name)
    end

    test "remove of a missing network is idempotent :ok" do
      assert :ok =
               Docker.remove_network("vagus-net-missing-#{System.unique_integer([:positive])}")
    end

    test "Network.ensure/1 creates the hassio bridge and is idempotent" do
      on_exit(fn -> Docker.remove_network(Network.name()) end)

      assert {:ok, id} = Network.ensure()
      assert is_binary(id)
      # second call adopts the existing network (same id), does not recreate
      assert {:ok, ^id} = Network.ensure()

      assert {:ok, %{"IPAM" => %{"Config" => [ipam]}}} = Docker.inspect_network(Network.name())
      assert ipam["Subnet"] == "172.30.32.0/23"
      assert ipam["Gateway"] == "172.30.32.1"
    end
  end
end
