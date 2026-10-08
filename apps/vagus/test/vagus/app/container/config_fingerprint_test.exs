defmodule Vagus.App.Container.ConfigFingerprintTest do
  @moduledoc """
  `Vagus.App.Container.Config` against what a real Supervisor's app
  container looks like from the inside: the capture
  `Vagus.Addon.ContainerFingerprintTest` holds the builder before this one
  to, read here from the engine config instead of the intermediate struct.

  What is compared and what is not, and how the capture is regenerated, is
  written there. Every assertion here has its ground truth in the capture;
  what the config says that the capture cannot witness (labels, the restart
  policy, published ports, the network alias) is held to the builder this
  one replaces, in `Vagus.App.Container.ConfigTest`. That the capture is
  redacted is tested there alone.
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
  @supervisor_version @fixture_path
                      |> Path.basename()
                      |> String.replace_prefix("haos-", "")
                      |> String.replace_suffix("-container-fingerprint.json", "")
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
  # Mounts the config declares that a real Supervisor's container lacks.
  @vagus_only_mounts []

  @mount_flags ~w(dirsync lazytime noatime nodev nodiratime noexec nosuid nosymfollow
                  relatime strictatime sync)
  @policy_flags ~w(nodev noexec nosuid)

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
    config: config
  } do
    expected = String.replace(@identity["slug"], "_", "-")

    assert @fingerprint["hostname"] == expected
    assert config["Hostname"] == expected
    assert config["Domainname"] in @fingerprint["resolv_conf"]["search"]
  end

  test "resolver search domain and options match, ndots aside", %{host: host} do
    resolv = @fingerprint["resolv_conf"]

    assert host["DnsSearch"] == resolv["search"]
    # The engine's embedded resolver, which forwards to what `Dns` names.
    assert resolv["nameservers"] == ["127.0.0.11"]

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

    for mount <- host["Mounts"], mount["Target"] not in @vagus_only_mounts do
      real = fixture_mounts(mount["Target"])

      assert real != [], "the config mounts #{mount["Target"]}, absent from the real mount table"
      assert Enum.all?(real, &(&1["ro"] == mount["ReadOnly"])), mount["Target"]
    end

    # `/dev` is what this pins read-only: the capture's is.
    assert [%{"ro" => true}] = fixture_mounts("/dev")
    assert Enum.find(host["Mounts"], &(&1["Target"] == "/dev"))["ReadOnly"]
  end

  test "each declared divergence is still real: declared by the config, absent upstream", %{
    host: host
  } do
    declared = Enum.map(host["Mounts"], & &1["Target"])

    for target <- @vagus_only_mounts do
      assert target in declared, "#{target} is ledgered and no longer declared"
      assert fixture_mounts(target) == [], "#{target} is ledgered and the real app has it too"
    end

    # With nothing ledgered, everything declared is upstream's as well.
    assert Enum.all?(declared -- @vagus_only_mounts, &(fixture_mounts(&1) != []))
  end

  test "the accepted mount gap is still exactly what was accepted" do
    assert [cid] = fixture_mounts("/run/cid")

    # The source says this is the Supervisor's doing and not the engine's.
    assert cid["source"] =~ ~r{/supervisor/cid_files/.+\.cid$}
    assert cid["ro"] == true
  end

  test "the capture's mount flags are whole, and tied to the options they came from" do
    mounts = @fingerprint["mounts"]

    for mount <- mounts do
      assert mount["flags"] |> Map.keys() |> Enum.sort() == @mount_flags, mount["target"]
    end

    # Each was witnessed somewhere: a capture where one is nowhere true has
    # lost hardening.
    for flag <- @policy_flags do
      assert Enum.any?(mounts, & &1["flags"][flag]), "no mount carries #{flag}"
    end

    for mount <- mounts, flag <- @mount_flags do
      assert mount["flags"][flag] == flag in String.split(mount["options"], ","),
             "#{mount["target"]}: flags.#{flag} disagrees with options #{mount["options"]}"
    end
  end

  test "the capture records the Supervisor version its filename claims" do
    assert @fixture["versions"]["supervisor"] == @supervisor_version
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

  test "OomScoreAdj, seccomp and pid 1 are what the container shows", %{host: host} do
    assert @fingerprint["proc"]["oom_score_adj"] == host["OomScoreAdj"]

    # `Seccomp: 0` in /proc/self/status is what `seccomp=unconfined` does.
    assert @fingerprint["status"]["Seccomp"] == "0"
    assert host["SecurityOpt"] == ["seccomp=unconfined"]

    # No init shim: the image's own entrypoint is pid 1.
    assert host["Init"] == false
    assert @fingerprint["proc"]["pid1_comm"] == "beam.smp"
  end
end
