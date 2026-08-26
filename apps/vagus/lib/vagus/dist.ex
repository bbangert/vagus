defmodule Vagus.Dist do
  @moduledoc """
  Runtime Erlang distribution for test and diagnostic work, on request only.

  > #### Test boards only {: .warning}
  >
  > This is not for a board anyone depends on. Enabling it opens an
  > unauthenticated-root-equivalent surface on the LAN segment, and **any
  > failure while enabling reboots the board** — there is no rollback, because
  > restarting is the cleanest way back to a known non-distributed state.

  `enable/0` starts distribution and returns the node, cookie and port range.
  Nothing is enabled until someone asks, and a reboot turns it back off — there
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

  alias Vagus.Host.Shutdown

  @port_min 9100
  @port_max 9105
  # Bounds both how long the caller waits and how long the guard lets a stalled
  # worker hold the claim — `epmd -daemon` through `System.cmd/3` has no timeout
  # of its own.
  @bring_up_timeout :timer.seconds(30)

  # Only bounds how long the guard waits for a killed worker to actually die,
  # so it never delays the reboot meaningfully.
  @kill_timeout :timer.seconds(5)

  # Never expected to fire: the guard always reports an outcome, and its own
  # deadline is shorter. Here so a lost guard cannot hang an operator's shell.
  @caller_backstop @bring_up_timeout + @kill_timeout + :timer.seconds(10)
  @table :vagus_dist
  @session_key :session

  @type session :: %{node: node(), cookie: String.t(), ports: Range.t()}

  @doc """
  Mints a cookie, brings the node up, and returns what you need to connect.

  Idempotent: the first caller claims the `:vagus_dist` row atomically and every
  later call hands back that same session without touching `net_kernel` again.
  A caller that arrives while a claim is in flight gets `{:error, :starting}`
  rather than racing it.

  Losing the caller is not itself a failure. Bring-up runs in its own process,
  so a caller that dies mid-call leaves a board that either finished correctly —
  session recorded, retrievable by calling this again — or is rebooting. What is
  guaranteed is the outcome, not that anyone is still listening for it.
  """
  @spec enable(keyword()) :: {:ok, session()} | {:error, term()}
  def enable(opts \\ []) do
    system = system(opts)

    case system.session_claim_fun.() do
      :claimed ->
        bring_up(system)

      :starting ->
        {:error, :starting}

      # A record with no live node behind it is corruption — only a deliberate
      # `:net_kernel.stop/0` produces it — and handing back a session whose
      # listener is gone would send an operator to a dead port.
      {:recorded, session} ->
        if system.alive_fun.() do
          {:ok, session}
        else
          Logger.error("Vagus.Dist: recorded session but no live node; rebooting")
          system.reboot_fun.()
          {:error, :node_gone}
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

  # Bring-up runs in a WORKER, and the guard watches the worker rather than the
  # caller. That distinction is load-bearing and was got wrong once: an
  # interactive IEx session catches `MatchError` and keeps its evaluator alive,
  # so a guard watching the caller never fires. DEVICE-MEASURED on a
  # dragon_q6a — `iex> Vagus.Dist.enable(...)` with a failing cookie left the
  # node up as `vagus@...` under the 20-letter LCG cookie, the row stuck at
  # `:starting`, and no reboot. Nobody can rescue a worker, so its exit reason
  # is an honest signal.
  #
  # Nothing is rolled back. This is a test-mode tool on a test board: the fail
  # case for every step is "restart the board", which reseeds the table, stops
  # the node and returns a known non-distributed boot for free. So each step
  # asserts, and the guard turns any abnormal exit into a reboot.
  defp bring_up(system) do
    parent = self()
    ref = make_ref()

    spawn(fn -> guard(system, parent, ref) end)

    # No deadline here. The guard owns the only one and reports the outcome it
    # actually observed — two independent timers on the same deadline let the
    # caller's fire first and return `{:error, :timeout}` for a bring-up that
    # went on to succeed, with no reboot to match the reported failure.
    receive do
      {^ref, outcome} -> outcome
    after
      @caller_backstop -> {:error, :guard_lost}
    end
  end

  # Ordering is load-bearing and not the obvious one:
  #
  #   * ports first — `inet_tcp_dist` reads the range from the kernel app env at
  #     LISTEN time.
  #   * epmd next — it only auto-starts when the VM was booted with
  #     `-name`/`-sname`, and Nerves deliberately passes neither.
  #   * the cookie last, because `set_cookie/1` raises `:distribution_not_started`
  #     before `net_kernel` is up. MEASURED on OTP 29.
  defp start_distribution(system) do
    {:ok, address} = address(system)
    :ok = pin_ports(system)
    :ok = start_epmd(system)
    start_node(system, node_name(address))
  end

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
    # during the window above is still attached under the cookie OTP invented
    # and would keep root-equivalent access despite the read-back succeeding.
    # `:connected` rather than the default `:visible`, or a peer that attached
    # with `-hidden` survives the sweep.
    Enum.each(system.connected_nodes_fun.(), &system.disconnect_fun.(&1))

    session = %{node: system.self_node_fun.(), cookie: cookie, ports: @port_min..@port_max}
    :ok = system.session_put_fun.(session)
    session
  end

  # The guard CREATES the worker, via `spawn_monitor/1`, so the monitor is
  # installed atomically with the spawn. Spawning the worker separately and
  # monitoring it afterwards loses a race: a worker that finishes first is
  # already dead, `Process.monitor/1` then reports `:noproc`, and a SUCCESSFUL
  # bring-up gets misread as a failure and reboots the board.
  #
  # It is also the single source of the caller's outcome, so what `enable/0`
  # returns always matches what the guard did about it.
  defp guard(system, parent, ref) do
    me = self()

    {worker, monitor} =
      spawn_monitor(fn -> send(me, {:result, start_distribution(system)}) end)

    receive do
      {:DOWN, ^monitor, :process, ^worker, :normal} ->
        # The worker's send happens-before its exit and signals from one process
        # arrive in order, so the result is already in the mailbox here.
        receive do
          {:result, session} -> send(parent, {ref, {:ok, session}})
        after
          0 -> send(parent, {ref, {:error, :no_result}})
        end

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        send(parent, {ref, {:error, {:bring_up_failed, reason}}})
        shut_down(system, "bring-up failed (#{inspect(reason)})")
    after
      @bring_up_timeout ->
        # Kill it and WAIT. A worker stalled in `epmd` could otherwise return
        # after the deadline and walk into `net_kernel.start` behind our back,
        # reopening the listener during a graceful reboot that takes minutes.
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        after
          @kill_timeout -> :ok
        end

        send(parent, {ref, {:error, :timeout}})
        shut_down(system, "bring-up stalled")
    end
  end

  defp shut_down(system, why) do
    system.net_kernel_stop_fun.()
    Logger.error("Vagus.Dist: #{why}; rebooting")
    system.reboot_fun.()
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
    |> Enum.reject(fn {ifname, opts} -> container_bridge?(ifname) or down?(opts) end)
    |> Enum.find_value(fn {_ifname, opts} ->
      Enum.find(Keyword.get_values(opts, :addr), &reachable?/1)
    end)
    |> case do
      nil -> {:error, :no_address}
      address -> {:ok, address}
    end
  end

  # By NAME, not by address range: `172.16/12` is RFC1918 in its entirety, so
  # excluding it would strand a board on an ordinary `172.20.x.x` LAN.
  #
  # OBSERVED on a dragon_q6a: `hassio` (the one network Vagus creates) and
  # `balena0` (balenaEngine's default bridge). `br-` covers any further bridge
  # the engine names for itself; there is no `docker0` because this product does
  # not run plain Docker.
  defp container_bridge?(ifname) do
    name = to_string(ifname)
    name in ["hassio", "balena0"] or String.starts_with?(name, "br-")
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
      reboot_fun: &Shutdown.reboot/0,
      self_node_fun: &Node.self/0,
      session_claim_fun: &default_session_claim/0,
      session_get_fun: &default_session_get/0,
      session_put_fun: &default_session_put/1
    )
    |> Map.new()
  end

  # `select_replace/2` is the atomic compare-and-swap: exactly one concurrent
  # caller can move the row off `:not_requested`, so only that one proceeds to
  # `net_kernel.start`. Without it a second caller reaches `already_started`
  # while the first has not yet set its cookie, and records one that never
  # authenticates.
  defp default_session_claim do
    claim = [{{@session_key, :not_requested}, [], [{{@session_key, :starting}}]}]

    case :ets.select_replace(@table, claim) do
      1 ->
        :claimed

      0 ->
        case default_session_get() do
          :starting -> :starting
          session -> {:recorded, session}
        end
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
  # its `:timeout` does not fire. Unbounded is tolerable because this runs in the
  # spawned worker, and the guard reboots if that worker stalls past
  # `@bring_up_timeout`.
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
