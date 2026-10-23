defmodule Vagus.Dist do
  @moduledoc """
  Runtime Erlang distribution for test and diagnostic work, on request only.

  > #### Test boards only {: .warning}
  >
  > This is not for a board anyone depends on. Enabling it opens an
  > unauthenticated-root-equivalent surface on the LAN segment. A failed
  > `enable/0` stops distribution and raises; **reboot the board** rather than
  > reasoning about what a half-finished attempt left behind.

  `enable/0` starts distribution and returns the node, cookie and port range.
  Nothing is enabled until someone asks (on the agent-dev-board flavor, boot
  does: `Vagus.App.Gates.dist/1`), and a reboot turns it back off — there
  is no gate file, no config flag and no supervised process, so there is also no
  `disable/0` that has to stop a live node without stranding it under a secret
  it has already deleted.

  The session is recorded in the `:vagus_dist` ETS table, created at application
  start and seeded `:not_requested`. Repeat calls return the same node and
  cookie instead of starting distribution twice. It is memory only — dropped by
  a reboot, and by a `:vagus` restart, which is why `enable/0` can meet a live
  node with no record and has to recover.

  The listener binds `0.0.0.0` and the cookie is the only control. Ports are
  pinned to 9100-9105 so the range is firewallable at the LAN edge. Treat an
  enabled board as an unauthenticated root shell open to its LAN segment, and
  reboot it when the work is done.

  ## Runbook

      iex> Vagus.Dist.enable()
      {:ok, %{node: :"vagus@192.168.2.58", cookie: "a1b2c3...", ports: 9100..9105}}

  Run it over **SSH**, never the local console: this repo documents that every
  add-on can read `/dev/pts/0`, so a cookie printed there is disclosed to all of
  them.

  Then, from the dev host — the node name is a bare IPv4 longname, no DNS:

      iex --name agent@<your-host-ip> --cookie a1b2c3... -S mix
      iex> Node.connect(:"vagus@192.168.2.58")

  Wrap bulk or long work in `run/1`, on the board side of the call:

      iex> :erpc.call(board, Vagus.Dist, :run, [fn -> collect_everything() end], :infinity)
  """

  require Logger

  @port_min 9100
  @port_max 9105
  @table :vagus_dist
  @session_key :session
  # Under the boot gate's 10 s `gate_timeout`, so the gate answers before it
  # is killed.
  @wait_ms 5_000
  # A plain directory on the `/run` tmpfs, like the rest of `/run/vagus`
  # (`Vagus.Runtime.Host` only makes that one 0700; its own tmpfs is the logs
  # subdirectory). Gone at reboot with the session it describes.
  @export_dir "/run/vagus/dist"
  # The orchestrator image runs `claude` and the `vagus` CLI as its `agent`
  # user, gid 1000, and rootful podman maps ids 1:1: the group is what lets
  # that user read the read-only bind.
  @agent_gid 1000

  @type session :: %{node: node(), cookie: String.t(), ports: Range.t()}

  @doc """
  Mints a cookie, brings the node up, and returns what you need to connect.

  Idempotent: the first caller claims the `:vagus_dist` row atomically and every
  later call hands back that same session without touching `net_kernel` again.
  A caller that arrives while a claim is in flight gets `{:error, :starting}`
  rather than racing it.

  The bring-up runs in a process of its own under `Vagus.TaskSupervisor`, which
  the claim names (`{:starting, pid}`). The caller waits up to `:wait_ms`
  (5 s) for it and otherwise answers `{:error, :starting}` while it runs on, so
  a caller killed on a deadline, as a boot gate is, cannot cut a bring-up off
  between `net_kernel` starting and the cookie being ours. A claim whose
  process is dead is taken over by the next caller, which meets the node, if
  it came up, through the `already_started` recovery.

  Raises if bring-up fails, having stopped distribution first. Reboot rather
  than retrying into a state nobody has reasoned about. The one exception is
  `{:error, :no_address}`: it is known before anything starts, and at boot
  the LAN lease can simply be late, so it is answered and the claim released.
  """
  @spec enable(keyword()) :: {:ok, session()} | {:error, :starting | :node_gone | :no_address}
  def enable(opts \\ []) do
    {wait_ms, opts} = Keyword.pop(opts, :wait_ms, @wait_ms)
    system = system(opts)

    task =
      Task.Supervisor.async_nolink(Vagus.TaskSupervisor, fn -> claim_and_bring_up(system) end)

    case Task.yield(task, wait_ms) || Task.ignore(task) do
      {:ok, {:raised, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
      {:ok, result} -> result
      # Killed from outside: its claim names a dead pid, which the next call takes over.
      {:exit, _reason} -> {:error, :starting}
      nil -> {:error, :starting}
    end
  end

  # Everything is caught so the caller, not this process, raises: a crash
  # here would surface as an exit, which the boot gate retries.
  defp claim_and_bring_up(system) do
    case system.session_claim_fun.(self()) do
      :claimed ->
        bring_up(system)

      :starting ->
        {:error, :starting}

      # A record with no live node behind it is corruption — only a deliberate
      # `:net_kernel.stop/0` produces it — and handing back a session whose
      # listener is gone would send an operator to a dead port.
      {:recorded, session} ->
        if system.alive_fun.(), do: {:ok, session}, else: {:error, :node_gone}
    end
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  @doc false
  # What a claim attempt by `claimant` makes of the row; `:take` means it may
  # replace the row with its own `{:starting, claimant}`. Shared with the
  # tests' fake table so the eviction rule they exercise is this one.
  @spec claim_decision(term()) :: :take | :starting | {:recorded, session()}
  def claim_decision(:not_requested), do: :take
  def claim_decision({:starting, pid}), do: if(Process.alive?(pid), do: :starting, else: :take)
  def claim_decision(session), do: {:recorded, session}

  @doc false
  @spec agent_gid() :: non_neg_integer()
  def agent_gid, do: @agent_gid

  @doc """
  Writes the session's node and cookie, and nothing else, to `node.json` in
  `/run/vagus/dist` (`:dir`), for the agent-dev-board's orchestrator app,
  which mounts that directory read-only and connects back. `:temp_suffix`
  names the temp file (tests).

  The directory is 0750 and the file 0640, both root and group 1000 (`:gid`),
  the image's `agent` user. The file's mode and group are set before the
  cookie is written, then it is renamed into place, so a reader never sees a
  partial file or one readable beyond that group. Nothing here logs: the
  error carries only the reason.
  """
  @spec export(session(), keyword()) :: :ok | {:error, {:export, File.posix()}}
  # sobelow_skip ["Traversal.FileModule"]
  def export(%{node: node, cookie: cookie}, opts \\ []) do
    dir = Keyword.get(opts, :dir, @export_dir)
    gid = Keyword.get(opts, :gid, @agent_gid)
    suffix = Keyword.get(opts, :temp_suffix, &temp_suffix/0)
    json = Jason.encode!(%{node: Atom.to_string(node), cookie: cookie})

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o750),
         :ok <- File.chgrp(dir, gid),
         {:ok, tmp} <- write_temp(dir, json, gid, suffix, 2),
         :ok <- rename_or_remove(tmp, Path.join(dir, "node.json")) do
      :ok
    else
      {:error, reason} -> {:error, {:export, reason}}
    end
  end

  # Random, not `System.unique_integer/1`, which restarts with the VM: a temp
  # file a killed export left on this tmpfs could otherwise be named again.
  # One `:eexist` is removed and retried, so a leftover never halts a boot.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_temp(dir, json, gid, suffix, tries) do
    tmp = Path.join(dir, ".node.json." <> suffix.())

    case write_private(tmp, json, gid) do
      :ok ->
        {:ok, tmp}

      {:error, :eexist} when tries > 1 ->
        File.rm(tmp)
        write_temp(dir, json, gid, suffix, tries - 1)

      {:error, _reason} = error ->
        File.rm(tmp)
        error
    end
  end

  defp temp_suffix, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # sobelow_skip ["Traversal.FileModule"]
  defp rename_or_remove(tmp, path) do
    with {:error, _reason} = error <- File.rename(tmp, path) do
      File.rm(tmp)
      error
    end
  end

  # `:exclusive` so nothing placed at the name beforehand is written through.
  # The file is created under the umask, so its mode and group are fixed
  # while it is still empty, before the cookie goes in. `:raw` +
  # `:file.write/2` because `IO.binwrite/2` raises on a write error (tmpfs
  # full), which would skip the tagged error and the temp-file cleanup.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_private(path, data, gid) do
    with {:ok, fd} <- File.open(path, [:write, :exclusive, :raw, :binary]) do
      result =
        with :ok <- File.chmod(path, 0o640),
             :ok <- File.chgrp(path, gid),
             :ok <- :file.write(fd, data),
             do: :file.sync(fd)

      case File.close(fd) do
        :ok -> result
        {:error, _reason} = error -> if result == :ok, do: error, else: result
      end
    end
  end

  @doc false
  # Called from `Vagus.Application.start/2` so the owner is the application
  # master's process rather than whichever SSH session calls `enable/1`, which
  # would take the record with it when that session ended.
  @spec create_session_table() :: :ok
  def create_session_table do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.insert(@table, {@session_key, :not_requested})
    :ok
  end

  @doc """
  What was asked for (`enabled?`) and what is actually true (`alive?`).

  Both, because they can disagree: a `:vagus` restart drops the ETS table while
  a node started before it stays up. Reporting only the record would call that
  board "off" while it answered on the LAN.
  """
  @spec status(keyword()) :: %{
          enabled?: boolean(),
          alive?: boolean(),
          node: node() | nil,
          ports: Range.t()
        }
  def status(opts \\ []) do
    system = system(opts)
    alive? = system.alive_fun.()

    %{
      enabled?: is_map(system.session_get_fun.()),
      alive?: alive?,
      node: if(alive?, do: system.self_node_fun.()),
      ports: @port_min..@port_max
    }
  end

  @doc """
  Flags the CALLING process `async_dist`, then runs `fun` and returns its value.

  Distribution buffer flow-control suspends a sending process when the outbound
  buffer fills, which can defer a long `:erpc.call` past its timeout — the
  failure mode for the multi-minute, multi-megabyte runs this exists to serve.

  The flag is process-local and must sit on whichever process actually puts the
  bytes on the wire. Under `:erpc.call/5` that is the process running this
  function: `erpc` spawns it and returns the result as its **exit reason**
  (`erpc.erl` `execute_call/4` ends in `exit(Reply)`), so the payload leaves the
  node with this process, not with anything it spawns. Flagging a child Task
  would flag a process whose only send is local.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    Process.flag(:async_dist, true)
    fun.()
  end

  defp bring_up(system) do
    case address(system) do
      {:ok, address} ->
        start(system, address)

      {:error, :no_address} = error ->
        system.session_reset_fun.()
        error
    end
  end

  # Failures are caught HERE, in the bring-up process, rather than watched from
  # outside it: our own `catch` runs before anything else sees the exception
  # (an interactive IEx session would catch a `MatchError` and keep going).
  # No caller's deadline kills this process, so the cleanup below runs.
  #
  # The steps themselves assert. The only cleanup that matters is stopping
  # `net_kernel`: after it starts, the node is live under the cookie OTP
  # invented, and that is weak — DEVICE-MEASURED on a dragon_q6a,
  # `/root/.erlang.cookie` is 20 uppercase letters, `auth.erl`
  # `random_cookie/3`'s LCG, because this target passes no `-setcookie`.
  # Everything else a failure leaves behind is cleared by the reboot the tester
  # does next.
  defp start(system, address) do
    :ok = pin_ports(system)
    :ok = start_epmd(system)
    {:ok, start_node(system, node_name(address))}
  catch
    kind, reason ->
      system.net_kernel_stop_fun.()
      system.session_reset_fun.()
      Logger.error("Vagus.Dist: bring-up failed; distribution stopped")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Ordering is load-bearing and not the obvious one:
  #
  #   * ports first — `inet_tcp_dist` reads the range from the kernel app env at
  #     LISTEN time.
  #   * epmd next — it only auto-starts when the VM was booted with
  #     `-name`/`-sname`, and Nerves deliberately passes neither.
  #   * the cookie last, because `set_cookie/1` raises `:distribution_not_started`
  #     before `net_kernel` is up. MEASURED on OTP 29.
  defp start_node(system, name) do
    case system.net_kernel_start_fun.(name, %{name_domain: :longnames}) do
      {:ok, _pid} ->
        take_ownership(system)

      # We lost the record, not the node: nothing else on a Nerves board starts
      # distribution, and MEASURED on host, stopping and restarting the `:vagus`
      # app destroys this table while `net_kernel`, owned by `:kernel`, stays
      # up. Take ownership rather than refuse, which would lock the operator out
      # of a board that is distributed right now.
      {:error, {:already_started, _pid}} ->
        take_ownership(system)
    end
  end

  # Always mints, never adopts the cookie already in place: on the recovery path
  # that cookie may be the weak one OTP invented, and handing it back would
  # launder a bad credential into a recorded session.
  defp take_ownership(system) do
    cookie = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    :ok = apply_cookie(system, cookie)

    # `set_cookie/1` gates NEW handshakes only, so a peer that authenticated
    # during the window above is still attached under the cookie OTP invented.
    # `:connected` rather than the default `:visible`, or a peer that attached
    # with `-hidden` survives the sweep.
    Enum.each(system.connected_nodes_fun.(), &system.disconnect_fun.(&1))

    session = %{node: system.self_node_fun.(), cookie: cookie, ports: @port_min..@port_max}
    :ok = system.session_put_fun.(session)
    session
  end

  # One atom per call, from a value `take_ownership/1` generated as 64 lowercase
  # hex, so the atom table cannot be grown by an attacker. Keep this annotation
  # DIRECTLY above the clause: sobelow binds it to the next function clause, so
  # inserting anything between the two silently moves the skip.
  # sobelow_skip ["DOS.StringToAtom"]
  defp apply_cookie(system, cookie) do
    atom = String.to_atom(cookie)
    system.set_cookie_fun.(atom)

    if system.get_cookie_fun.() == atom, do: :ok, else: {:error, :cookie_not_applied}
  end

  # The node name carries an address so connecting needs no lookup — its only
  # job, since the listener binds the wildcard.
  defp address(system) do
    system.ifaddrs_fun.()
    |> Enum.reject(fn {ifname, opts} ->
      Vagus.Network.container_interface?(ifname) or down?(opts)
    end)
    |> Enum.find_value(fn {_ifname, opts} ->
      Enum.find(Keyword.get_values(opts, :addr), &reachable?/1)
    end)
    |> case do
      nil -> {:error, :no_address}
      address -> {:ok, address}
    end
  end

  # A configured address on a DOWN interface is still an address, and choosing
  # it fails invisibly: distribution starts and the name answers nowhere.
  defp down?(opts), do: :up not in Keyword.get(opts, :flags, [])

  defp reachable?({127, _, _, _}), do: false
  defp reachable?({169, 254, _, _}), do: false
  defp reachable?({_, _, _, _}), do: true
  defp reachable?(_not_ipv4), do: false

  # sobelow_skip ["DOS.BinToAtom"]
  defp node_name(address), do: :"vagus@#{address |> :inet.ntoa() |> to_string()}"

  # `Application.put_env/3` returns `:ok` unconditionally, so there is no failure
  # to thread here.
  defp pin_ports(system) do
    system.put_env_fun.(:inet_dist_listen_min, @port_min)
    system.put_env_fun.(:inet_dist_listen_max, @port_max)
    :ok
  end

  # `epmd -daemon` exits 0 whether or not one is already running, and on a Nerves
  # board nothing else starts one, so a survivor is ours from an earlier call and
  # reusing it is correct. No `ERL_EPMD_ADDRESS`: the listener binds the
  # wildcard, so pinning epmd to one address would only make it disagree with the
  # node it serves.
  defp start_epmd(system) do
    case system.epmd_fun.(["-daemon"], []) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:epmd_failed, status, output}}
    end
  end

  # Every OS- and VM-touching call is injectable so this is provable on host
  # without ever starting real distribution. `Keyword.validate!/2` so a typo in
  # an override key raises instead of silently using the default.
  defp system(opts) do
    opts
    |> Keyword.validate!(
      ifaddrs_fun: &default_ifaddrs/0,
      put_env_fun: &default_put_env/2,
      epmd_fun: &default_epmd/2,
      net_kernel_start_fun: &:net_kernel.start/2,
      set_cookie_fun: &default_set_cookie/1,
      get_cookie_fun: &:erlang.get_cookie/0,
      alive_fun: &Node.alive?/0,
      connected_nodes_fun: fn -> Node.list(:connected) end,
      disconnect_fun: &Node.disconnect/1,
      net_kernel_stop_fun: &:net_kernel.stop/0,
      self_node_fun: &Node.self/0,
      session_claim_fun: &default_session_claim/1,
      session_get_fun: &default_session_get/0,
      session_put_fun: &default_session_put/1,
      session_reset_fun: &default_session_reset/0
    )
    |> Map.new()
  end

  # `select_replace/2` is the atomic compare-and-swap: exactly one concurrent
  # caller can move the row off what it read, so only that one proceeds to
  # `net_kernel.start`. Without it a second caller reaches `already_started`
  # while the first has not yet set its cookie, and records one that never
  # authenticates. A lost swap reads the row again.
  defp default_session_claim(claimant) do
    current = default_session_get()

    case claim_decision(current) do
      :take ->
        swap = [{{@session_key, current}, [], [{:const, {@session_key, {:starting, claimant}}}]}]

        if :ets.select_replace(@table, swap) == 1,
          do: :claimed,
          else: default_session_claim(claimant)

      answer ->
        answer
    end
  end

  # No default clause: a missing row means the table was never seeded, which is a
  # startup-wiring bug and should crash rather than read as "nobody asked".
  defp default_session_get do
    [{@session_key, session}] = :ets.lookup(@table, @session_key)
    session
  end

  defp default_session_put(session) do
    :ets.insert(@table, {@session_key, session})
    :ok
  end

  defp default_session_reset do
    :ets.insert(@table, {@session_key, :not_requested})
    :ok
  end

  defp default_ifaddrs do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} -> ifaddrs
      {:error, _reason} -> []
    end
  end

  defp default_put_env(key, value), do: Application.put_env(:kernel, key, value)

  defp default_set_cookie(cookie) do
    :erlang.set_cookie(cookie)
    :ok
  end

  # Not injectable: the binary is `:code.root_dir()`-relative and every argument
  # passed to it is a literal.
  #
  # `System.cmd/3` deliberately, NOT MuonTrap. MEASURED on a dragon_q6a:
  # `MuonTrap.cmd/3` hangs unbounded on `epmd -kill` with no daemon to kill and
  # its `:timeout` does not fire. This one has no deadline either, so an epmd
  # that never returns blocks the caller's shell with the claim still held. That
  # is accepted: bounding it needs a process to enforce the bound from, and this
  # is a test mode where the answer to "it did not come up" is a reboot.
  # sobelow_skip ["CI.System"]
  defp default_epmd(args, env) do
    System.cmd(epmd_path(), args, env: env, stderr_to_stdout: true)
  end

  defp epmd_path do
    Path.join([
      to_string(:code.root_dir()),
      "erts-#{:erlang.system_info(:version)}",
      "bin",
      "epmd"
    ])
  end
end
