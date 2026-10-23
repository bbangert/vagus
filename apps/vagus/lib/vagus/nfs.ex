defmodule Vagus.NFS do
  @moduledoc """
  The kernel NFS server, for targets that `nfsroot`-boot from a directory
  on the board. An agent drives it over distribution:

      :erpc.call(board, Vagus.NFS, :export, ["/data/vagus/nfs/t1", "10.42.0.0/24"])
      # target cmdline: root=/dev/nfs nfsroot=<board>:/data/vagus/nfs/t1,vers=4,tcp ip=dhcp

  NFSv4 only: with v2/v3 off, `rpc.mountd` opens no RPC listeners and
  nothing needs rpcbind or statd, so mountd remains the only daemon (the
  kernel's export-cache upcalls still go through it). The first export
  starts the server; removing the last one stops it.

  `rpc.nfsd` could bind with `-H`, but lab interfaces come and go at
  runtime and their addresses are not known at start, so knfsd listens on
  every interface and each export's client CIDR is the access control.

  Exports outlive this process: the kernel and `etab` keep them, a new
  incarnation adopts `etab`, and a crashed mountd is restarted, so an
  nfsroot target keeps its root. Only a mountd that keeps crashing makes
  the server give up and drop every export.

  Never starts on the appliance flavor (`Vagus.Flavor.agent?/0`).
  """

  use GenServer

  require Logger

  @default_root "/data/vagus/nfs"
  # exportfs reads its state directory only from /etc/nfs.conf, which the
  # read-only rootfs does not ship, so mountd and exportfs must both use the
  # compiled-in NFS_STATEDIR. It is under /run, so it is tmpfs.
  @default_state_dir "/run/nfs"
  # nfsroot targets run as root, so squashing would make their root
  # filesystem unwritable.
  # `insecure`: target userspace (and some bootloaders) mount from
  # unprivileged source ports.
  @base_options ~w(sync no_root_squash)
  @tail_options ~w(insecure)
  @mountd_args ["-F", "-N", "2", "-N", "3"]
  @max_restarts 3
  @restart_window_ms 60_000
  @cmd_timeout_ms 10_000
  # The longest call (a first export whose exportfs fails) runs modprobe,
  # mount, rpc.nfsd, exportfs and `rpc.nfsd 0`, each bounded, plus a mountd
  # start and stop.
  @max_cmds_per_call 5
  @daemon_margin_ms 10_000
  @call_timeout_ms @cmd_timeout_ms * @max_cmds_per_call + @daemon_margin_ms

  @type export_entry :: %{path: String.t(), client: String.t(), options: String.t()}
  @type status :: %{running: boolean(), exports: [export_entry()]}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &Vagus.Flavor.agent?/0) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc """
  Exports `path` to `client_cidr` (an IPv4 address or a CIDR of /8 or
  narrower). `ro: true` exports read-only; `subtree_check: false` drops
  the subtree check, which otherwise stops a client from forging a handle
  outside the export. Exporting a path again with the same client and
  options is a no-op; with different ones it is `{:error, {:already_exported, entry}}`.
  """
  @spec export(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def export(path, client_cidr, opts \\ []) do
    ro? = Keyword.get(opts, :ro, false)
    subtree? = Keyword.get(opts, :subtree_check, true)
    call(opts, {:export, path, client_cidr, options(ro?, subtree?)})
  end

  @spec unexport(String.t(), keyword()) :: :ok | {:error, term()}
  def unexport(path, opts \\ []), do: call(opts, {:unexport, path})

  @spec status(keyword()) :: status() | {:error, term()}
  def status(opts \\ []), do: call(opts, :status)

  # Dist callers get a value back, never an exit, whether the server is
  # absent (appliance flavor) or slow.
  defp call(opts, msg) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      msg,
      Keyword.get(opts, :timeout, @call_timeout_ms)
    )
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {{:nodedown, _}, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl GenServer
  def init(opts) do
    # MuonTrap.Daemon is linked; its exit arrives as a message, and the
    # bounded command runner's tasks exit through here too.
    Process.flag(:trap_exit, true)

    state = %{
      root: opts |> Keyword.get(:root, @default_root) |> Path.expand(),
      state_dir: Keyword.get(opts, :state_dir, @default_state_dir),
      cmd: Keyword.get(opts, :cmd, &default_cmd/2),
      daemon: Keyword.get(opts, :daemon, &default_daemon/2),
      nfsd_mounted?: Keyword.get(opts, :nfsd_mounted?, &nfsd_mounted?/0),
      mountd: nil,
      restarts: [],
      exports: %{}
    }

    {:ok, state, {:continue, :adopt}}
  end

  @impl GenServer
  def handle_continue(:adopt, state) do
    case state.state_dir |> read_etab() |> parse_etab() do
      [] -> {:noreply, state}
      entries -> {:noreply, adopt(entries, state)}
    end
  end

  @impl GenServer
  def handle_call({:export, path, client, options}, _from, state) do
    with {:ok, path} <- validate_path(path, state.root),
         {:ok, client} <- validate_client(client) do
      entry = %{path: path, client: client, options: options}

      case Map.fetch(state.exports, path) do
        {:ok, ^entry} -> {:reply, :ok, state}
        {:ok, other} -> {:reply, {:error, {:already_exported, other}}, state}
        :error -> add_export(entry, state)
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:unexport, path}, _from, state) do
    case Map.fetch(state.exports, Path.expand(path)) do
      {:ok, entry} -> remove_export(entry, state)
      :error -> {:reply, {:error, :not_exported}, state}
    end
  end

  def handle_call(:status, _from, state) do
    exports = state.exports |> Map.values() |> Enum.sort_by(& &1.path)
    {:reply, %{running: state.mountd != nil, exports: exports}, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{mountd: pid} = state) do
    state = %{state | mountd: nil}

    if map_size(state.exports) == 0 do
      Logger.warning("Vagus.NFS: idle rpc.mountd exited: #{inspect(reason)}")
      {_result, state} = stop_server(state)
      {:noreply, state}
    else
      {:noreply, restart_mountd(reason, state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The kernel export table survives mountd; only its upcalls fail until a
  # new mountd (which re-reads etab) is up.
  defp restart_mountd(reason, state) do
    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(state.restarts, &(now - &1 < @restart_window_ms))

    with true <- length(recent) < @max_restarts,
         {:ok, pid} <- start_mountd(state) do
      Logger.warning("Vagus.NFS: rpc.mountd exited (#{inspect(reason)}); restarted it")
      %{state | mountd: pid, restarts: [now | recent]}
    else
      _ ->
        Logger.error("Vagus.NFS: rpc.mountd keeps exiting (#{inspect(reason)}); dropping exports")
        give_up(state)
    end
  end

  defp give_up(state) do
    run(state, "exportfs", ["-ua"])
    {_result, state} = stop_server(state)
    %{state | exports: %{}, restarts: []}
  end

  defp adopt(entries, state) do
    {keep, drop} = Enum.split_with(entries, &adoptable?(&1, state.root))
    Enum.each(drop, &run(state, "exportfs", ["-u", spec(&1)]))

    case keep do
      [] -> state
      keep -> start_adopted(keep, state)
    end
  end

  defp start_adopted(keep, state) do
    case ensure_started(state) do
      {:ok, state} ->
        Logger.info("Vagus.NFS: adopted #{length(keep)} export(s) from etab")
        resync(%{state | exports: Map.new(keep, &{&1.path, &1})})

      error ->
        Logger.error("Vagus.NFS: adopting etab failed (#{inspect(error)}); dropping exports")
        state = with {:error, _reason, state} <- error, do: state
        give_up(state)
    end
  end

  # `-f` flushes the kernel's export cache so its next upcalls are answered
  # from etab; `-r` would skip etab and rebuild from the absent /etc/exports,
  # unexporting everything. A failed flush only leaves stale cache entries.
  defp resync(state) do
    with {:error, reason} <- run(state, "exportfs", ["-f"]) do
      Logger.warning("Vagus.NFS: export cache flush failed: #{inspect(reason)}")
    end

    state
  end

  defp adoptable?(entry, root) do
    match?({:ok, _}, validate_path(entry.path, root)) and
      match?({:ok, _}, validate_client(entry.client))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_etab(dir) do
    case File.read(Path.join(dir, "etab")) do
      {:ok, etab} -> etab
      {:error, _} -> ""
    end
  end

  # putexportent() in nfs-utils support/nfs/exports.c writes
  # `<path>\t<client>(<flag>,...)`, octal-escaping odd path bytes as \ooo.
  defp parse_etab(etab) do
    for line <- String.split(etab, "\n", trim: true),
        [path, rest] <- [String.split(line, "\t", parts: 2)],
        [client, flags] <- [String.split(rest, "(", parts: 2)] do
      flags = flags |> String.trim_trailing(")") |> String.split(",")
      ro? = "ro" in flags
      subtree? = "subtree_check" in flags
      %{path: unescape(path), client: client, options: options(ro?, subtree?)}
    end
  end

  defp unescape(path) do
    Regex.replace(~r/\\([0-7]{3})/, path, fn _, oct -> <<String.to_integer(oct, 8)>> end)
  end

  defp add_export(entry, state) do
    case ensure_started(state) do
      {:ok, state} ->
        case run(state, "exportfs", ["-o", entry.options, spec(entry)]) do
          :ok -> {:reply, :ok, %{state | exports: Map.put(state.exports, entry.path, entry)}}
          error -> {:reply, error, stop_if_idle(state)}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp remove_export(entry, state) do
    case run(state, "exportfs", ["-u", spec(entry)]) do
      :ok ->
        state = %{state | exports: Map.delete(state.exports, entry.path)}

        if map_size(state.exports) == 0 do
          {result, state} = stop_server(state)
          {:reply, result, state}
        else
          {:reply, :ok, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp ensure_started(%{mountd: pid} = state) when pid != nil, do: {:ok, state}

  defp ensure_started(state) do
    with :ok <- run(state, "modprobe", ["nfsd"]),
         :ok <- mount_nfsd(state),
         :ok <- prepare_state_dir(state.state_dir),
         {:ok, pid} <- start_mountd(state) do
      state = %{state | mountd: pid}

      # Grace exists for clients reclaiming state across a server restart;
      # nothing here persists client state, so the 90 s default would only
      # stall every target's first OPENs. 10 is the kernel minimum.
      case run(state, "rpc.nfsd", ["-N", "2", "-N", "3", "--no-udp", "-G", "10", "4"]) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason, stop_mountd(state)}
      end
    end
  end

  defp stop_if_idle(state) when map_size(state.exports) == 0 and state.mountd != nil do
    {_result, state} = stop_server(state)
    state
  end

  defp stop_if_idle(state), do: state

  # mountd is stopped even if the threads would not stop: a later start's
  # `rpc.nfsd` finds the server in use and only resets the thread count.
  defp stop_server(state) do
    result = run(state, "rpc.nfsd", ["0"])
    {result, stop_mountd(state)}
  end

  defp stop_mountd(%{mountd: nil} = state), do: state

  defp stop_mountd(state) do
    state.daemon.(:stop, state.mountd)
    %{state | mountd: nil}
  end

  defp start_mountd(state) do
    case state.daemon.(:start, @mountd_args) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {"rpc.mountd", reason}}
    end
  end

  defp mount_nfsd(state) do
    if state.nfsd_mounted?.() do
      :ok
    else
      run(state, "mount", ["-t", "nfsd", "nfsd", "/proc/fs/nfsd"])
    end
  end

  # mountd reads etab at start and keeps rmtab here; both must exist.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_state_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- touch(Path.join(dir, "etab")) do
      touch(Path.join(dir, "rmtab"))
    else
      {:error, reason} -> {:error, {:state_dir, dir, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp touch(path) do
    case File.open(path, [:append]) do
      {:ok, io} -> File.close(io)
      error -> error
    end
  end

  defp run(state, bin, args) do
    case state.cmd.(bin, args) do
      {_out, 0} -> :ok
      {out, status} when is_integer(status) -> {:error, {bin, args, out, status}}
      {:error, reason} -> {:error, {bin, args, reason}}
    end
  end

  defp spec(entry), do: "#{entry.client}:#{entry.path}"

  defp options(ro?, subtree?) do
    subtree = if subtree?, do: "subtree_check", else: "no_subtree_check"
    Enum.join([if(ro?, do: "ro", else: "rw")] ++ @base_options ++ [subtree | @tail_options], ",")
  end

  # exportfs splits `client:path` at the first ':' (utils/exportfs/exportfs.c:334),
  # as does the target's `nfsroot=server:path`; whitespace and control bytes
  # come back octal-escaped from etab. Refusing them keeps every form of the
  # path unambiguous.
  defp validate_path(path, root) when is_binary(path) do
    cond do
      not String.valid?(path) or String.match?(path, ~r/[:\s\x00-\x1f\x7f]/u) ->
        {:error, :invalid_path}

      not String.starts_with?(Path.expand(path), root <> "/") ->
        {:error, :outside_root}

      true ->
        walk(root, Path.expand(path) |> Path.relative_to(root) |> Path.split())
    end
  end

  defp validate_path(_path, _root), do: {:error, :outside_root}

  # Every component is lstat'ed: a symlink anywhere below the root could
  # point the export outside it.
  defp walk(dir, []), do: {:ok, dir}

  defp walk(dir, [name | rest]) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      _ -> {:error, :not_a_directory}
    end
  end

  defp validate_client(client) when is_binary(client) do
    case String.split(client, "/") do
      [addr] ->
        parse_ipv4(addr)

      [addr, bits] ->
        with {:ok, ip} <- parse_ipv4(addr), {:ok, n} <- prefix(bits), do: {:ok, "#{ip}/#{n}"}

      _ ->
        {:error, :invalid_client}
    end
  end

  defp validate_client(_client), do: {:error, :invalid_client}

  defp parse_ipv4(addr) do
    case :inet.parse_ipv4strict_address(String.to_charlist(addr)) do
      {:ok, ip} -> {:ok, ip |> :inet.ntoa() |> to_string()}
      {:error, _} -> {:error, :invalid_client}
    end
  end

  # Anything wider than /8 is close enough to "everyone" to be a mistake.
  defp prefix(bits) do
    case Integer.parse(bits) do
      {n, ""} when n in 8..32 -> {:ok, n}
      _ -> {:error, :invalid_client}
    end
  end

  defp default_cmd(bin, args) do
    Vagus.BoundedCall.run(fn -> Vagus.Host.Cmd.run(bin, args) end, @cmd_timeout_ms)
  end

  # A missing binary fails the daemon's init, so this returns {:error, _}.
  defp default_daemon(:start, args) do
    MuonTrap.Daemon.start_link("rpc.mountd", args,
      log_output: :info,
      log_prefix: "rpc.mountd: ",
      stderr_to_stdout: true
    )
  end

  defp default_daemon(:stop, pid) do
    GenServer.stop(pid, :normal, @cmd_timeout_ms)
  catch
    :exit, _ -> :ok
  end

  defp nfsd_mounted? do
    case File.read("/proc/mounts") do
      {:ok, mounts} -> String.contains?(mounts, " /proc/fs/nfsd nfsd ")
      {:error, _} -> false
    end
  end
end
