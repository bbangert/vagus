defmodule Vagus.NFS do
  @moduledoc """
  The kernel NFS server, for targets that `nfsroot`-boot from a directory
  on the board. An agent drives it over distribution:

      :erpc.call(board, Vagus.NFS, :export, ["/data/vagus/nfs/t1", "10.42.0.0/24"])
      # the target mounts the `export_path` status/1 reports for it:
      # root=/dev/nfs nfsroot=<board>:/root/vagus/nfs/t1,vers=4,tcp ip=dhcp

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
  @sigkill_delay_ms 1_000
  @kill_budget_ms @sigkill_delay_ms + 1_000
  @outer_bound_ms @cmd_timeout_ms + @kill_budget_ms
  @cmd_budget_ms @outer_bound_ms + @kill_budget_ms
  # The longest call (a first export whose exportfs times out) runs modprobe,
  # mount, rpc.nfsd, exportfs and `rpc.nfsd 0`, then reconciles with etab:
  # up to five more, plus mountd starts and stops.
  @max_cmds_per_call 10
  @daemon_margin_ms 10_000
  @call_timeout_ms @cmd_budget_ms * @max_cmds_per_call + @daemon_margin_ms
  @stale_key {__MODULE__, :stale}
  # Linux's own limit on symlinks followed while resolving one path.
  @max_links 40

  @type export_entry :: %{
          path: String.t(),
          export_path: String.t(),
          client: String.t(),
          options: String.t()
        }
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
      exports: %{},
      unclean: nil
    }

    {:ok, state, {:continue, :adopt}}
  end

  @impl GenServer
  def handle_continue(:adopt, state), do: {:noreply, state |> reconcile() |> settle()}

  @impl GenServer
  def handle_call(msg, _from, state) do
    {:reply, reply, state} = command(msg, settle(state))
    {:reply, reply, settle(state)}
  end

  @impl GenServer
  def handle_info(msg, state) do
    {:noreply, state} = info(msg, settle(state))
    {:noreply, settle(state)}
  end

  defp command({:export, _path, _client, _options} = msg, %{unclean: reason} = state)
       when reason != nil do
    case retry_cleanup(state) do
      {:ok, state} -> command(msg, state)
      error -> error
    end
  end

  defp command({:unexport, path}, %{unclean: reason} = state) when reason != nil do
    tracked? = find_export(path, state) != nil

    case retry_cleanup(state) do
      {:ok, state} when tracked? -> {:reply, :ok, state}
      {:ok, state} -> {:reply, {:error, :not_exported}, state}
      error -> error
    end
  end

  defp command({:export, path, client, options}, state) do
    with {:ok, export_path} <- validate_path(path, state.root),
         {:ok, client} <- validate_client(client) do
      entry = %{
        path: Path.expand(path),
        export_path: export_path,
        client: client,
        options: options
      }

      # Keyed by the physical path, so either spelling of a path is the same export.
      case Map.fetch(state.exports, export_path) do
        {:ok, %{client: ^client, options: ^options}} -> {:reply, :ok, state}
        {:ok, other} -> {:reply, {:error, {:already_exported, other}}, state}
        :error -> add_export(entry, state)
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp command({:unexport, path}, state) do
    case find_export(path, state) do
      nil -> {:reply, {:error, :not_exported}, state}
      entry -> remove_export(entry, state)
    end
  end

  defp command(:status, state) do
    exports = state.exports |> Map.values() |> Enum.sort_by(& &1.export_path)
    status = %{running: state.mountd != nil, exports: exports}
    status = if state.unclean, do: Map.put(status, :cleanup_failed, state.unclean), else: status
    {:reply, status, state}
  end

  defp info({:EXIT, pid, reason}, %{mountd: pid} = state) do
    state = %{state | mountd: nil}

    if map_size(state.exports) == 0 do
      Logger.warning("Vagus.NFS: idle rpc.mountd exited: #{inspect(reason)}")
      {_result, state} = stop_server(state)
      {:noreply, state}
    else
      {:noreply, restart_mountd(reason, state)}
    end
  end

  defp info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # A timed-out command may still have changed the kernel's exports before
  # it was killed, so state is rebuilt from etab, which exportfs rewrites.
  # run/3 flags the timeout here because it is called deep in paths that do
  # not thread state back.
  defp settle(state) do
    if Process.delete(@stale_key) == true and state.unclean == nil,
      do: reconcile(state),
      else: state
  end

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

  # An export left in etab would be served again by the next mountd, so a
  # failed cleanup keeps the exports tracked and `unclean` blocks every start
  # until a retry succeeds.
  defp give_up(state) do
    unexported = run(state, "exportfs", ["-ua"])
    {stopped, state} = stop_server(state)
    state = %{state | restarts: []}

    case {unexported, stopped} do
      {:ok, :ok} -> %{state | exports: %{}, unclean: nil}
      {{:error, reason}, _} -> %{state | unclean: reason}
      {:ok, {:error, reason}} -> %{state | unclean: reason}
    end
  end

  defp retry_cleanup(state) do
    case give_up(state) do
      %{unclean: nil} = state -> {:ok, state}
      state -> {:reply, {:error, {:unclean, state.unclean}}, state}
    end
  end

  defp reconcile(state) do
    entries = state.state_dir |> read_etab() |> parse_etab()
    {keep, drop} = Enum.split_with(entries, &adoptable?(&1, state.root))

    rejected =
      drop
      |> Enum.map(&run(state, "exportfs", ["-u", spec(&1)]))
      |> Enum.find(:ok, &match?({:error, _}, &1))

    exports =
      Map.new(keep, fn entry ->
        case Map.fetch(state.exports, entry.export_path) do
          {:ok, known} -> {entry.export_path, %{entry | path: known.path}}
          :error -> {entry.export_path, entry}
        end
      end)

    case {rejected, keep} do
      # nfsd may have outlived the previous incarnation, still serving it.
      {{:error, reason}, _} ->
        Logger.error("Vagus.NFS: a rejected etab entry stayed exported: #{inspect(reason)}")
        {_result, state} = stop_server(state)
        %{state | exports: exports, unclean: reason}

      {:ok, []} ->
        stop_if_idle(%{state | exports: %{}})

      {:ok, keep} ->
        start_adopted(keep, exports, state)
    end
  end

  defp start_adopted(keep, exports, state) do
    case ensure_started(state) do
      {:ok, state} ->
        Logger.info("Vagus.NFS: adopted #{length(keep)} export(s) from etab")
        resync(%{state | exports: exports})

      error ->
        Logger.error("Vagus.NFS: adopting etab failed (#{inspect(error)}); dropping exports")

        state =
          case error do
            {:error, _reason, state} -> state
            {:error, _reason} -> state
          end

        give_up(%{state | exports: exports})
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

  # etab holds the physical path exportfs was given, so it must already be canonical.
  defp adoptable?(entry, root) do
    validate_path(entry.export_path, root) == {:ok, entry.export_path} and
      match?({:ok, _}, validate_client(entry.client))
  end

  # The directory may be gone by now, so this only matches spellings.
  defp find_export(path, state) do
    expanded = Path.expand(path)

    physical =
      with {:ok, canonical_root} <- canonical_root(state.root),
           {:ok, rel} <- relative_to_root(expanded, state.root, canonical_root) do
        Path.join(canonical_root, rel)
      else
        _ -> expanded
      end

    state.exports
    |> Map.values()
    |> Enum.find(&(&1.export_path == physical or &1.path == expanded))
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
      path = unescape(path)
      %{path: path, export_path: path, client: client, options: options(ro?, subtree?)}
    end
  end

  defp unescape(path) do
    Regex.replace(~r/\\([0-7]{3})/, path, fn _, oct -> <<String.to_integer(oct, 8)>> end)
  end

  defp add_export(entry, state) do
    case ensure_started(state) do
      {:ok, state} ->
        case run(state, "exportfs", ["-o", entry.options, spec(entry)]) do
          :ok ->
            {:reply, :ok, %{state | exports: Map.put(state.exports, entry.export_path, entry)}}

          error ->
            {:reply, error, stop_if_idle(state)}
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
        state = %{state | exports: Map.delete(state.exports, entry.export_path)}

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
      # NFSv2 is compiled out (`-N 2` errors) and the rootfs has no
      # /etc/services, so the port must be numeric; -V 4.0 keeps nfsroot's v4.0.
      argv = ["-N", "3", "-V", "4.0", "--no-udp", "-G", "10", "-p", "2049", "4"]

      case run(state, "rpc.nfsd", argv) do
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
      {_out, 0} ->
        :ok

      {out, 124} ->
        Process.put(@stale_key, true)
        {:error, {bin, args, out, 124}}

      {out, status} when is_integer(status) ->
        {:error, {bin, args, out, status}}

      {:error, reason} ->
        {:error, {bin, args, reason}}
    end
  end

  defp spec(entry), do: "#{entry.client}:#{entry.export_path}"

  defp options(ro?, subtree?) do
    subtree = if subtree?, do: "subtree_check", else: "no_subtree_check"
    Enum.join([if(ro?, do: "ro", else: "rw")] ++ @base_options ++ [subtree | @tail_options], ",")
  end

  # exportfs splits `client:path` at the first ':' (utils/exportfs/exportfs.c:334),
  # as does the target's `nfsroot=server:path`; whitespace and control bytes
  # come back octal-escaped from etab. Refusing them keeps every form of the
  # path unambiguous. Returns the physical path, which is what gets exported.
  defp validate_path(path, root) when is_binary(path) do
    if not String.valid?(path) or String.match?(path, ~r/[:\s\x00-\x1f\x7f]/u) do
      {:error, :invalid_path}
    else
      with {:ok, canonical_root} <- canonical_root(root),
           {:ok, rel} <- relative_to_root(Path.expand(path), root, canonical_root) do
        walk(canonical_root, Path.split(rel))
      end
    end
  end

  defp validate_path(_path, _root), do: {:error, :outside_root}

  # The root and its ancestors may be symlinks: on Nerves /data is a symlink
  # to /root, where the data partition is mounted. They are resolved, so the
  # confinement is checked against the physical directory, and a target
  # mounts that physical path because NFSv4 walks the server's real tree.
  defp canonical_root(root) do
    ["/" | parts] = root |> Path.expand() |> Path.split()

    case resolve("/", parts, @max_links) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _} -> {:error, :invalid_root}
    end
  end

  defp relative_to_root(expanded, root, canonical_root) do
    Enum.find_value([root, canonical_root], {:error, :outside_root}, fn prefix ->
      rel = String.replace_prefix(expanded, prefix <> "/", "")
      if rel != expanded and rel != "", do: {:ok, rel}
    end)
  end

  defp resolve(dir, [], _links), do: {:ok, dir}
  defp resolve(dir, ["." | rest], links), do: resolve(dir, rest, links)
  defp resolve(dir, [".." | rest], links), do: resolve(Path.dirname(dir), rest, links)

  # sobelow_skip ["Traversal.FileModule"]
  defp resolve(dir, [name | rest], links) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> resolve(path, rest, links)
      {:ok, %File.Stat{type: :symlink}} when links > 0 -> follow(dir, path, rest, links - 1)
      _ -> {:error, :invalid_root}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp follow(dir, link, rest, links) do
    case File.read_link(link) do
      {:ok, target} ->
        case Path.split(target) do
          ["/" | parts] -> resolve("/", parts ++ rest, links)
          parts -> resolve(dir, parts ++ rest, links)
        end

      {:error, _} ->
        {:error, :invalid_root}
    end
  end

  # Below the canonical root nothing is followed: a symlink there could point
  # anywhere.
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

  # Under muontrap, so a timed-out command is killed rather than left
  # running: closing a plain port only closes its pipes. The port is closed
  # without waiting for the child, so a timeout waits out the kill before
  # the caller reads etab. BoundedCall stays as the outer bound (MuonTrap's
  # own timeout has been seen not to fire, see `Vagus.Dist`); killing its
  # task closes the port, which kills the child too.
  defp default_cmd(bin, args) do
    fun = fn ->
      MuonTrap.cmd(bin, args,
        stderr_to_stdout: true,
        timeout: @cmd_timeout_ms,
        delay_to_sigkill: @sigkill_delay_ms
      )
    end

    case Vagus.BoundedCall.run(fun, @outer_bound_ms) do
      {out, status} when is_integer(status) ->
        {out, status}

      {out, :timeout} ->
        Process.sleep(@kill_budget_ms)
        {out, 124}

      {:error, :attempt_timeout} ->
        Process.sleep(@kill_budget_ms)
        {"#{bin}: no answer in #{@cmd_timeout_ms} ms", 124}

      {:error, {:exit, reason}} ->
        {"#{bin}: #{inspect(reason)}", 1}
    end
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
