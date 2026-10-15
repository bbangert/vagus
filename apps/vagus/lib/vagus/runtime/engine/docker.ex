defmodule Vagus.Runtime.Engine.Docker do
  @moduledoc """
  `Vagus.Runtime.Engine` over the Docker Engine API (`Vagus.Runtime.Docker`),
  which balena-engine speaks too.

  `:timeout_ms` becomes the client's `:deadline` instant, so one value
  bounds every request a callback makes; the remaining opts pass through,
  which is how `socket:` aims a call at another daemon.
  """

  @behaviour Vagus.Runtime.Engine

  import Kernel, except: [inspect: 2]

  alias Vagus.Runtime.Docker, as: Client
  alias Vagus.Runtime.Engine.{Container, ContainerSpec, NetworkSpec}
  alias Vagus.Runtime.Logs
  alias Vagus.Runtime.Stats

  # Docker reports "never" as Go's zero time rather than omitting it.
  @zero_time "0001-01-01T00:00:00Z"

  @states %{
    "created" => :created,
    "running" => :running,
    "paused" => :paused,
    "restarting" => :restarting,
    "removing" => :removing,
    "exited" => :exited,
    "dead" => :exited
  }

  @impl true
  def ready(opts) do
    opts = deadline(opts)

    case Client.ping(opts) do
      :ok -> :ok
      {:error, {:unexpected_status, status}} -> {:error, {:failed, :ready, status_detail(status)}}
      {:error, reason} -> {:error, error(:ready, reason)}
    end
  end

  @impl true
  def pull(image, opts) do
    case Client.pull_image(image, deadline(opts)) do
      :ok -> :ok
      {:error, {:pull_failed, {_status, body}}} -> {:error, {:pull_failed, message(body)}}
      {:error, {:pull_failed, detail}} -> {:error, {:pull_failed, detail}}
      {:error, reason} -> {:error, error(:pull, reason)}
    end
  end

  @impl true
  def image_present?(image, opts) do
    opts = deadline(opts)

    case Client.inspect_image(image, opts) do
      {:ok, _image} -> true
      {:error, {:http, 404, _}} -> false
      {:error, reason} -> {:error, error(:image_present?, reason)}
    end
  end

  @impl true
  def remove_image(image, opts) do
    opts = deadline(opts)

    case Client.remove_image(image, opts) do
      :ok -> :ok
      {:error, {:remove_image_failed, 409, _}} -> {:error, :in_use}
      {:error, reason} -> {:error, error(:remove_image, reason)}
    end
  end

  @impl true
  def create(%ContainerSpec{} = spec, opts) do
    opts = opts |> deadline() |> Keyword.put(:name, spec.name)

    case Client.create_container(render_container(spec), opts) do
      {:ok, id} ->
        {:ok, id}

      {:error, {:create_failed, 409, _}} ->
        {:error, :conflict}

      # A 404 also covers a missing network; only the message tells them apart.
      {:error, {:create_failed, 404, "No such image" <> _}} ->
        {:error, {:failed, :create, :image_not_found}}

      {:error, {:create_failed, 404, "network " <> rest} = reason} ->
        if String.ends_with?(rest, " not found"),
          do: {:error, {:failed, :create, :network_not_found}},
          else: {:error, error(:create, reason)}

      {:error, reason} ->
        {:error, error(:create, reason)}
    end
  end

  @impl true
  def start(name, opts), do: unit(:start, Client.start_container(name, deadline(opts)))

  @impl true
  def stop(name, opts), do: unit(:stop, Client.stop_container(name, grace(opts)))

  @impl true
  def restart(name, opts), do: unit(:restart, Client.restart_container(name, grace(opts)))

  @impl true
  def stop_all(names, timeout_s, opts) do
    # Stops run one after another, so the floor is every container's grace.
    opts =
      opts
      |> Keyword.put(:timeout_s, timeout_s)
      |> deadline(length(names) * grace_ms(timeout_s))

    {stopped, failed} =
      Enum.reduce(names, {[], []}, fn name, {stopped, failed} ->
        case stop(name, opts) do
          result when result in [:ok, {:error, :not_found}] -> {[name | stopped], failed}
          {:error, reason} -> {stopped, [{name, reason} | failed]}
        end
      end)

    {:ok, Enum.reverse(stopped), Enum.reverse(failed)}
  end

  @impl true
  def remove(name, opts) do
    opts = deadline(opts)

    case Client.remove_container(name, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, error(:remove, reason)}
    end
  end

  @impl true
  def inspect(name, opts) do
    opts = deadline(opts)

    case Client.inspect_container(name, opts) do
      {:ok, raw} -> {:ok, parse_inspect(raw)}
      {:error, reason} -> {:error, error(:inspect, reason)}
    end
  end

  @impl true
  def list(opts) do
    opts = deadline(opts)

    case Client.list_containers(opts) do
      {:ok, raw} -> {:ok, raw |> Enum.map(&parse_summary/1) |> by_prefix(opts[:name_prefix])}
      {:error, reason} -> {:error, error(:list, reason)}
    end
  end

  @impl true
  def logs(name, opts) do
    opts = deadline(opts)

    case Client.container_logs(name, opts) do
      {:ok, raw} -> {:ok, Logs.demux(raw)}
      {:error, reason} -> {:error, error(:logs, reason)}
    end
  end

  @impl true
  def follow_logs(name, owner, opts) do
    opts
    |> Keyword.take([:tail, :timestamps, :socket])
    |> Keyword.merge(owner: owner, ref: name)
    |> Logs.Follow.start_link()
  end

  @impl true
  def stats(name, opts) do
    opts = deadline(opts)

    case Client.stats(name, opts) do
      {:ok, raw} -> {:ok, Stats.compute(raw)}
      {:error, reason} -> {:error, error(:stats, reason)}
    end
  end

  @impl true
  def exec(name, argv, opts) do
    opts = deadline(opts)

    if Keyword.get(opts, :capture, true) do
      case Client.exec_capture(name, argv, opts) do
        {:ok, %{exit_code: code, output: raw}} ->
          {:ok, %{exit_code: code, output: Logs.demux(raw)}}

        {:error, reason} ->
          {:error, exec_error(reason)}
      end
    else
      case Client.exec(name, argv, opts) do
        :ok -> {:ok, %{exit_code: 0, output: ""}}
        {:error, {:exec, code}} -> {:ok, %{exit_code: code, output: ""}}
        {:error, reason} -> {:error, exec_error(reason)}
      end
    end
  end

  # The daemon schedules checks itself, so this returns its latest verdict.
  @impl true
  def healthcheck(name, opts) do
    case inspect(name, opts) do
      {:ok, %Container{healthcheck: nil}} -> {:error, :no_healthcheck}
      {:ok, %Container{health: nil}} -> {:error, :no_healthcheck}
      {:ok, %Container{health: health}} -> {:ok, health}
      {:error, {:failed, :inspect, detail}} -> {:error, {:failed, :healthcheck, detail}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ensure_network(%NetworkSpec{name: name} = spec, opts) do
    opts = deadline(opts)

    case Client.inspect_network(name, opts) do
      {:ok, _network} -> :ok
      {:error, {:http, 404, _}} -> create_network(spec, opts)
      {:error, reason} -> {:error, error(:ensure_network, reason)}
    end
  end

  defp create_network(spec, opts) do
    case Client.create_network(render_network(spec), opts) do
      {:ok, _id} -> :ok
      # Created by someone else between our inspect and create.
      {:error, :already_exists} -> :ok
      {:error, reason} -> {:error, error(:ensure_network, reason)}
    end
  end

  @impl true
  def event_source, do: __MODULE__.EventSource

  @doc "The Engine-API `POST /containers/create` body for `spec` (the name travels separately)."
  @spec render_container(ContainerSpec.t()) :: map()
  def render_container(%ContainerSpec{} = spec) do
    bridge = bridge_name(spec.network)

    %{"HostConfig" => host_config(spec, bridge)}
    |> put("Image", spec.image)
    |> put("Hostname", spec.hostname)
    |> put("Domainname", spec.domainname)
    |> put("Cmd", spec.cmd)
    |> put("Env", spec.env && Enum.map(spec.env, fn {k, v} -> "#{k}=#{v}" end))
    |> put("OpenStdin", spec.open_stdin)
    |> put("Labels", spec.labels)
    |> put("ExposedPorts", bridged(bridge, spec.ports, &Map.new(&1, fn {p, _} -> {p, %{}} end)))
    |> put("NetworkingConfig", bridged(bridge, spec.network_aliases, &endpoints(bridge, &1)))
  end

  @doc "The Engine-API `POST /networks/create` body for `spec`."
  @spec render_network(NetworkSpec.t()) :: map()
  def render_network(%NetworkSpec{driver: :bridge} = spec) do
    ipam =
      %{}
      |> put("Subnet", spec.subnet)
      |> put("Gateway", spec.gateway)
      |> put("IPRange", spec.ip_range)

    %{
      "Name" => spec.name,
      "Driver" => "bridge",
      "IPAM" => %{"Driver" => "default", "Config" => [ipam]}
    }
    |> put(
      "Options",
      spec.interface_name && %{"com.docker.network.bridge.name" => spec.interface_name}
    )
  end

  defp host_config(spec, bridge) do
    %{}
    |> put("NetworkMode", if(bridge, do: bridge, else: "host"))
    |> put("Privileged", spec.privileged)
    |> put("Init", spec.init)
    |> put("OomScoreAdj", spec.oom_score_adj)
    |> put("SecurityOpt", spec.security_opt)
    |> put("RestartPolicy", restart_policy(spec.restart))
    |> put(
      "ExtraHosts",
      spec.extra_hosts && Enum.map(spec.extra_hosts, fn {h, ip} -> "#{h}:#{ip}" end)
    )
    |> put("CapAdd", spec.cap_add)
    |> put("Dns", spec.dns)
    |> put("DnsSearch", spec.dns_search)
    |> put("DnsOptions", spec.dns_options)
    |> put("Mounts", spec.mounts && Enum.map(spec.mounts, &mount/1))
    |> put("Tmpfs", spec.tmpfs)
    |> put("DeviceCgroupRules", spec.device_cgroup_rules)
    |> put("PortBindings", bridged(bridge, spec.ports, &port_bindings/1))
    |> put("PidMode", spec.pid_mode)
    |> put("UTSMode", spec.uts_mode)
  end

  defp bridge_name({:bridge, name}), do: name
  defp bridge_name(:host), do: nil

  defp bridged(nil, _value, _render), do: nil
  defp bridged(_bridge, value, _render) when value in [nil, [], %{}], do: nil
  defp bridged(_bridge, value, render), do: render.(value)

  defp endpoints(net, aliases), do: %{"EndpointsConfig" => %{net => %{"Aliases" => aliases}}}

  defp port_bindings(ports),
    do: Map.new(ports, fn {port, host} -> {port, [%{"HostPort" => to_string(host)}]} end)

  defp restart_policy(nil), do: nil
  defp restart_policy(:no), do: %{"Name" => ""}
  defp restart_policy(:unless_stopped), do: %{"Name" => "unless-stopped"}

  defp mount(%{type: :volume} = m) do
    %{"Type" => "volume", "Source" => m.source, "Target" => m.target}
    |> put("ReadOnly", if(Map.get(m, :read_only), do: true))
  end

  defp mount(%{type: :bind} = m) do
    bind_options =
      %{}
      |> put("Propagation", Map.get(m, :propagation))
      |> put("ReadOnlyNonRecursive", if(Map.get(m, :read_only_non_recursive), do: true))

    %{
      "Type" => "bind",
      "Source" => m.source,
      "Target" => m.target,
      "ReadOnly" => Map.get(m, :read_only) || false
    }
    |> put("BindOptions", if(bind_options != %{}, do: bind_options))
  end

  defp parse_inspect(raw) do
    state = raw["State"] || %{}
    config = raw["Config"] || %{}
    status = state_atom(state["Status"])

    %Container{
      id: raw["Id"],
      name: trim_name(raw["Name"]),
      image: config["Image"],
      state: status,
      exit_code: if(status == :exited, do: state["ExitCode"]),
      health: health_atom(get_in(state, ["Health", "Status"])),
      labels: config["Labels"] || %{},
      env: parse_env(config["Env"]),
      ips: parse_ips(get_in(raw, ["NetworkSettings", "Networks"])),
      healthcheck: parse_healthcheck(config["Healthcheck"]),
      started_at: parse_time(state["StartedAt"]),
      finished_at: parse_time(state["FinishedAt"])
    }
  end

  defp parse_summary(raw) do
    status = state_atom(raw["State"])

    %Container{
      id: raw["Id"],
      name: raw["Names"] |> List.wrap() |> List.first() |> trim_name(),
      image: raw["Image"],
      state: status,
      exit_code: if(status == :exited, do: summary_exit_code(raw["Status"])),
      labels: raw["Labels"] || %{}
    }
  end

  defp by_prefix(containers, nil), do: containers

  defp by_prefix(containers, prefix),
    do: Enum.filter(containers, &(is_binary(&1.name) and String.starts_with?(&1.name, prefix)))

  defp trim_name(nil), do: nil
  defp trim_name(name), do: String.trim_leading(name, "/")

  defp state_atom(status), do: Map.get(@states, status, :unknown)

  defp health_atom("healthy"), do: :healthy
  defp health_atom("unhealthy"), do: :unhealthy
  defp health_atom("starting"), do: :starting
  defp health_atom(_none), do: nil

  defp summary_exit_code(status) do
    case Regex.run(~r/^Exited \((-?\d+)\)/, status || "") do
      [_, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  defp parse_env(nil), do: %{}

  defp parse_env(env) do
    Map.new(env, fn entry ->
      case String.split(entry, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  defp parse_ips(nil), do: %{}

  defp parse_ips(networks) do
    for {net, %{"IPAddress" => ip}} <- networks,
        is_binary(ip) and ip != "",
        into: %{},
        do: {net, ip}
  end

  defp parse_healthcheck(%{"Test" => [_ | _] = test} = hc) when test != ["NONE"] do
    %{
      test: test,
      interval_ms: ns_to_ms(hc["Interval"]),
      timeout_ms: ns_to_ms(hc["Timeout"]),
      start_period_ms: ns_to_ms(hc["StartPeriod"]),
      retries: hc["Retries"]
    }
  end

  defp parse_healthcheck(_absent), do: nil

  defp ns_to_ms(ns) when is_integer(ns), do: div(ns, 1_000_000)
  defp ns_to_ms(_missing), do: nil

  defp parse_time(@zero_time), do: nil

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_time(_missing), do: nil

  defp unit(_verb, :ok), do: :ok
  defp unit(verb, {:error, reason}), do: {:error, error(verb, reason)}

  defp exec_error({:exec_create_failed, 404, _}), do: :not_found
  defp exec_error(reason), do: error(:exec, reason)

  defp error(_verb, :deadline), do: :timeout
  defp error(_verb, :exec_timeout), do: :timeout
  defp error(_verb, %Mint.TransportError{reason: :timeout}), do: :timeout
  # The daemon went away mid-request (closed, reset, refused on reconnect).
  defp error(_verb, %Mint.TransportError{}), do: :unavailable
  defp error(_verb, {:connect, _reason}), do: :unavailable
  defp error(_verb, {:http, 404, _message}), do: :not_found
  defp error(_verb, {:http, 404}), do: :not_found
  defp error(verb, {:http, status}), do: {:failed, verb, status_detail(status)}
  defp error(verb, {_kind, status, message}) when is_integer(status), do: {:failed, verb, message}
  defp error(verb, %{__exception__: true} = e), do: {:failed, verb, Exception.message(e)}
  defp error(verb, reason), do: {:failed, verb, reason}

  defp status_detail(status), do: "engine answered #{status}"

  defp message(%{"message" => message}), do: message
  defp message(body) when is_binary(body), do: body
  defp message(body), do: Kernel.inspect(body)

  # An already-set `:deadline` (stop_all's shared instant) wins.
  defp deadline(opts, floor_ms \\ 0) do
    case Keyword.pop(opts, :timeout_ms) do
      {nil, opts} -> opts
      {ms, opts} -> Keyword.put_new(opts, :deadline, now_ms() + max(ms, floor_ms))
    end
  end

  # A deadline or receive budget shorter than the grace would abandon the
  # engine mid-kill: the daemon stays silent until the container is gone.
  defp grace(opts) do
    case Keyword.pop(opts, :timeout_s) do
      {nil, opts} ->
        deadline(opts)

      {seconds, opts} ->
        grace = grace_ms(seconds)

        opts
        |> Keyword.put(:timeout, seconds)
        # Never less patience than a request with no grace gets.
        |> Keyword.update(
          :recv_timeout,
          max(grace, Client.default_recv_timeout()),
          &max(&1, grace)
        )
        |> deadline(grace)
    end
  end

  defp grace_ms(seconds), do: seconds * 1000 + 10_000

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
