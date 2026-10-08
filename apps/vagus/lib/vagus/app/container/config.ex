defmodule Vagus.App.Container.Config do
  @moduledoc """
  The engine's description of an app's container, as
  `Vagus.App.Backend.Container.create/3` takes it: one pure function of the
  App spec, the machine's `Vagus.App.Facts`, and what only the moment of
  creation knows.

  The container's name is not part of the description, it is `create/3`'s
  first argument, and nothing in the description is derived from it: the
  hostname and the network alias come from the app's slug.

  What every app container gets whatever its manifest says: never
  `Privileged` (a manifest's `privileged:` is capabilities), seccomp
  unconfined, the `supervisor_managed` label, `OomScoreAdj` 200, and the
  restart policy of its profile, which for an app is none.

  A manifest's `map:` entry of a type unknown here is left out, as is a
  host port the system holds (`facts.reserved_host_ports`): an app that
  declares one is unpublished on that port, not unstartable.

  Core's container is not described here; its profile is `:core` and
  `build/3` refuses it.
  """

  alias Vagus.Addon.Config
  alias Vagus.App.{Facts, Profile}

  @typedoc """
  `token` goes into the environment as `SUPERVISOR_TOKEN` and
  `HASSIO_TOKEN`. `device_cgroup_rules` are the app's
  (`Vagus.Addon.Devices.cgroup_rules/2`): resolving a device path to a rule
  reads the node itself, which is why they come from outside.
  """
  @type creation :: %{token: String.t(), device_cgroup_rules: [String.t()]}

  @typedoc "`:invalid_creation` is a token that is no string or rules that are no list."
  @type refusal ::
          :no_image | :no_manifest | :invalid_creation | {:not_a_container, Profile.tag()}

  # A manifest's `map:` type: the directory under the data root, where it is
  # mounted, and the bind propagation.
  @map_types %{
    "ssl" => {"ssl", "/ssl", nil},
    "share" => {"share", "/share", "rslave"},
    "media" => {"media", "/media", "rslave"},
    "backup" => {"backup", "/backup", nil},
    "config" => {"homeassistant", "/config", nil},
    "homeassistant_config" => {"homeassistant", "/homeassistant", nil},
    "all_addon_configs" => {"addon_configs", "/addon_configs", nil},
    "addons" => {"addons/local", "/addons", nil}
  }

  @dns_suffix "local.hass.io"
  @managed_label "supervisor_managed"

  @doc "The config for a `:container` app. Any other profile is refused."
  @spec build(map(), Facts.t(), creation()) :: {:ok, map()} | {:error, refusal()}
  def build(
        %{lifecycle: :container, config: %Config{} = config} = spec,
        %Facts{} = facts,
        %{token: token, device_cgroup_rules: rules}
      )
      when is_binary(token) and is_list(rules) do
    with {:ok, image} <- image(spec, facts) do
      host? = config.host_network
      hostname = if host?, do: nil, else: hostname(config.slug)
      ports = if host?, do: %{}, else: published(config, spec.settings.ports, facts)

      {:ok,
       %{
         "Image" => image,
         "Env" =>
           Enum.sort([
             "TZ=#{facts.timezone}",
             "SUPERVISOR_TOKEN=#{token}",
             "HASSIO_TOKEN=#{token}"
           ]),
         "OpenStdin" => false,
         "Labels" => %{@managed_label => ""},
         "HostConfig" => host_config(spec, facts, rules, ports)
       }
       |> put("Hostname", hostname)
       |> put("Domainname", hostname && @dns_suffix)
       |> put("ExposedPorts", exposed(ports))
       |> put(
         "NetworkingConfig",
         hostname && %{"EndpointsConfig" => %{facts.network_name => %{"Aliases" => [hostname]}}}
       )}
    end
  end

  def build(%{lifecycle: :container, config: %Config{}}, %Facts{}, _creation),
    do: {:error, :invalid_creation}

  def build(%{lifecycle: :container}, %Facts{}, _creation), do: {:error, :no_manifest}
  def build(%{lifecycle: tag}, %Facts{}, _creation), do: {:error, {:not_a_container, tag}}

  @doc "The image the app runs: the manifest's, for the machine's architecture, at the spec's version."
  @spec image(map(), Facts.t()) :: {:ok, String.t()} | {:error, :no_image}
  def image(%{config: %Config{image: image}, version: version}, %Facts{image_arch: arch})
      when is_binary(image),
      do: {:ok, "#{String.replace(image, "{arch}", arch)}:#{version}"}

  def image(_spec, %Facts{}), do: {:error, :no_image}

  @doc "The platform to pull the image for, or `nil` for the engine's own."
  @spec platform(Facts.t()) :: String.t() | nil
  def platform(%Facts{image_arch: arch}) do
    case arch do
      "amd64" -> "linux/amd64"
      "aarch64" -> "linux/arm64"
      "armv7" -> "linux/arm/v7"
      "armhf" -> "linux/arm/v6"
      "i386" -> "linux/386"
      _other -> nil
    end
  end

  @doc """
  The host directories the container binds that are the app's own, and so
  have to exist before it is created. A bind whose source belongs to the
  system (`/dev`, the bus socket, the DSP's libraries) is not among them:
  made empty here, it would hide that the system does not have it.
  """
  @spec bind_sources(map(), Facts.t()) :: [Path.t()]
  def bind_sources(%{config: %Config{} = config}, %Facts{} = facts),
    do: for(%{system: false} = mount <- mounts(config, facts), do: mount.source)

  defp host_config(%{config: config, settings: settings} = spec, facts, rules, ports) do
    host? = config.host_network

    %{
      "NetworkMode" => if(host?, do: "host", else: facts.network_name),
      "Privileged" => false,
      "Init" => config.init,
      "OomScoreAdj" => 200,
      "SecurityOpt" => ["seccomp=unconfined"],
      "RestartPolicy" => %{"Name" => Profile.of(spec).engine_restart()},
      "ExtraHosts" => ["hassio:#{facts.supervisor_ip}", "supervisor:#{facts.supervisor_ip}"],
      "CapAdd" => config.privileged,
      "Dns" => [facts.dns_ip],
      "DnsSearch" => [@dns_suffix],
      "DnsOptions" => ["timeout:10"],
      "Mounts" => Enum.map(mounts(config, facts), &bind/1),
      "Tmpfs" => if(config.host_ipc, do: %{}, else: %{"/dev/shm" => ""}),
      # Sent even when empty: rules only add to what the engine allows.
      "DeviceCgroupRules" => rules
    }
    |> put("PortBindings", bindings(ports))
    |> put("PidMode", if(not settings.protected and config.host_pid, do: "host"))
    |> put("UTSMode", if(config.host_uts, do: "host"))
  end

  defp hostname(slug), do: String.replace(slug, "_", "-")

  # The manifest names the ports and the user only their host side: an
  # override for a port the manifest no longer has is dropped. A manifest
  # without ports has nothing to restrict to.
  defp published(%Config{ports: declared}, overrides, %Facts{reserved_host_ports: reserved}) do
    ports =
      if declared == %{},
        do: overrides,
        else: Map.new(declared, fn {port, host} -> {port, Map.get(overrides, port, host)} end)

    Map.new(ports, fn {port, host} -> {port, if(host in reserved, do: nil, else: host)} end)
  end

  defp exposed(ports) when ports == %{}, do: nil
  defp exposed(ports), do: Map.new(ports, fn {port, _host} -> {port, %{}} end)

  defp bindings(ports) when ports == %{}, do: nil

  # A port with no host side goes out as `""`.
  defp bindings(ports),
    do: Map.new(ports, fn {port, host} -> {port, [%{"HostPort" => to_string(host)}]} end)

  defp mounts(%Config{slug: slug} = config, %Facts{data_root: root} = facts) do
    data = %{source: Path.join([root, "addons", "data", slug]), target: "/data"}
    mapped = for entry <- config.map, mount = mapped(entry, root, slug), do: mount

    for mount <- [data | mapped] ++ dbus(config) ++ dsp(config, facts) ++ [dev()] do
      Map.merge(
        %{read_only: false, propagation: nil, non_recursive: false, system: false},
        mount
      )
    end
  end

  defp mapped(%{type: "addon_config", read_only: read_only}, root, slug),
    do: %{
      source: Path.join([root, "addon_configs", slug]),
      target: "/config",
      read_only: read_only
    }

  defp mapped(%{type: type, read_only: read_only}, root, _slug) do
    case @map_types do
      %{^type => {directory, target, propagation}} ->
        %{
          source: Path.join(root, directory),
          target: target,
          read_only: read_only,
          propagation: propagation
        }

      _unknown ->
        nil
    end
  end

  defp dbus(%Config{host_dbus: true}),
    do: [%{source: "/run/dbus", target: "/run/dbus", read_only: true, system: true}]

  defp dbus(_config), do: []

  # Two binds: the fastrpc shells the firmware ships, and the skeleton
  # library the operator supplied, which may not be redistributed and so is
  # in no image. A board without a DSP has no store to bind.
  defp dsp(%Config{dsp: true}, %Facts{dsp_root: root}) do
    shells = %{source: "/usr/lib/dsp", target: "/usr/lib/dsp", read_only: true, system: true}
    skel = %{source: root, target: "/usr/lib/rfsa/adsp", read_only: true, system: true}
    if root, do: [shells, skel], else: [shells]
  end

  defp dsp(_config, _facts), do: []

  # Every app sees the host's `/dev`; what it may open there is decided by
  # the device rules. Read-only for the bind only, not forced onto what is
  # mounted beneath it, as upstream has it.
  defp dev,
    do: %{source: "/dev", target: "/dev", read_only: true, non_recursive: true, system: true}

  defp bind(mount) do
    options =
      %{}
      |> put("Propagation", mount.propagation)
      |> put("ReadOnlyNonRecursive", mount.non_recursive || nil)

    %{
      "Type" => "bind",
      "Source" => mount.source,
      "Target" => mount.target,
      "ReadOnly" => mount.read_only
    }
    |> put("BindOptions", if(options != %{}, do: options))
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
