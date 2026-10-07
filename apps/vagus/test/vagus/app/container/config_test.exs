defmodule Vagus.App.Container.ConfigTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.Backend.Container, as: OldBackend
  alias Vagus.Addon.{Devices, Manager}
  alias Vagus.App.Container.Config
  alias Vagus.App.{Facts, Profile}
  alias Vagus.App.Spec.Schema
  alias Vagus.Test.AppManifests

  # Resolving a manifest's devices logs what each path resolved to.
  @moduletag :capture_log

  @archs ["aarch64", "amd64", "armv7", "armhf", "i386", "riscv64"]
  @roots ["/data", "/mnt/data/supervisor"]
  @zones ["UTC", "Europe/Berlin"]

  defp facts(overrides \\ []), do: Facts.read([machine: "raspberrypi3-64"] ++ overrides)

  # Host-port overrides as a user could have stored them: none, a remap, a
  # port unpublished, a port the manifest does not declare, and each port the
  # system keeps for itself.
  defp port_variants(config) do
    declared = config.ports |> Map.keys() |> Enum.sort()

    remaps =
      for port <- Enum.take(declared, 1),
          host <- [9_999, nil, 80, 8_123, 8_888],
          do: %{port => host}

    [%{}, %{"31337/tcp" => 31_337}] ++ remaps
  end

  defp admitted(config, facts, fields) do
    fields =
      if Schema.dynamic_ingress?(config),
        do: Map.put(fields, :ingress_port, 62_000),
        else: fields

    # Admission is for the machine; the image's architecture varies freely.
    {:ok, spec} =
      config
      |> Schema.from_manifest(facts, fields)
      |> Schema.validate(%{facts | arch: hd(config.arch)})

    spec
  end

  defp old(config, arch, root, zone, protected, ports, token) do
    Manager.build_spec(config,
      access_token: token,
      arch: arch,
      data_root: root,
      tz: zone,
      protected: protected,
      ports: ports
    )
  end

  defp new(config, facts, protected, ports, token) do
    spec = admitted(config, facts, %{settings: %{protected: protected, ports: ports}})
    creation = %{token: token, device_cgroup_rules: Devices.cgroup_rules(config, protected)}
    {spec, Config.build(spec, facts, creation)}
  end

  describe "against the builder it replaces" do
    test "every manifest, in every variation, gives the same engine config" do
      compared =
        for config <- AppManifests.containers(),
            arch <- @archs,
            root <- @roots,
            zone <- @zones,
            protected <- [true, false],
            ports <- port_variants(config) do
          facts = facts(image_arch: arch, data_root: root, timezone: zone)
          token = "token-#{arch}-#{protected}"

          before = old(config, arch, root, zone, protected, ports, token)
          {spec, {:ok, built}} = new(config, facts, protected, ports, token)

          context = "#{config.slug} #{arch} #{root} #{zone} #{protected} #{inspect(ports)}"

          assert built == OldBackend.build_config(before), context
          assert Config.image(spec, facts) == {:ok, before.image}, context
          assert Config.platform(facts) == before.platform, context

          # The one thing that differs, and it is no part of the config.
          assert before.name == "addon_" <> config.slug
          assert Profile.of(spec).container_name(config.slug) == "app_" <> config.slug

          assert Config.bind_sources(spec, facts) ==
                   for(
                     mount <- before.mounts,
                     not Map.get(mount, :system, false),
                     do: mount.source
                   ),
                 context

          1
        end

      manifests = length(AppManifests.containers())
      assert manifests == 10
      assert length(compared) >= manifests * 6 * 2 * 2 * 2 * 2
    end

    test "with nothing given, the facts read are what the old builder reads for itself" do
      facts = Facts.read()

      for config <- AppManifests.containers() do
        before = Manager.build_spec(config, access_token: "t")
        spec = admitted(config, facts, %{})
        creation = %{token: "t", device_cgroup_rules: Devices.cgroup_rules(config, true)}

        assert Config.build(spec, facts, creation) == {:ok, OldBackend.build_config(before)}
        assert Config.platform(facts) == before.platform
      end

      assert facts.arch == Vagus.API.StaticData.arch()
      assert facts.machine == Vagus.API.StaticData.machine()
      assert facts.reserved_host_ports == Vagus.Addon.Ports.reserved_host_ports()
      assert facts.native_apps == ["core_mqtt"]
      assert facts.core_version == nil
    end

    test "nothing in the config names the container" do
      for config <- AppManifests.containers() do
        {_spec, {:ok, built}} = new(config, facts(), true, %{}, "t")
        text = inspect(built, limit: :infinity)

        refute text =~ "addon_" <> config.slug
        refute text =~ "app_" <> config.slug
      end
    end

    test "the variations do vary: each input reaches the config" do
      config = AppManifests.get("local_namespaces")

      build = fn facts, protected, ports ->
        new(config, facts, protected, ports, "t") |> elem(1) |> elem(1)
      end

      base = build.(facts(), true, %{})

      assert base["HostConfig"]["PortBindings"]["53/udp"] == [%{"HostPort" => "53"}]
      # The system's own ports are declared and not published.
      assert base["HostConfig"]["PortBindings"]["8888/tcp"] == [%{"HostPort" => ""}]
      assert base["HostConfig"]["PortBindings"]["80/tcp"] == [%{"HostPort" => ""}]
      refute is_map_key(base["HostConfig"], "PidMode")

      unprotected = build.(facts(), false, %{})
      assert unprotected["HostConfig"]["PidMode"] == "host"

      assert unprotected["HostConfig"]["DeviceCgroupRules"] !=
               base["HostConfig"]["DeviceCgroupRules"]

      remapped = build.(facts(), true, %{"53/udp" => 5_353})
      assert remapped["HostConfig"]["PortBindings"]["53/udp"] == [%{"HostPort" => "5353"}]

      assert build.(facts(image_arch: "amd64"), true, %{})["Image"] ==
               "local/amd64-namespaces:1.0.0"

      assert "TZ=Asia/Tokyo" in build.(facts(timezone: "Asia/Tokyo"), true, %{})["Env"]

      moved = build.(facts(data_root: "/elsewhere"), true, %{})

      assert hd(moved["HostConfig"]["Mounts"])["Source"] ==
               "/elsewhere/addons/data/local_namespaces"

      other_net =
        build.(
          facts(network_name: "other", supervisor_ip: "10.0.0.2", dns_ip: "10.0.0.3"),
          true,
          %{}
        )

      assert other_net["HostConfig"]["NetworkMode"] == "other"
      assert other_net["HostConfig"]["Dns"] == ["10.0.0.3"]
      assert other_net["HostConfig"]["ExtraHosts"] == ["hassio:10.0.0.2", "supervisor:10.0.0.2"]
      assert Map.keys(other_net["NetworkingConfig"]["EndpointsConfig"]) == ["other"]
    end
  end

  describe "build/3" do
    test "puts the token in the environment under both names, and nowhere else" do
      {_spec, {:ok, built}} =
        new(AppManifests.get("core_mosquitto"), facts(), true, %{}, "s3cret")

      assert built["Env"] == ["HASSIO_TOKEN=s3cret", "SUPERVISOR_TOKEN=s3cret", "TZ=UTC"]
      refute inspect(Map.delete(built, "Env"), limit: :infinity) =~ "s3cret"
    end

    test "runs the version of the spec, which an update moves ahead of the manifest's" do
      facts = facts(image_arch: "aarch64")
      spec = admitted(AppManifests.get("core_mosquitto"), facts, %{version: "7.2.0"})

      assert {:ok, %{"Image" => "homeassistant/aarch64-addon-mosquitto:7.2.0"}} =
               Config.build(spec, facts, %{token: "t", device_cgroup_rules: []})
    end

    test "has the restart policy of the profile" do
      {_spec, {:ok, built}} = new(AppManifests.get("core_mosquitto"), facts(), true, %{}, "t")

      assert built["HostConfig"]["RestartPolicy"] == %{
               "Name" => Profile.Container.engine_restart()
             }

      assert built["HostConfig"]["RestartPolicy"] == %{"Name" => ""}
    end

    test "is given the device rules and does not look for them" do
      facts = facts()
      spec = admitted(AppManifests.get("45df7312_zigbee2mqtt"), facts, %{})

      assert {:ok, built} =
               Config.build(spec, facts, %{token: "t", device_cgroup_rules: ["c 188:0 rwm"]})

      assert built["HostConfig"]["DeviceCgroupRules"] == ["c 188:0 rwm"]
    end

    test "leaves out a mapping of a type it does not know" do
      {_spec, {:ok, built}} = new(AppManifests.get("local_once"), facts(), true, %{}, "t")

      assert Enum.map(built["HostConfig"]["Mounts"], & &1["Target"]) ==
               ["/data", "/config", "/media", "/dev"]
    end

    test "refuses Core and a native app, which are not described here" do
      facts = facts()
      creation = %{token: "t", device_cgroup_rules: []}
      {:ok, core} = Schema.validate(%{lifecycle: :core, version: "2026.10.1"}, facts)
      native = admitted(AppManifests.native(), facts, %{})

      assert Config.build(core, facts, creation) == {:error, {:not_a_container, :core}}
      assert Config.build(native, facts, creation) == {:error, {:not_a_container, :native}}
    end

    test "refuses a manifest with no image, as does image/2" do
      facts = facts()
      config = AppManifests.parse!(%{"name" => "n", "version" => "1", "slug" => "local_build"})

      spec = %{
        lifecycle: :container,
        config: config,
        version: "1",
        settings: Profile.Container.settings()
      }

      assert Config.image(spec, facts) == {:error, :no_image}

      assert Config.build(spec, facts, %{token: "t", device_cgroup_rules: []}) ==
               {:error, :no_image}
    end

    test "bind_sources/2 are the app's own directories and none of the system's" do
      facts = facts(data_root: "/data")
      spec = admitted(AppManifests.get("a0d7b954_glances"), facts, %{})

      assert Config.bind_sources(spec, facts) == ["/data/addons/data/a0d7b954_glances"]

      spec = admitted(AppManifests.get("core_mosquitto"), facts, %{})

      assert Config.bind_sources(spec, facts) ==
               ["/data/addons/data/core_mosquitto", "/data/ssl", "/data/share"]
    end
  end
end

defmodule Vagus.App.Container.ConfigDspTest do
  # Not async: the builder this is compared with reads the DSP store's path
  # from the application's environment.
  use ExUnit.Case, async: false

  alias Vagus.Addon.Backend.Container, as: OldBackend
  alias Vagus.Addon.{Devices, Manager}
  alias Vagus.App.Container.Config
  alias Vagus.App.Facts
  alias Vagus.App.Spec.Schema
  alias Vagus.Test.AppManifests

  @moduletag :capture_log

  setup do
    before = Application.get_env(:vagus, :dsp_root)

    on_exit(fn ->
      if before,
        do: Application.put_env(:vagus, :dsp_root, before),
        else: Application.delete_env(:vagus, :dsp_root)
    end)
  end

  test "a board with a DSP store binds it, one without binds only the shells, as before" do
    config = AppManifests.get("local_dsp")

    for root <- ["/data/vagus/dsp", nil] do
      if root,
        do: Application.put_env(:vagus, :dsp_root, root),
        else: Application.delete_env(:vagus, :dsp_root)

      facts = Facts.read(image_arch: "aarch64", data_root: "/data")
      assert facts.dsp_root == root

      {:ok, spec} = config |> Schema.from_manifest(facts) |> Schema.validate(facts)
      rules = Devices.cgroup_rules(config, true)
      before = Manager.build_spec(config, access_token: "t", arch: "aarch64", data_root: "/data")

      assert {:ok, built} = Config.build(spec, facts, %{token: "t", device_cgroup_rules: rules})
      assert built == OldBackend.build_config(before)

      targets = Enum.map(built["HostConfig"]["Mounts"], & &1["Target"])
      assert "/usr/lib/dsp" in targets
      assert "/usr/lib/rfsa/adsp" in targets == (root != nil)
      assert Config.bind_sources(spec, facts) == ["/data/addons/data/local_dsp"]
    end
  end
end
