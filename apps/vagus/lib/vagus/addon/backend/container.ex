defmodule Vagus.Addon.Backend.Container do
  @moduledoc """
  The container `Vagus.Addon.Backend`: translates a runtime-neutral
  `Vagus.Addon.Backend.Spec` into a `Vagus.Runtime.Engine.ContainerSpec` and
  drives the lifecycle through `Vagus.Runtime.Engine`.

  `to_container_spec/1` is that pure translation, and is where the §A1.4
  cross-cutting invariants are stamped regardless of the spec:

    * `privileged: false` (add-on `privileged:` maps to `cap_add`, never a
      privileged container),
    * `security_opt` always includes `seccomp=unconfined` (+ `apparmor=<x>`
      iff the spec names a profile),
    * `labels` always include `supervisor_managed: ""`,
    * `oom_score_adj: 200`,
    * `restart: :no`, i.e. never restarted by the engine (the manager owns
      start/stop),
    * `domainname: local.hass.io` when a hostname + DNS are set.
  """

  @behaviour Vagus.Addon.Backend

  alias Vagus.Addon.Backend.Spec
  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Engine.{Container, ContainerSpec}

  @oom_score_adj 200
  @managed_label "supervisor_managed"
  @dns_suffix "local.hass.io"
  @secret_env ["SUPERVISOR_TOKEN", "HASSIO_TOKEN"]

  # Every callback's `opts` reach `Vagus.Runtime.Engine`, with a nested
  # `:engine_opts` flattened in. Steps passes its own opts to `stop`,
  # `remove` and `remove_image`; it calls `pull`, `create`, `start` and
  # `state` with none, so tests give those the engine directly.

  @impl true
  def pull(%Spec{image: image, platform: platform}, opts \\ []) do
    Engine.pull(image, [platform: platform] ++ engine(opts))
  end

  # A presence check that errors fails like a pull: the create would only
  # fail on an image that is not there, and the start's image retry covers a
  # check that times out or waits on a permit.
  @impl true
  def ensure_image(%Spec{image: image} = spec, opts \\ []) do
    case Engine.image_present?(image, engine(opts)) do
      true ->
        :ok

      false ->
        case pull(spec, opts) do
          :ok -> :ok
          {:error, reason} -> {:error, {:pull, reason}}
        end

      {:error, reason} ->
        {:error, {:image_check, reason}}
    end
  end

  @impl true
  def create(%Spec{} = spec, opts \\ []),
    do: Engine.create(to_container_spec(spec), engine(opts))

  @impl true
  def start(id, opts \\ []), do: Engine.start(id, engine(opts))

  @impl true
  def stop(id, opts \\ []) do
    case Keyword.pop(engine(opts), :timeout) do
      {nil, opts} -> Engine.stop(id, opts)
      {seconds, opts} -> Engine.stop(id, [timeout_s: seconds] ++ opts)
    end
  end

  @impl true
  def remove(id, opts \\ []), do: Engine.remove(id, engine(opts))

  @impl true
  def remove_image(image, opts \\ []), do: Engine.remove_image(image, engine(opts))

  @impl true
  def state(id, opts \\ []) do
    case Engine.inspect(id, engine(opts)) do
      {:ok, container} -> {:ok, if(Container.alive?(container), do: :running, else: :stopped)}
      {:error, :not_found} -> {:ok, :unknown}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_container_spec(Spec.t()) :: ContainerSpec.t()
  def to_container_spec(%Spec{} = spec) do
    bridge? = spec.network != :host
    env = env_pairs(spec.env)

    %ContainerSpec{
      name: spec.name,
      image: spec.image,
      cmd: spec.cmd,
      env: env,
      secret_env: for({name, _value} <- env, name in @secret_env, do: name),
      hostname: spec.hostname,
      domainname: domainname(spec),
      open_stdin: spec.open_stdin,
      labels: Map.put(spec.labels, @managed_label, ""),
      network: if(bridge?, do: {:bridge, spec.network_name}, else: :host),
      network_aliases: if(bridge? and is_binary(spec.hostname), do: [spec.hostname]),
      dns: spec.dns,
      dns_search: spec.dns_search,
      dns_options: spec.dns_options,
      extra_hosts: Enum.sort_by(spec.extra_hosts, fn {name, ip} -> "#{name}:#{ip}" end),
      mounts: Enum.map(spec.mounts, &mount/1),
      tmpfs: spec.tmpfs,
      # Additive only: these ALLOW nodes the engine's default device policy
      # denies. They cannot revoke anything, which is why an add-on granting
      # nothing still emits the key rather than omitting it.
      device_cgroup_rules: spec.device_cgroup_rules,
      cap_add: spec.cap_add,
      privileged: false,
      init: spec.init,
      oom_score_adj: @oom_score_adj,
      security_opt: security_opt(spec),
      restart: :no,
      ports: spec.ports,
      pid_mode: spec.pid_mode,
      uts_mode: spec.uts_mode
    }
  end

  defp engine(opts) do
    {nested, opts} = Keyword.pop(opts, :engine_opts, [])
    opts ++ nested
  end

  defp security_opt(spec) do
    apparmor = if spec.apparmor, do: ["apparmor=#{spec.apparmor}"], else: []
    Enum.uniq(["seccomp=unconfined" | apparmor])
  end

  defp domainname(%Spec{hostname: h, dns: dns}) when is_binary(h) and dns != [], do: @dns_suffix
  defp domainname(_), do: nil

  # `false` stays unset, so a mount asking for neither option renders
  # neither.
  defp mount(m) do
    %{
      type: :bind,
      source: m.source,
      target: m.target,
      read_only: Map.get(m, :read_only, false),
      propagation: Map.get(m, :propagation),
      read_only_non_recursive: if(Map.get(m, :read_only_non_recursive), do: true)
    }
  end

  # Sorted as the `K=V` strings they render to (`VAR1=` comes before `VAR=`,
  # unlike the bare keys).
  defp env_pairs(env), do: Enum.sort_by(env, fn {k, v} -> "#{k}=#{v}" end)
end
