defmodule Vagus.Addon.Backend.ContainerTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Backend.{Container, Spec}

  defp mosquitto_spec(overrides \\ []) do
    base = %Spec{
      name: "addon_core_mosquitto",
      image: "homeassistant/amd64-addon-mosquitto:7.1.0",
      hostname: "core-mosquitto",
      env: %{"TZ" => "UTC", "SUPERVISOR_TOKEN" => "tok", "HASSIO_TOKEN" => "tok"},
      network: :hassio,
      extra_hosts: %{"supervisor" => "172.30.32.2", "hassio" => "172.30.32.2"},
      dns: ["172.30.32.3"],
      dns_search: ["local.hass.io"],
      dns_options: ["timeout:10"],
      init: false,
      ports: %{"1883/tcp" => "1883", "8883/tcp" => "8883"},
      mounts: [
        %{source: "/data/ssl", target: "/ssl", read_only: false},
        %{source: "/data/share", target: "/share", read_only: false, propagation: "rslave"}
      ]
    }

    struct(base, overrides)
  end

  describe "build_config/1 — pinned §A1.4 invariants" do
    setup do
      %{cfg: Container.build_config(mosquitto_spec()), host: Container.build_config(mosquitto_spec()) |> Map.fetch!("HostConfig")}
    end

    test "Privileged is always false", %{host: host}, do: assert host["Privileged"] == false

    test "SecurityOpt always includes seccomp=unconfined", %{host: host} do
      assert host["SecurityOpt"] == ["seccomp=unconfined"]
    end

    test "OomScoreAdj is 200", %{host: host}, do: assert host["OomScoreAdj"] == 200

    test "no restart policy", %{host: host}, do: assert host["RestartPolicy"] == %{"Name" => ""}

    test "supervisor_managed label always present", %{cfg: cfg} do
      assert cfg["Labels"]["supervisor_managed"] == ""
    end

    test "ExtraHosts rendered name:ip and sorted", %{host: host} do
      assert host["ExtraHosts"] == ["hassio:172.30.32.2", "supervisor:172.30.32.2"]
    end

    test "DNS wiring", %{host: host} do
      assert host["Dns"] == ["172.30.32.3"]
      assert host["DnsSearch"] == ["local.hass.io"]
      assert host["DnsOptions"] == ["timeout:10"]
    end

    test "Init reflects the spec", %{host: host}, do: assert host["Init"] == false

    test "hostname + Domainname + bridge alias", %{cfg: cfg} do
      assert cfg["Hostname"] == "core-mosquitto"
      assert cfg["Domainname"] == "local.hass.io"
      assert cfg["HostConfig"]["NetworkMode"] == "hassio"
      assert cfg["NetworkingConfig"]["EndpointsConfig"]["hassio"]["Aliases"] == ["core-mosquitto"]
    end

    test "ports → PortBindings + ExposedPorts", %{cfg: cfg} do
      assert cfg["HostConfig"]["PortBindings"]["1883/tcp"] == [%{"HostPort" => "1883"}]
      assert cfg["ExposedPorts"]["8883/tcp"] == %{}
    end

    test "env map normalized to a sorted K=V list", %{cfg: cfg} do
      assert cfg["Env"] == ["HASSIO_TOKEN=tok", "SUPERVISOR_TOKEN=tok", "TZ=UTC"]
    end

    test "mounts → bind mounts with propagation + read_only", %{host: host} do
      assert %{"Type" => "bind", "Source" => "/data/ssl", "Target" => "/ssl", "ReadOnly" => false} in
               host["Mounts"]

      share = Enum.find(host["Mounts"], &(&1["Target"] == "/share"))
      assert share["BindOptions"] == %{"Propagation" => "rslave"}
    end
  end

  describe "build_config/1 — variants" do
    test "apparmor profile adds a SecurityOpt entry" do
      cfg = Container.build_config(mosquitto_spec(apparmor: "addon_core_mosquitto"))
      assert cfg["HostConfig"]["SecurityOpt"] == ["seccomp=unconfined", "apparmor=addon_core_mosquitto"]
    end

    test "host network: NetworkMode host, no port publishing or networking config" do
      cfg = Container.build_config(mosquitto_spec(network: :host))
      assert cfg["HostConfig"]["NetworkMode"] == "host"
      refute Map.has_key?(cfg["HostConfig"], "PortBindings")
      refute Map.has_key?(cfg, "ExposedPorts")
      refute Map.has_key?(cfg, "NetworkingConfig")
    end

    test "no hostname → no Domainname/NetworkingConfig" do
      cfg = Container.build_config(mosquitto_spec(hostname: nil))
      refute Map.has_key?(cfg, "Domainname")
      refute Map.has_key?(cfg, "NetworkingConfig")
    end
  end

  describe "lifecycle via the backend (live daemon)" do
    @describetag :docker

    test "pull → create → start → state → stop → remove" do
      name = "vagus-be-test-#{System.unique_integer([:positive])}"
      on_exit(fn -> Container.remove(name, force: true) end)

      spec = %Spec{name: name, image: "alpine:3", cmd: ["sleep", "30"], network: :host}

      assert :ok = Container.pull(spec)
      assert {:ok, _id} = Container.create(spec)
      assert :ok = Container.start(name)
      assert {:ok, :running} = Container.state(name)
      assert :ok = Container.stop(name, timeout: 1)
      assert {:ok, :stopped} = Container.state(name)
      assert :ok = Container.remove(name)
      assert {:ok, :unknown} = Container.state(name)
    end
  end
end
