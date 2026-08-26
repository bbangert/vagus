defmodule Vagus.Dist do
  @moduledoc """
  Runtime Erlang distribution for test and diagnostic work, on request only.

  `Vagus.Dist.enable/0` brings the node up and hands back everything needed to
  connect. **Nothing is written to disk.** There is no gate file, no config
  flag and no supervised process — a board is a single node until someone with
  SSH access asks otherwise, and it is a single node again after the next
  reboot.

  The one thing held is the session `enable/0` produced, in the `:vagus_dist`
  ETS table, so repeat calls return the same node and cookie instead of trying
  to start distribution twice. The table is created at application start and
  seeded `:not_requested`, so "nobody has asked" is a value that is read rather
  than an absence that is assumed. It lives in memory for exactly as long as
  the VM does.

  ## Why nothing persists

  A persistent gate is what made this dangerous. A cookie file on disk had to be
  validated, moded, mint-or-adopted, guarded against symlinks, and brought up
  unattended at boot — and a bad one crash-looped the board into a firmware
  rollback. Every one of those problems is a property of the file, not of
  distribution. Without it the failure mode of a broken `enable/0` is one failed
  call to one operator, and the recovery is a reboot that was going to happen
  anyway.

  It also removes the need to stop anything. Turning distribution off in place
  means stopping `net_kernel`, killing epmd, and reporting which of those did
  not happen without ever leaving a node alive under a secret already deleted.
  A reboot does all of it, correctly, for free.

  ## The listener binds 0.0.0.0

  The distribution port is not pinned to an interface. The operator turning this
  on is on the LAN and owns the exposure, and the alternative was an
  interface-ranking apparatus guarding a surface the cookie already protects.
  **The cookie is the whole control**: 32 bytes of
  `:crypto.strong_rand_bytes/1`, minted per call, returned once, never stored.

  OTP does create `$HOME/.erlang.cookie` (0400) when `net_kernel` starts, and it
  survives a reboot — but it never holds the cookie that authenticates anything.
  MEASURED on OTP 29: `net_kernel.start` writes a value it invented, and
  `set_cookie/1` updates the VM only, leaving that file untouched.

  Ports are pinned to 9100-9105 so the range is firewallable at the LAN edge
  rather than discovered. See `docs/divergences.md`.

  ## Runbook

      iex> Vagus.Dist.enable()
      {:ok, %{node: :"vagus@192.168.2.58", cookie: "a1b2c3...", ports: 9100..9105}}

  Then, from the dev host — no DNS, the node name is a bare IPv4 longname:

      iex --name agent@<your-host-ip> --cookie a1b2c3... -S mix
      iex> Node.connect(:"vagus@192.168.2.58")
      true

  Wrap bulk or long work in `run/1`, on the board side of the call:

      iex> :erpc.call(board, Vagus.Dist, :run, [fn -> collect_everything() end], :infinity)

  To turn it off, reboot. Distribution is an unauthenticated-root-equivalent
  surface on the LAN segment; a board left enabled is the mistake worth
  avoiding, and a reboot is the whole off switch.

  `status/0` reports whether `enable/0` has run since boot.
  """

  @port_min 9100
  @port_max 9105
  @table :vagus_dist
  @session_key :session

  @type session :: %{node: node(), cookie: String.t(), ports: Range.t()}

  @doc """
  Mints a cookie, brings the node up, and returns what you need to connect.

  Idempotent by record, not by inference: a successful call stores the session
  in `:persistent_term`, and every later call hands back that same node, cookie
  and port range without touching `net_kernel` again. Nothing clears the record,
  so it cannot go stale — the only code that ever stopped distribution was the
  old `disable/0`, and it is gone.
  """
  @spec enable(keyword()) :: {:ok, session()} | {:error, term()}
  def enable(opts \\ []) do
    system = system(opts)

    case system.session_get_fun.() do
      :not_requested -> bring_up(system)
      session -> {:ok, session}
    end
  end

  @doc false
  # Called from `Vagus.Application.start/2` so the owner is the application
  # master's process, which lives as long as the application. Creating it from
  # whichever process calls `enable/1` would tie the table to an SSH session and
  # lose the record when that session ended, while distribution stayed up.
  @spec create_session_table() :: :ok
  def create_session_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@table, {@session_key, :not_requested})
    :ok
  end

  @doc """
  What was asked for (`enabled?`) and what is actually true (`alive?`).

  Both, because they can disagree: a `:vagus` restart drops the ETS table while
  a node started before it stays up. Reporting only the record would call that
  board "off" while it answers on the LAN.

  The cookie is deliberately not repeated here — `enable/1` hands it back on
  every call, so there is no need for a second way to read it out.
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
      enabled?: system.session_get_fun.() != :not_requested,
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

  ## Bring-up

  # Ordering is load-bearing and not the obvious one:
  #
  #   * ports first — `inet_tcp_dist` reads the range from the kernel app env at
  #     LISTEN time.
  #   * epmd next — it only auto-starts when the VM was booted with
  #     `-name`/`-sname`, and Nerves deliberately passes neither.
  #   * `set_cookie` AFTER `net_kernel.start` — MEASURED on OTP 29: before it,
  #     `set_cookie/1` raises `:distribution_not_started`.
  #   * the `get_cookie` read-back LAST, and it is the whole safety property: a
  #     node alive under a cookie the caller was not handed is the one state
  #     this must never leave behind.
  #
  # There is no `$HOME/.erlang.cookie` pre-seed. `net_kernel.start` mints a
  # random cookie there when the file is absent, and an earlier version of this
  # module pre-seeded to close the window before `set_cookie` ran. That window
  # was never a security problem — a cookie OTP invented is unknown to everyone,
  # which is strictly more secret than ours. It was a correctness problem, and
  # the read-back already catches it.
  defp bring_up(system) do
    with {:ok, address} <- address(system),
         :ok <- pin_ports(system),
         :ok <- start_epmd(system) do
      start_node(system, node_name(address))
    end
  end

  # Split from `bring_up/1` so tear-down is UNREACHABLE from a failure that
  # happened before our own `net_kernel.start` returned. Stopping the node from
  # those paths would be stopping one this call did not start — the `alive?`
  # check at the top of `enable/1` is not a lock.
  defp start_node(system, name) do
    cookie = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    case system.net_kernel_start_fun.(name, %{name_domain: :longnames}) do
      {:ok, _pid} ->
        case apply_cookie(system, cookie) do
          :ok ->
            session = %{node: name, cookie: cookie, ports: @port_min..@port_max}
            system.session_put_fun.(session)
            {:ok, session}

          {:error, reason} ->
            {:error, stop_node(system, reason)}
        end

      # We lost the record, not the node. Nothing else on a Nerves board starts
      # distribution, and MEASURED on host: stopping and restarting the :vagus
      # app destroys the ETS table — its owner is the application master — while
      # `net_kernel` belongs to :kernel and stays up, still using the cookie we
      # minted. Refusing here would lock the operator out of a board that is
      # distributed on the LAN right now, so re-record what it is actually
      # using instead.
      {:error, {:already_started, _pid}} ->
        adopt(system)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp adopt(system) do
    session = %{
      node: system.self_node_fun.(),
      cookie: to_string(system.get_cookie_fun.()),
      ports: @port_min..@port_max
    }

    system.session_put_fun.(session)
    {:ok, session}
  end

  # One atom per call, from a value `start_node/2` generated as 64 lowercase hex,
  # so the atom table cannot be grown by an attacker. Keep this annotation
  # DIRECTLY above the clause: sobelow binds it to the next function clause, so
  # inserting anything between the two silently moves the skip.
  # sobelow_skip ["DOS.StringToAtom"]
  defp apply_cookie(system, cookie) do
    atom = String.to_atom(cookie)
    system.set_cookie_fun.(atom)

    if system.get_cookie_fun.() == atom, do: :ok, else: {:error, :cookie_not_applied}
  end

  # The only thing worth undoing. epmd is deliberately left alone: it serves an
  # empty name list, costs a listening port that a reboot clears, and nothing
  # else on a Nerves board starts one — so killing it here risks stopping a
  # daemon this call did not create, for no gain. A node left alive under an
  # unverified cookie is the one thing that genuinely must not survive, so
  # `Node.alive?/0` decides rather than `net_kernel.stop/0`'s return.
  defp stop_node(system, reason) do
    stopped = system.net_kernel_stop_fun.()
    if system.alive_fun.(), do: {reason, {:still_alive, stopped}}, else: reason
  end

  ## Naming

  # The node name carries an address so connecting needs no lookup — that is its
  # only job, since the listener binds the wildcard.
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
  # OBSERVED on a dragon_q6a: `hassio` (172.30.32.0/23, the one network Vagus
  # creates) and `balena0` (172.17.0.1, balenaEngine's default bridge). `br-`
  # covers any further bridge the engine names for itself; there is no
  # `docker0` entry because this product does not run plain Docker.
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

  # `epmd -daemon` exits 0 whether or not one is already running, and on a
  # Nerves board nothing else starts one — so a survivor is ours from an earlier
  # call and reusing it is correct. No `ERL_EPMD_ADDRESS`: the listener binds
  # the wildcard, so pinning epmd to one address would only make it disagree
  # with the node it serves.
  defp start_epmd(system) do
    case system.epmd_fun.(["-daemon"], []) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:epmd_failed, status, output}}
    end
  end

  # Every OS-touching call is injectable so this is provable on host without
  # ever starting real distribution. Passed per call rather than held anywhere,
  # because nothing here has state to hold it in.

  defp system(opts) do
    %{
      ifaddrs_fun: Keyword.get(opts, :ifaddrs_fun, &default_ifaddrs/0),
      put_env_fun: Keyword.get(opts, :put_env_fun, &default_put_env/2),
      epmd_fun: Keyword.get(opts, :epmd_fun, &default_epmd/2),
      net_kernel_start_fun: Keyword.get(opts, :net_kernel_start_fun, &:net_kernel.start/2),
      net_kernel_stop_fun: Keyword.get(opts, :net_kernel_stop_fun, &:net_kernel.stop/0),
      set_cookie_fun: Keyword.get(opts, :set_cookie_fun, &default_set_cookie/1),
      get_cookie_fun: Keyword.get(opts, :get_cookie_fun, &:erlang.get_cookie/0),
      alive_fun: Keyword.get(opts, :alive_fun, &Node.alive?/0),
      self_node_fun: Keyword.get(opts, :self_node_fun, &Node.self/0),
      session_get_fun: Keyword.get(opts, :session_get_fun, &default_session_get/0),
      session_put_fun: Keyword.get(opts, :session_put_fun, &default_session_put/1)
    }
  end

  # No default clause: a missing row means the table was never seeded, which is a
  # bug in startup wiring and should crash rather than read as "nobody asked".
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
  # its `:timeout` does not fire. Unbounded is acceptable here because this runs
  # once, in a call an operator made, on a board they are logged into.
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
