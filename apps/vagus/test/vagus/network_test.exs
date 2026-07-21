defmodule Vagus.NetworkTest do
  use ExUnit.Case, async: false

  alias Vagus.Network
  alias Vagus.Runtime.Docker

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
