defmodule Vagus.Addon.Backend.Container do
  @moduledoc """
  The Docker/balena-engine `Vagus.Addon.Backend` — translates a runtime-neutral
  `Vagus.Addon.Backend.Spec` into an Engine-API container config and drives the
  lifecycle via `Vagus.Runtime.Docker`.

  `build_config/1` is the pure Spec→Docker-JSON translation, and is where the
  §A1.4 cross-cutting invariants are stamped regardless of the spec:

    * `Privileged: false` (add-on `privileged:` maps to `CapAdd`, never Docker
      privileged),
    * `SecurityOpt` always includes `seccomp=unconfined` (+ `apparmor=<x>` iff
      the spec names a profile),
    * `Labels` always includes `supervisor_managed: ""`,
    * `OomScoreAdj: 200`,
    * no `RestartPolicy` (the manager owns start/stop),
    * `Domainname: local.hass.io` when a hostname + DNS are set.
  """

  @behaviour Vagus.Addon.Backend

  alias Vagus.Addon.Backend.Spec
  alias Vagus.Runtime.Docker

  @oom_score_adj 200
  @managed_label "supervisor_managed"
  @dns_suffix "local.hass.io"

  @impl true
  def pull(%Spec{image: image, platform: platform}) do
    Docker.pull_image(image, platform: platform)
  end

  @impl true
  def create(%Spec{} = spec) do
    Docker.create_container(build_config(spec), name: spec.name)
  end

  @impl true
  def start(id), do: Docker.start_container(id)

  @impl true
  def stop(id, opts \\ []), do: Docker.stop_container(id, opts)

  @impl true
  def remove(id, opts \\ []), do: Docker.remove_container(id, opts)

  @impl true
  def remove_image(image, opts \\ []), do: Docker.remove_image(image, opts)

  @impl true
  def state(id) do
    case Docker.inspect_container(id) do
      {:ok, %{"State" => state}} -> {:ok, normalize_state(state)}
      {:error, {:http, 404, _}} -> {:ok, :unknown}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pure Spec → Engine-API `POST /containers/create` config map. Exposed for
  testing the pinned run-param fidelity without a daemon.
  """
  @spec build_config(Spec.t()) :: map()
  def build_config(%Spec{} = spec) do
    host? = spec.network == :host

    %{
      "Image" => spec.image,
      "Env" => normalize_env(spec.env),
      "OpenStdin" => spec.open_stdin,
      "Labels" => Map.put(spec.labels, @managed_label, ""),
      "HostConfig" => host_config(spec, host?)
    }
    |> maybe_put("Hostname", spec.hostname)
    |> maybe_put("Domainname", domainname(spec))
    |> maybe_put("Cmd", spec.cmd)
    |> maybe_put("ExposedPorts", exposed_ports(spec, host?))
    |> maybe_put("NetworkingConfig", networking_config(spec, host?))
  end

  ## Config builders

  defp host_config(spec, host?) do
    %{
      "NetworkMode" => if(host?, do: "host", else: spec.network_name),
      "Privileged" => false,
      "Init" => spec.init,
      "OomScoreAdj" => @oom_score_adj,
      "SecurityOpt" => security_opt(spec),
      "RestartPolicy" => %{"Name" => ""},
      "ExtraHosts" => extra_hosts(spec),
      "CapAdd" => spec.cap_add,
      "Dns" => spec.dns,
      "DnsSearch" => spec.dns_search,
      "DnsOptions" => spec.dns_options,
      "Mounts" => Enum.map(spec.mounts, &mount/1),
      "Tmpfs" => spec.tmpfs,
      # Additive only: these ALLOW nodes the engine's default device policy
      # denies. They cannot revoke anything, which is why an add-on granting
      # nothing still emits the key rather than omitting it.
      "DeviceCgroupRules" => spec.device_cgroup_rules
    }
    |> maybe_put("PortBindings", port_bindings(spec, host?))
    |> maybe_put("PidMode", spec.pid_mode)
    |> maybe_put("UTSMode", spec.uts_mode)
  end

  defp security_opt(spec) do
    apparmor = if spec.apparmor, do: ["apparmor=#{spec.apparmor}"], else: []
    Enum.uniq(["seccomp=unconfined" | apparmor])
  end

  defp extra_hosts(spec) do
    Enum.map(spec.extra_hosts, fn {name, ip} -> "#{name}:#{ip}" end) |> Enum.sort()
  end

  defp domainname(%Spec{hostname: h, dns: dns}) when is_binary(h) and dns != [], do: @dns_suffix
  defp domainname(_), do: nil

  # host-network containers can't publish ports
  defp exposed_ports(_spec, true), do: nil

  defp exposed_ports(%Spec{ports: ports}, false) when map_size(ports) > 0 do
    Map.new(ports, fn {port, _host} -> {port, %{}} end)
  end

  defp exposed_ports(_spec, _), do: nil

  defp port_bindings(_spec, true), do: nil

  defp port_bindings(%Spec{ports: ports}, false) when map_size(ports) > 0 do
    Map.new(ports, fn {port, host} -> {port, [%{"HostPort" => to_string(host)}]} end)
  end

  defp port_bindings(_spec, _), do: nil

  defp networking_config(_spec, true), do: nil

  defp networking_config(%Spec{hostname: h, network_name: net}, false) when is_binary(h) do
    %{"EndpointsConfig" => %{net => %{"Aliases" => [h]}}}
  end

  defp networking_config(_spec, _), do: nil

  defp mount(m) do
    %{
      "Type" => "bind",
      "Source" => m.source,
      "Target" => m.target,
      "ReadOnly" => Map.get(m, :read_only, false)
    }
    |> maybe_put("BindOptions", bind_options(Map.get(m, :propagation)))
  end

  defp bind_options(nil), do: nil
  defp bind_options(propagation), do: %{"Propagation" => propagation}

  defp normalize_env(env) when is_list(env), do: Enum.sort(env)

  defp normalize_env(env) when is_map(env) do
    env |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.sort()
  end

  @doc """
  Normalizes a Docker inspect `"State"` map to a coarse `Backend.state()`.
  Public for hermetic testing (the daemon-facing `state/1` wraps it).
  """
  @spec normalize_state(map()) :: Vagus.Addon.Backend.state()
  def normalize_state(%{"Running" => true}), do: :running
  def normalize_state(%{"Restarting" => true}), do: :restarting
  def normalize_state(%{"Status" => "restarting"}), do: :restarting
  def normalize_state(_), do: :stopped

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
