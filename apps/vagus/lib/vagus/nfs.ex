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

  The export table lives only in this process. If it dies the next
  incarnation unexports everything the kernel still holds, so the
  orchestrator re-exports what it needs.

  Never starts on the appliance flavor (`Vagus.Flavor.agent?/0`).
  """

  use GenServer

  require Logger

  @default_root "/data/vagus/nfs"
  # exportfs reads its state directory only from /etc/nfs.conf, which the
  # read-only rootfs does not ship, so mountd and exportfs must both use the
  # compiled-in NFS_STATEDIR. It is under /run, so it is tmpfs.
  @default_state_dir "/run/nfs"
  @default_options ~w(sync no_root_squash no_subtree_check insecure)
  @cmd_timeout_ms 10_000
  # A start runs up to four bounded commands.
  @call_timeout_ms 60_000

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
  Exports `path` to `client_cidr` (an IPv4 address or CIDR). `ro: true`
  exports read-only. Exporting a path again with the same client and
  options is a no-op; with different ones it is `{:error, {:already_exported, entry}}`.
  """
  @spec export(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def export(path, client_cidr, opts \\ []) do
    call(opts, {:export, path, client_cidr, Keyword.get(opts, :ro, false)})
  end

  @spec unexport(String.t(), keyword()) :: :ok | {:error, term()}
  def unexport(path, opts \\ []), do: call(opts, {:unexport, path})

  @spec status(keyword()) :: status() | {:error, term()}
  def status(opts \\ []), do: call(opts, :status)

  # Dist callers get a value back, never an exit, whether the server is
  # absent (appliance flavor) or slow.
  defp call(opts, msg) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), msg, @call_timeout_ms)
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
      exports: %{}
    }

    {:ok, state, {:continue, :reset_stale}}
  end

  # A non-empty etab means a previous incarnation died with exports in the
  # kernel; drop them so the kernel matches the (empty) table here.
  @impl GenServer
  # sobelow_skip ["Traversal.FileModule"]
  def handle_continue(:reset_stale, state) do
    case File.read(Path.join(state.state_dir, "etab")) do
      {:ok, etab} when etab != "" ->
        Logger.warning("Vagus.NFS: dropping exports left by a previous instance")
        state.cmd.("exportfs", ["-ua"])
        state.cmd.("rpc.nfsd", ["0"])

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:export, path, client, ro?}, _from, state) do
    with {:ok, path} <- validate_path(path, state.root),
         {:ok, client} <- validate_client(client) do
      entry = %{path: path, client: client, options: options(ro?)}

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
    Logger.error("Vagus.NFS: rpc.mountd exited: #{inspect(reason)}")
    {:stop, {:mountd_exited, reason}, %{state | mountd: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

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
    case state.daemon.(:start, ["-F", "-N", "2", "-N", "3"]) do
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

  defp options(ro?), do: Enum.join([if(ro?, do: "ro", else: "rw") | @default_options], ",")

  # The leaf is lstat'ed so a symlink cannot stand in for a directory.
  defp validate_path(path, root) when is_binary(path) do
    path = Path.expand(path)

    cond do
      not String.starts_with?(path, root <> "/") -> {:error, :outside_root}
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)) -> {:ok, path}
      true -> {:error, :not_a_directory}
    end
  end

  defp validate_path(_path, _root), do: {:error, :outside_root}

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

  defp prefix(bits) do
    case Integer.parse(bits) do
      {n, ""} when n in 0..32 -> {:ok, n}
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
    GenServer.stop(pid)
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
