defmodule Vagus.Runtime.Engine.Podman do
  @moduledoc """
  `Vagus.Runtime.Engine` over the `podman` CLI, one process per call
  (`Vagus.Runtime.Podman.Cmd`), each under a `Vagus.Runtime.Host` permit.

  `:timeout_ms` bounds the permit wait and the command together, across
  every podman call a callback makes; without it each verb class has its
  own deadline (queries 15 s, lifecycle 60 s, exec 60 s, pull 1 h). Once a
  stop has its permit, the command still gets its grace plus 15 s, because
  podman only SIGKILLs the container once the grace is spent; without
  `timeout_s` that grace is podman's default 10 s. Adapter-specific opts:
  `host:` (the Host's name), `podman_bin:`, and for tests of the stop
  floor `default_stop_grace_s:` (podman's default, 10) and
  `stop_margin_ms:` (15 000).

  Names and image refs are checked before podman sees them. An image ref
  must be a registry reference: podman would also take `oci-archive:`,
  `dir:` and other transports, reading a host path an app's config named,
  and `create` imports such an archive even with `--pull=never`. Pulls go
  through `docker://` so only a registry is ever contacted.

  Idempotence comes from flags (`--ignore`, `rm -f -t 0`) rather than
  from parsing, except where podman has none.
  """

  @behaviour Vagus.Runtime.Engine

  import Kernel, except: [inspect: 2]

  alias Vagus.Runtime.Engine.{Container, ContainerSpec, NetworkSpec}
  alias Vagus.Runtime.Host
  alias Vagus.Runtime.Podman.{Cmd, Error}

  @query_ms 15_000
  @lifecycle_ms 60_000
  @exec_ms 60_000
  # A check's own default timeout (30 s) plus margin.
  @healthcheck_ms 35_000
  @pull_ms 3_600_000
  @stop_margin_ms 15_000
  # podman stop's own default grace when no `-t` is given.
  @default_grace_s 10
  @logs_cap 16 * 1_048_576
  @discard_cap 65_536
  # A first sample older than this is no base for a CPU delta.
  @stale_sample_ms 600_000

  # podman's create default set lacks these three, which Docker grants.
  @docker_caps ["AUDIT_WRITE", "MKNOD", "NET_RAW"]

  # Docker's default tmpfs options; podman's lack noexec and copy the image
  # dir's content up into the tmpfs.
  @tmpfs_defaults ["rw", "noexec", "nosuid", "nodev", "notmpcopyup"]
  @tmpfs_opposites %{
    "ro" => "rw",
    "exec" => "noexec",
    "suid" => "nosuid",
    "dev" => "nodev",
    "tmpcopyup" => "notmpcopyup"
  }

  @zero_time "0001-01-01T00:00:00Z"

  @name_re ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
  # distribution/reference's grammar: optional registry host[:port], path
  # components, then a tag and/or digest.
  @image_re ~r"""
  \A
  (?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)(?:\.(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?))*(?::\d+)?/)?
  [a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*
  (?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*
  (?::[\w][\w.-]{0,127})?
  (?:@[A-Za-z][A-Za-z0-9]*(?:[-_+.][A-Za-z][A-Za-z0-9]*)*:[0-9a-fA-F]{32,})?
  \z
  """x
  # A name and tag can spell one of these too (`oci:latest`); podman reads
  # them as transports.
  @transports ~w(containers-storage docker docker-archive docker-daemon dir oci oci-archive sif tarball)
  @port_key_re ~r/\A\d{1,5}(\/(tcp|udp|sctp))?\z/

  # `stopped` is podman's exited-but-not-cleaned-up state. 6.1.4 never
  # reports `restarting` (its field is a TODO); mapped for parity only.
  @states %{
    "restarting" => :restarting,
    "configured" => :created,
    "created" => :created,
    "initialized" => :created,
    "running" => :running,
    "paused" => :paused,
    "stopping" => :stopping,
    "stopped" => :exited,
    "exited" => :exited,
    "removing" => :removing
  }

  @impl true
  def ready(opts) do
    case Host.ready(opts[:host]) do
      :ok -> :ok
      {:error, :preparing} -> {:error, :unavailable}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, {:prep_failed, :unavailable}} -> {:error, :unavailable}
      {:error, {:prep_failed, {:failed, _verb, detail}}} -> {:error, {:failed, :ready, detail}}
      {:error, {:prep_failed, reason}} -> {:error, {:failed, :ready, reason}}
    end
  end

  @impl true
  def pull(image, opts) do
    platform = if p = opts[:platform], do: ["--platform", p], else: []
    args = ["pull", "--quiet" | platform] ++ ["--", "docker://" <> image]

    case valid_image(:pull, image) do
      :ok ->
        case run(:pull, args, opts, @pull_ms, &clear_spool_on_failure(&1, opts[:host])) do
          {:ok, _id} -> :ok
          {:exit, 125, out} -> {:error, {:pull_failed, registry_message(out)}}
          other -> unit(:pull, other)
        end

      {:error, {:failed, :pull, reason}} ->
        {:error, {:pull_failed, reason}}
    end
  end

  @impl true
  def image_present?(image, opts) do
    with :ok <- valid_image(:image_present?, image) do
      case run(:image_present?, ["image", "exists", "--", image], opts, @query_ms) do
        {:ok, _} -> true
        {:exit, 1, _} -> false
        other -> unit(:image_present?, other)
      end
    end
  end

  @impl true
  def remove_image(image, opts) do
    with :ok <- valid_image(:remove_image, image) do
      case run(:remove_image, ["rmi", "--ignore", "--", image], opts, @lifecycle_ms) do
        {:exit, 1, _} -> :ok
        other -> unit(:remove_image, other)
      end
    end
  end

  @impl true
  def create(%ContainerSpec{} = spec, opts) do
    secrets = for {k, v} <- spec.env || [], k in spec.secret_env, do: {k, v}

    with :ok <- validate(spec),
         {:ok, out} <-
           ok(
             :create,
             run(
               :create,
               render_create(spec, Host.log_config(opts[:host])),
               [env: secrets] ++ opts,
               @lifecycle_ms
             )
           ) do
      {:ok, out |> String.trim() |> String.split("\n") |> List.last()}
    end
  end

  @impl true
  def start(name, opts) do
    with :ok <- valid_name(:start, name),
         do: unit(:start, run(:start, ["start", "--", name], opts, @lifecycle_ms))
  end

  @impl true
  def stop(name, opts) do
    {t, floor} = grace(opts)
    opts = [floor_ms: floor] ++ with_deadline(opts, floor)

    with :ok <- valid_name(:stop, name) do
      case run(:stop, ["stop" | t] ++ ["--", name], opts, floor) do
        {:exit, _, out} = failed ->
          if paused_refusal?(out),
            do: unpause_then_stop(name, t, opts),
            else: unit(:stop, failed)

        other ->
          unit(:stop, other)
      end
    end
  end

  # podman refuses to stop a paused container; Docker unpauses it first.
  defp paused_refusal?(out), do: out =~ "paused" and out =~ "container state improper"

  defp unpause_then_stop(name, t, opts) do
    unpause_opts = Keyword.delete(opts, :floor_ms)

    with :ok <- unit(:stop, run(:stop, ["unpause", "--", name], unpause_opts, @lifecycle_ms)) do
      unit(:stop, run(:stop, ["stop" | t] ++ ["--", name], opts, @lifecycle_ms))
    end
  end

  @impl true
  def restart(name, opts) do
    {t, floor} = grace(opts)
    floor = floor + @lifecycle_ms
    opts = [floor_ms: floor] ++ with_deadline(opts, floor)

    with :ok <- valid_name(:restart, name),
         do: unit(:restart, run(:restart, ["restart" | t] ++ ["--", name], opts, floor))
  end

  @doc """
  One `podman stop` for every name, which podman runs concurrently, on the
  reserved shutdown permit so a full ops pool cannot hold up a shutdown.
  """
  @impl true
  def stop_all([], _timeout_s, _opts), do: {:ok, [], []}

  def stop_all(names, timeout_s, opts) do
    {t, floor} = grace(Keyword.put(opts, :timeout_s, timeout_s))
    opts = [floor_ms: floor, class: :shutdown] ++ with_deadline(opts, floor)
    {valid, invalid} = Enum.split_with(names, &(valid_name(:stop, &1) == :ok))
    bad = for name <- invalid, do: {name, {:failed, :stop, {:invalid_name, name}}}

    case valid != [] && run(:stop_all, ["stop", "--ignore" | t] ++ ["--" | valid], opts, floor) do
      false -> {:ok, [], bad}
      {:ok, _} -> {:ok, valid, bad}
      {:exit, _status, out} -> split_stopped(valid, out, Keyword.delete(opts, :floor_ms), bad)
      {:error, _} = error -> {:ok, [], Enum.map(valid, &{&1, stop_error(error)}) ++ bad}
    end
  end

  # podman prints each stopped name and skips (`--ignore`) an absent one, so
  # an unprinted name is either absent or failed; `exists` tells which.
  defp split_stopped(names, out, opts, bad) do
    printed = out |> String.split("\n", trim: true) |> MapSet.new()
    detail = Error.detail(out)

    Enum.reduce(Enum.reverse(names), {:ok, [], bad}, fn name, {:ok, stopped, failed} ->
      cond do
        name in printed -> {:ok, [name | stopped], failed}
        exists(name, opts) == {:error, :not_found} -> {:ok, [name | stopped], failed}
        true -> {:ok, stopped, [{name, {:failed, :stop, detail}} | failed]}
      end
    end)
  end

  defp stop_error({:error, {:failed, _verb, detail}}), do: {:failed, :stop, detail}
  defp stop_error({:error, reason}), do: reason

  defp exists(name, opts) do
    case run(:exists, ["container", "exists", "--", name], opts, @query_ms) do
      {:ok, _} -> :ok
      other -> unit(:exists, other)
    end
  end

  @impl true
  def remove(name, opts) do
    args =
      if Keyword.get(opts, :force, true),
        do: ["rm", "--force", "--ignore", "--time", "0", "--", name],
        else: ["rm", "--ignore", "--", name]

    with :ok <- valid_name(:remove, name) do
      case unit(:remove, run(:remove, args, opts, @lifecycle_ms)) do
        result when result in [:ok, {:error, :not_found}] ->
          Host.forget_sample(opts[:host], name)
          remove_log(Host.log_config(opts[:host]).dir, name)
          :ok

        other ->
          other
      end
    end
  end

  # conmon appends to a log file it finds, so a container recreated under
  # the same name would inherit the old one's lines; Docker's go with the
  # container. The name was checked, so the path stays inside `dir`; a
  # symlink there is removed, never followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_log(dir, name) do
    path = log_path(dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] -> File.rm(path)
      _ -> :ok
    end

    :ok
  end

  defp log_path(dir, name), do: Path.join(dir, name <> ".log")

  @impl true
  def inspect(name, opts) do
    with {:ok, raw} <- inspect_raw(name, opts), do: {:ok, parse_inspect(raw)}
  end

  defp inspect_raw(name, opts) do
    with :ok <- valid_name(:inspect, name),
         {:ok, out} <-
           ok(:inspect, run(:inspect, ["container", "inspect", "--", name], opts, @query_ms)),
         {:ok, [raw | _]} <- decode(:inspect, out) do
      {:ok, raw}
    else
      {:ok, []} -> {:error, :not_found}
      {:ok, _other} -> {:error, {:failed, :inspect, :bad_json}}
      {:error, _} = error -> error
    end
  end

  @doc false
  # What `LogFollow` tails, and the conmon whose exit ends the follow
  # (`ConmonPid` is absent once the container stops).
  @spec log_target(String.t(), keyword()) ::
          {:ok, %{path: String.t() | nil, conmon_pid: integer() | nil}} | {:error, term()}
  def log_target(name, opts) do
    with {:ok, raw} <- inspect_raw(name, opts) do
      running? = get_in(raw, ["State", "Running"]) == true

      {:ok,
       %{
         path: get_in(raw, ["HostConfig", "LogConfig", "Path"]),
         conmon_pid: if(running?, do: get_in(raw, ["State", "ConmonPid"]))
       }}
    end
  end

  # `ps` without `--all` hides paused containers, which Docker lists as live.
  @impl true
  def list(opts) do
    with {:ok, out} <- ok(:list, run(:list, ["ps", "--all", "--format", "json"], opts, @query_ms)),
         {:ok, raw} when is_list(raw) <- decode(:list, out) do
      containers = Enum.map(raw, &parse_summary/1)
      live = if opts[:all], do: containers, else: Enum.filter(containers, &Container.alive?/1)
      {:ok, by_prefix(live, opts[:name_prefix])}
    else
      {:ok, _other} -> {:error, {:failed, :list, :bad_json}}
      {:error, _} = error -> error
    end
  end

  # The log is the capped file on tmpfs `render_create/2` points conmon at:
  # what survives is the newest stretch up to the cap, as since boot.
  @impl true
  def logs(name, opts) do
    stamps = if opts[:timestamps], do: ["--timestamps"], else: []
    args = ["logs", "--tail", to_string(Keyword.get(opts, :tail, 100))] ++ stamps ++ ["--", name]

    with :ok <- valid_name(:logs, name),
         do: ok(:logs, run(:logs, args, [cap: @logs_cap] ++ opts, @query_ms))
  end

  @impl true
  def follow_logs(name, owner, opts) do
    {follow, engine_opts} = Keyword.split(opts, [:tail, :timestamps, :poll_ms])

    __MODULE__.LogFollow.start_link(
      [name: name, owner: owner, engine_opts: engine_opts] ++ follow
    )
  end

  @impl true
  def stats(name, opts) do
    args = [
      "stats",
      "--no-stream",
      "--no-reset",
      "--format",
      "{{json .ContainerStats}}",
      "--",
      name
    ]

    with :ok <- valid_name(:stats, name),
         {:ok, out} <- ok(:stats, run(:stats, args, opts, @query_ms)),
         {:ok, raw} when is_map(raw) <- decode(:stats, out) do
      {:ok, compute_stats(raw, opts[:host])}
    else
      {:ok, _other} -> {:error, {:failed, :stats, :bad_json}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def exec(name, argv, opts) do
    capture? = Keyword.get(opts, :capture, true)
    cap = if capture?, do: [], else: [cap: @discard_cap, truncate: true, discard_stdout: true]

    with :ok <- valid_name(:exec, name) do
      case run(:exec, ["exec", "--", name | argv], cap ++ opts, @exec_ms) do
        {:ok, out} -> {:ok, %{exit_code: 0, output: if(capture?, do: out, else: "")}}
        {:exit, status, out} -> exec_exit(status, out, capture?)
        other -> unit(:exec, other)
      end
    end
  end

  # Exit codes 125 and 255 are podman's own as well as a command's; only
  # podman's own texts tell them apart (255 is how 6.1.4 reports a
  # container that is not running).
  @exec_failures ~r/^Error: .*(no such container|container state improper)/m

  defp exec_exit(status, out, capture?) when status in [125, 255] do
    if out =~ @exec_failures,
      do: Error.classify(:exec, status, out),
      else: {:ok, %{exit_code: status, output: if(capture?, do: out, else: "")}}
  end

  defp exec_exit(status, out, capture?),
    do: {:ok, %{exit_code: status, output: if(capture?, do: out, else: "")}}

  @doc """
  Runs the check once. A pass is `:healthy`; otherwise the verdict is the
  stored `Health.Status`, because `healthcheck run` reports this one probe
  while the status honours the start period and the retry count.
  """
  @impl true
  def healthcheck(name, opts) do
    opts = with_deadline(opts, @healthcheck_ms)

    with :ok <- valid_name(:healthcheck, name) do
      healthcheck_run(name, opts)
    end
  end

  defp healthcheck_run(name, opts) do
    case run(:healthcheck, ["healthcheck", "run", "--", name], opts, @healthcheck_ms) do
      {:ok, _} ->
        {:ok, :healthy}

      {:exit, 1, _} ->
        case inspect(name, opts) do
          {:ok, %Container{health: nil}} -> {:error, :no_healthcheck}
          {:ok, %Container{health: health}} -> {:ok, health}
          {:error, {:failed, :inspect, detail}} -> {:error, {:failed, :healthcheck, detail}}
          {:error, _} = error -> error
        end

      {:exit, _status, out} = failed ->
        # A container that is not running has no health to report.
        if out =~ "has no defined healthcheck" or out =~ "is not running",
          do: {:error, :no_healthcheck},
          else: unit(:healthcheck, failed)

      other ->
        unit(:healthcheck, other)
    end
  end

  @impl true
  def ensure_network(%NetworkSpec{name: name} = spec, opts) do
    opts = with_deadline(opts, @lifecycle_ms)

    case run(:ensure_network, ["network", "exists", "--", name], opts, @query_ms) do
      {:ok, _} ->
        :ok

      {:exit, 1, _} ->
        unit(:ensure_network, run(:ensure_network, render_network(spec), opts, @lifecycle_ms))

      other ->
        unit(:ensure_network, other)
    end
  end

  @impl true
  def event_source, do: __MODULE__.EventSource

  @spec render_network(NetworkSpec.t()) :: [String.t()]
  def render_network(%NetworkSpec{driver: :bridge} = spec) do
    # No aardvark-dns on the board: a DNS-enabled network is broken without
    # it, and Vagus's own DNS serves the bridge.
    ["network", "create", "--driver", "bridge", "--disable-dns"] ++
      flag("--subnet", spec.subnet) ++
      flag("--gateway", spec.gateway) ++
      flag("--ip-range", spec.ip_range && ip_range(spec.ip_range)) ++
      flag("--interface-name", spec.interface_name) ++ ["--", spec.name]
  end

  # A CIDR range would start at network + 1; the start-end form keeps the
  # range's first address, as Docker hands it out.
  defp ip_range(range) do
    with [net, bits] <- String.split(range, "/"),
         {:ok, {a, b, c, d}} <- :inet.parse_ipv4strict_address(String.to_charlist(net)),
         {bits, ""} when bits in 0..32 <- Integer.parse(bits) do
      <<base::32>> = <<a, b, c, d>>
      mask = Bitwise.bsl(1, 32 - bits) - 1
      first = base |> Bitwise.band(Bitwise.bnot(mask)) |> Bitwise.band(0xFFFFFFFF)
      "#{ipv4(first)}-#{ipv4(Bitwise.bor(first, mask))}"
    else
      _ -> range
    end
  end

  defp ipv4(n) do
    <<a, b, c, d>> = <<n::32>>
    {a, b, c, d} |> :inet.ntoa() |> to_string()
  end

  @doc """
  Each value is its own element and the image follows `--`. Beyond the
  spec it pins what differs from Docker's defaults: Docker's capability
  set, unlimited pids, a private IPC namespace, no injected
  `container=podman` or proxy env, no pull on create, Docker's tmpfs
  options, and on a bridge an `/etc/hosts` built from nothing but the
  spec's entries. The log goes to `log.dir` (tmpfs: no SD writes, and
  nothing lost, as every container is recreated each boot), capped at
  `log.max_bytes`, which podman reads as a number of bytes.

  A `secret_env` entry renders as a bare `--env NAME`, which podman fills
  from its own environment, so the value stays off the argv. The spec must
  have passed `validate/1`.
  """
  @spec render_create(ContainerSpec.t(), %{dir: String.t(), max_bytes: pos_integer()}) ::
          [String.t()]
  def render_create(%ContainerSpec{} = spec, log \\ Host.log_config(nil)) do
    bridge = bridge_name(spec.network)
    pid_host? = spec.pid_mode == "host"

    # podman refuses a hostname inside the host's UTS namespace.
    # podman refuses an init binary outside a private PID namespace.
    # On tmpfs and capped; conmon starts the file over past the cap.
    ["create", "--name", spec.name] ++
      ~w(--pull=never --pids-limit=-1 --ipc=private --unsetenv=container --http-proxy=false) ++
      ["--log-driver", "k8s-file", "--log-opt", "path=" <> log_path(log.dir, spec.name)] ++
      ["--log-opt", "max-size=#{log.max_bytes}"] ++
      flag("--hostname", if(spec.uts_mode != "host", do: spec.hostname)) ++
      bool("--interactive", spec.open_stdin) ++
      env(spec.env, spec.secret_env) ++
      Enum.flat_map(Enum.sort(spec.labels || %{}), fn {k, v} -> ["--label", "#{k}=#{v}"] end) ++
      network(bridge, spec.network_aliases) ++
      dns(bridge, spec) ++
      hosts(bridge, spec.extra_hosts) ++
      Enum.flat_map(spec.mounts || [], &["--mount", mount(&1)]) ++
      Enum.flat_map(Enum.sort(spec.tmpfs || %{}), fn {dst, o} ->
        ["--tmpfs", "#{dst}:#{tmpfs(o)}"]
      end) ++
      many("--device-cgroup-rule", spec.device_cgroup_rules) ++
      many("--cap-add", caps(spec)) ++
      bool("--privileged", spec.privileged) ++
      bool("--init", spec.init == true and not pid_host?) ++
      flag("--oom-score-adj", spec.oom_score_adj && to_string(spec.oom_score_adj)) ++
      many("--security-opt", spec.security_opt) ++
      flag("--restart", restart(spec.restart)) ++
      if(bridge, do: publish(spec.ports), else: []) ++
      flag("--pid", spec.pid_mode) ++
      flag("--uts", spec.uts_mode) ++
      ["--", spec.image | spec.cmd || []]
  end

  defp env(nil, _secret), do: []

  defp env(env, secret) do
    Enum.flat_map(env, fn {k, v} ->
      if k in secret, do: ["--env", k], else: ["--env", "#{k}=#{v}"]
    end)
  end

  # Docker ignores these on the host network, where the container reads the
  # host's resolv.conf; podman would write them over it.
  defp dns(nil, _spec), do: []

  defp dns(_bridge, spec) do
    many("--dns", spec.dns) ++
      many("--dns-search", spec.dns_search) ++ many("--dns-option", spec.dns_options)
  end

  defp network(nil, _aliases), do: ["--network", "host"]
  defp network(bridge, aliases), do: ["--network", bridge] ++ many("--network-alias", aliases)

  # On a bridge podman would start /etc/hosts from the host's file; Docker
  # builds it fresh. On the host network both start from the host's.
  defp hosts(bridge, extra) do
    base = if bridge, do: ["--hosts-file=none"], else: []
    base ++ Enum.flat_map(extra || [], fn {h, ip} -> ["--add-host", "#{h}:#{ip}"] end)
  end

  # A privileged container has every capability already.
  defp caps(%ContainerSpec{privileged: true} = spec), do: spec.cap_add
  defp caps(spec), do: Enum.uniq((spec.cap_add || []) ++ @docker_caps)

  # podman 6.1.4 has no recursive read-only bind (`rro` is refused), so
  # `ro` is the top mount only: what `read_only_non_recursive` asks for,
  # and less than Docker 25's recursive `ReadOnly`. `bind-nonrecursive`
  # would also stop submounts being bound at all.
  defp mount(%{type: type} = m) do
    ro? = Map.get(m, :read_only) || Map.get(m, :read_only_non_recursive)
    propagation = if type == :bind, do: Map.get(m, :propagation)

    Enum.join(
      ["type=#{type}", "src=#{m.source}", "dst=#{m.target}"] ++
        if(ro?, do: ["ro=true"], else: []) ++
        if(propagation, do: ["bind-propagation=#{propagation}"], else: []),
      ","
    )
  end

  # Docker merges given options over its defaults, a given option replacing
  # its opposite.
  defp tmpfs(options) do
    given = String.split(options || "", ",", trim: true)
    replaced = Enum.map(given, &Map.get(@tmpfs_opposites, &1, &1))
    defaults = Enum.reject(@tmpfs_defaults, &(&1 in replaced or &1 in given))
    Enum.join(defaults ++ given, ",")
  end

  defp restart(nil), do: nil
  defp restart(:no), do: "no"
  defp restart(:unless_stopped), do: "unless-stopped"

  # A nil host port publishes on an ephemeral one, as Docker's empty
  # HostPort does.
  defp publish(ports) do
    ports
    |> Kernel.||(%{})
    |> Enum.sort()
    |> Enum.flat_map(fn
      {port, nil} -> ["--publish", port]
      {port, host} -> ["--publish", "#{host}:#{port}"]
    end)
  end

  defp bridge_name({:bridge, name}), do: name
  defp bridge_name(:host), do: nil

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, value]

  defp bool(name, true), do: [name]
  defp bool(_name, _), do: []

  defp many(_name, nil), do: []
  defp many(name, values), do: Enum.flat_map(values, &[name, &1])

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
      exit_code: if(status == :exited, do: raw["ExitCode"]),
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

  # podman's one-shot CPU figure is the average since the container
  # started, so the instantaneous one is the delta from the previous sample.
  defp compute_stats(raw, host) do
    usage = raw["MemUsage"] || 0
    limit = raw["MemLimit"] || 0
    network = raw["Network"] || %{}

    %{
      cpu_percent: cpu_percent(raw, host),
      # Already net of inactive_file: no second subtraction.
      memory_usage: usage,
      memory_limit: limit,
      memory_percent: percent(usage, limit),
      network_rx: network |> Map.values() |> Enum.map(&(&1["RxBytes"] || 0)) |> Enum.sum(),
      network_tx: network |> Map.values() |> Enum.map(&(&1["TxBytes"] || 0)) |> Enum.sum(),
      blk_read: raw["BlockInput"] || 0,
      blk_write: raw["BlockOutput"] || 0
    }
  end

  defp cpu_percent(%{"SystemNano" => sys} = raw, host) when is_integer(sys) and sys > 0 do
    name = raw["Name"]
    now = System.monotonic_time(:millisecond)
    sample = {raw["ContainerID"], raw["CPUNano"] || 0, sys, now}
    previous = Host.last_sample(host, name)
    :ok = Host.put_sample(host, name, sample)

    case {previous, sample} do
      {{id, cpu0, sys0, at}, {id, cpu, sys, _}}
      when cpu >= cpu0 and sys > sys0 and now - at < @stale_sample_ms ->
        Float.round((cpu - cpu0) / (sys - sys0) * 100.0, 2)

      _first_or_restarted ->
        Float.round((raw["CPU"] || 0) / 1, 2)
    end
  end

  defp cpu_percent(_not_running, _host), do: 0.0

  defp percent(_usage, 0), do: 0.0
  defp percent(usage, limit), do: Float.round(usage / limit * 100.0, 2)

  # The registry's own words are the last link of podman's error chain
  # ("initializing source …: reading manifest …: manifest unknown").
  defp registry_message(out) do
    line =
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "Error: "))
      |> List.last()

    case line do
      nil -> Error.detail(out)
      line -> line |> String.split(": ") |> List.last() |> String.trim()
    end
  end

  @doc false
  # The `--time` args and the command's floor once permitted: without
  # `timeout_s` podman applies its own default grace.
  @spec grace(keyword()) :: {[String.t()], pos_integer()}
  def grace(opts) do
    margin = Keyword.get(opts, :stop_margin_ms, @stop_margin_ms)

    case opts[:timeout_s] do
      nil -> {[], Keyword.get(opts, :default_stop_grace_s, @default_grace_s) * 1000 + margin}
      s -> {["--time", to_string(s)], s * 1000 + margin}
    end
  end

  defp class(:pull), do: :pull
  defp class(:stop_all), do: :shutdown
  defp class(_verb), do: :ops

  # One instant bounds every call a callback makes: the first sets it from
  # `timeout_ms`, else the verb's default.
  defp with_deadline(opts, default_ms) do
    Keyword.put_new_lazy(opts, :deadline, fn ->
      now_ms() + max(opts[:timeout_ms] || default_ms, opts[:floor_ms] || 0)
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A failed or killed pull leaves its layers in the spool. It runs under
  # the only pull permit, so no other pull's spool can be there.
  defp clear_spool_on_failure({:ok, _} = result, _host), do: result

  defp clear_spool_on_failure(result, host) do
    Host.clear_spool(host)
    result
  end

  # The permit wait counts against the deadline; the command then gets
  # what is left, but never less than `floor_ms` (a stop's grace).
  # `after_run` runs on the result while the permit is still held.
  defp run(verb, args, opts, default_ms, after_run \\ & &1) do
    deadline = with_deadline(opts, default_ms)[:deadline]
    host = opts[:host]
    floor = opts[:floor_ms] || 1

    cmd_opts =
      opts
      |> Keyword.take([:env, :cap, :truncate, :discard_stdout, :podman_bin])
      |> Keyword.put(:host, host)

    Host.with_permit(host, opts[:class] || class(verb), max(deadline - now_ms(), 0), fn ->
      left = max(deadline - now_ms(), floor)
      args |> Cmd.run(Keyword.put(cmd_opts, :timeout_ms, left)) |> after_run.()
    end)
  end

  @doc false
  # Every create input podman would read differently from Docker, rejected
  # here so `render_create/1` only ever sees a spec podman takes as meant.
  @spec validate(ContainerSpec.t()) :: :ok | {:error, {:failed, :create, term()}}
  def validate(%ContainerSpec{} = spec) do
    with :ok <- valid_name(:create, spec.name),
         :ok <- valid_image(:create, spec.image),
         :ok <- check(:invalid_restart, spec.restart, &(&1 in [nil, :no, :unless_stopped])),
         :ok <- each(:invalid_mount, spec.mounts, &valid_mount?/1) do
      each(:invalid_port, Map.keys(spec.ports || %{}), &Regex.match?(@port_key_re, &1))
    end
  end

  # A comma would end the `--mount` field; podman reads `--publish`'s key
  # as `[ip:][host:]port`, so a key could bind a host port of its own.
  defp valid_mount?(%{type: type, source: src, target: dst})
       when type in [:bind, :volume] and is_binary(src) and is_binary(dst),
       do: not String.contains?(src <> dst, ",")

  defp valid_mount?(_mount), do: false

  defp each(_tag, nil, _ok?), do: :ok

  defp each(tag, values, ok?) do
    case Enum.find(values, &(not ok?.(&1))) do
      nil -> :ok
      bad -> {:error, {:failed, :create, {tag, bad}}}
    end
  end

  defp check(tag, value, ok?),
    do: if(ok?.(value), do: :ok, else: {:error, {:failed, :create, {tag, value}}})

  defp valid_name(verb, name) when is_binary(name) do
    if Regex.match?(@name_re, name),
      do: :ok,
      else: {:error, {:failed, verb, {:invalid_name, name}}}
  end

  defp valid_name(verb, name), do: {:error, {:failed, verb, {:invalid_name, name}}}

  defp valid_image(verb, image) when is_binary(image) do
    transport? =
      case String.split(image, ":", parts: 2) do
        [prefix, _] -> prefix in @transports
        _ -> false
      end

    if Regex.match?(@image_re, image) and not transport?,
      do: :ok,
      else: {:error, {:failed, verb, {:invalid_image, image}}}
  end

  defp valid_image(verb, image), do: {:error, {:failed, verb, {:invalid_image, image}}}

  defp ok(_verb, {:ok, out}), do: {:ok, out}
  defp ok(verb, other), do: unit(verb, other)

  defp unit(_verb, {:ok, _out}), do: :ok
  defp unit(verb, {:exit, status, out}), do: Error.classify(verb, status, out)

  defp unit(_verb, {:error, reason}) when reason in [:timeout, :unavailable, :busy],
    do: {:error, reason}

  defp unit(_verb, {:error, :shutting_down}), do: {:error, :busy}
  defp unit(verb, {:error, reason}), do: {:error, {:failed, verb, reason}}

  defp decode(verb, out) do
    case Cmd.decode(out) do
      {:ok, term} -> {:ok, term}
      {:error, :bad_json} -> {:error, {:failed, verb, :bad_json}}
    end
  end
end
