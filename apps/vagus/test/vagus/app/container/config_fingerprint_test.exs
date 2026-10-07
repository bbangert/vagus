defmodule Vagus.App.Container.ConfigFingerprintTest do
  @moduledoc """
  `Vagus.App.Container.Config` against what a real Supervisor's app
  container looks like from the inside: the capture
  `Vagus.Addon.ContainerFingerprintTest` holds the builder before this one
  to, read here from the engine config instead of the intermediate struct.

  What is compared and what is not, and how the capture is regenerated, is
  written there. What the capture itself must satisfy (redaction, its
  version) is tested there alone.
  """

  use ExUnit.Case, async: true

  alias Vagus.Addon.Config, as: Manifest
  alias Vagus.App.Container.Config
  alias Vagus.App.Facts
  alias Vagus.App.Spec.Schema

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "..",
                  "fixtures",
                  "haos-2026.07.5-container-fingerprint.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()
  @fingerprint @fixture["fingerprint"]
  @identity @fixture["identity"]

  # What every container on this engine has, whoever made it.
  @engine_baseline ~w(/ /dev/hugepages /dev/mqueue /dev/pts /dev/shm /etc/hostname /etc/hosts
                      /etc/resolv.conf /proc /sys)
  @engine_baseline_prefixes ["/proc/", "/sys/"]

  # Accepted differences, each for the reason given beside its twin in
  # `Vagus.Addon.ContainerFingerprintTest`.
  @accepted_mounts ["/run/cid"]
  @accepted_dns_options ["ndots:0"]

  setup_all do
    {:ok, manifest} =
      Manifest.parse(%{
        "name" => "Elixir probe",
        "version" => @identity["version"],
        "slug" => @identity["slug"],
        "description" => "bench probe",
        "arch" => [@fixture["versions"]["arch"]],
        "image" => "ghcr.io/bbangert/ha-bench-addons/elixir_probe",
        "init" => false,
        "boot" => "manual",
        "startup" => "application",
        "homeassistant_api" => @identity["homeassistant_api"],
        "hassio_api" => @identity["hassio_api"],
        "ports" => %{"4000/tcp" => 4000}
      })

    facts =
      Facts.read(
        arch: @fixture["versions"]["arch"],
        image_arch: @fixture["versions"]["arch"],
        data_root: "/mnt/data/supervisor",
        timezone: @fingerprint["env"]["TZ"]
      )

    {:ok, spec} = manifest |> Schema.from_manifest(facts) |> Schema.validate(facts)

    {:ok, config} =
      Config.build(spec, facts, %{token: "fingerprint-token", device_cgroup_rules: []})

    %{config: config, host: config["HostConfig"], facts: facts}
  end

  defp env(config) do
    Map.new(config["Env"], fn entry ->
      [key, value] = String.split(entry, "=", parts: 2)
      {key, value}
    end)
  end

  defp fixture_mounts(target), do: Enum.filter(@fingerprint["mounts"], &(&1["target"] == target))

  test "every env var the config injects reached the container", %{config: config} do
    env = env(config)
    real = @fingerprint["env"]

    assert Enum.sort(Map.keys(env)) == ["HASSIO_TOKEN", "SUPERVISOR_TOKEN", "TZ"]

    for {key, _value} <- env do
      assert Map.has_key?(real, key), "the config injects #{key}, the real app had no such var"
    end

    assert env["TZ"] == real["TZ"]

    for key <- ["SUPERVISOR_TOKEN", "HASSIO_TOKEN"] do
      assert env[key] == "fingerprint-token"
      assert String.starts_with?(real[key], "<redacted ")
    end
  end

  test "the hostname is the slug with underscores dashed, in the app network's domain", %{
    config: config,
    facts: facts
  } do
    expected = String.replace(@identity["slug"], "_", "-")

    assert @fingerprint["hostname"] == expected
    assert config["Hostname"] == expected
    assert config["Domainname"] in @fingerprint["resolv_conf"]["search"]

    assert config["NetworkingConfig"] ==
             %{"EndpointsConfig" => %{facts.network_name => %{"Aliases" => [expected]}}}
  end

  test "resolver search domain and options match, ndots aside", %{host: host} do
    resolv = @fingerprint["resolv_conf"]

    assert host["DnsSearch"] == resolv["search"]
    # The engine's embedded resolver, which forwards to what `Dns` names.
    assert resolv["nameservers"] == ["127.0.0.11"]
    assert host["Dns"] != []

    for option <- host["DnsOptions"] do
      assert option in resolv["options"],
             "the config sets #{option}, the real resolv.conf has not"
    end

    assert (resolv["options"] -- host["DnsOptions"]) -- @accepted_dns_options == []
  end

  test "supervisor and hassio resolve to the bridge anchor", %{host: host, facts: facts} do
    hosts =
      Map.new(host["ExtraHosts"], fn entry ->
        [name, ip] = String.split(entry, ":", parts: 2)
        {name, ip}
      end)

    assert Enum.sort(Map.keys(hosts)) == ["hassio", "supervisor"]

    for {name, ip} <- hosts do
      entry = Enum.find(@fingerprint["etc_hosts"], &(name in &1["names"]))

      assert entry, "the config injects host #{name}, absent from the real /etc/hosts"
      assert entry["ip"] == ip
      assert ip == facts.supervisor_ip
    end
  end

  test "the tmpfs entries exist as tmpfs in the container", %{host: host} do
    assert Map.keys(host["Tmpfs"]) == ["/dev/shm"]
    # The engine's own and the Supervisor's stacked over it.
    assert length(fixture_mounts("/dev/shm")) == 2

    for {target, _options} <- host["Tmpfs"] do
      assert Enum.all?(fixture_mounts(target), &(&1["fstype"] == "tmpfs"))
    end
  end

  test "every mount the config declares is in the container, as writable as there", %{host: host} do
    assert host["Mounts"] != []

    for mount <- host["Mounts"] do
      real = fixture_mounts(mount["Target"])

      assert mount["Type"] == "bind"
      assert real != [], "the config mounts #{mount["Target"]}, absent from the real mount table"
      assert Enum.all?(real, &(&1["ro"] == mount["ReadOnly"])), mount["Target"]
    end

    # `/dev` is what this pins read-only, and as upstream binds it.
    dev = Enum.find(host["Mounts"], &(&1["Target"] == "/dev"))
    assert dev["ReadOnly"]
    assert dev["BindOptions"] == %{"ReadOnlyNonRecursive" => true}
  end

  test "every mount the container has is explained", %{host: host} do
    explained = Map.keys(host["Tmpfs"]) ++ Enum.map(host["Mounts"], & &1["Target"])

    unexplained =
      @fingerprint["mounts"]
      |> Enum.map(& &1["target"])
      |> Enum.uniq()
      |> Enum.reject(fn target ->
        target in explained or target in @engine_baseline or target in @accepted_mounts or
          Enum.any?(@engine_baseline_prefixes, &String.starts_with?(target, &1))
      end)

    assert unexplained == []
    # The ledger is still what was accepted, and not more.
    assert Enum.all?(@accepted_mounts, &(fixture_mounts(&1) != []))
    refute Enum.any?(@accepted_mounts, &(&1 in explained))
  end

  test "OomScoreAdj, seccomp, privilege and pid 1 are what the container shows", %{host: host} do
    assert @fingerprint["proc"]["oom_score_adj"] == host["OomScoreAdj"]

    # `Seccomp: 0` in /proc/self/status is what `seccomp=unconfined` does.
    assert @fingerprint["status"]["Seccomp"] == "0"
    assert host["SecurityOpt"] == ["seccomp=unconfined"]
    assert host["Privileged"] == false

    # No init shim: the image's own entrypoint is pid 1.
    assert host["Init"] == false
    assert @fingerprint["proc"]["pid1_comm"] == "beam.smp"
  end

  test "the port the manifest declares is published, and the container is managed", %{
    config: config,
    host: host
  } do
    assert config["ExposedPorts"] == %{"4000/tcp" => %{}}
    assert host["PortBindings"] == %{"4000/tcp" => [%{"HostPort" => "4000"}]}
    assert config["Labels"] == %{"supervisor_managed" => ""}
    assert host["RestartPolicy"] == %{"Name" => ""}
  end
end
