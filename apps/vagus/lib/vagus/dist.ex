defmodule Vagus.Dist do
  @moduledoc """
  Runtime Erlang distribution for test and diagnostic work, gated by the
  presence of a cookie file.

  Every board ships this module; no board distributes until
  `config :vagus, :dist_cookie_path` points at a file that exists.
  `Vagus.Dist.enable/0` writes that file and reboots; `Vagus.Dist.disable/0`
  deletes it and reboots. Nothing is discovered, advertised, or negotiated —
  `enable/0` hands back everything needed to connect, over the SSH session that
  called it.

  ## Why a reboot, and why so little machinery

  This is a test mode, toggled a handful of times in a board's life. Flipping a
  *live* board means stopping `net_kernel`, killing epmd, and threading every
  one of those failures back to a caller without ever leaving a node alive under
  a secret that has already been deleted. A reboot reaches the same end state
  and none of that exists. It also puts every external command on the boot path,
  where nothing is waiting on a `GenServer.call`.

  ## The listener binds 0.0.0.0, deliberately

  The distribution port is not pinned to an interface. On a board this mode is
  turned on for, the operator is on the LAN and owns the exposure — and the
  alternative was an interface-ranking apparatus that existed only to narrow a
  surface the cookie already protects. **The cookie is the whole control**, and
  it is 32 bytes of `:crypto.strong_rand_bytes/1` living at 0600 in `/data`,
  which is not among the paths bound into add-on containers.

  Ports are still pinned to 9100-9105 so the range is firewallable at the LAN
  edge rather than discovered. See `docs/divergences.md`.

  ## Runbook

  **1. Turn it on.** The board reboots; it comes back distributed.

      iex> Vagus.Dist.enable()
      {:ok, %{node: :"vagus@192.168.2.58", cookie: "a1b2c3...", ports: 9100..9105}}

  **2. Connect.** TCP 4369 and 9100-9105 must be open to the board. No DNS: the
  node name is a bare IPv4 longname, which does no lookup.

      iex --name agent@<your-host-ip> --cookie a1b2c3... -S mix
      iex> Node.connect(:"vagus@192.168.2.58")
      true

  **3. Wrap bulk or long work in `run/1`**, on the board side of the call:

      iex> :erpc.call(board, Vagus.Dist, :run, [fn -> collect_everything() end], :infinity)

  **4. Turn it off** when the work is done. The board reboots and comes back a
  single node. Distribution is an unauthenticated-root-equivalent surface on the
  LAN segment; leaving it on is the mistake this call exists to prevent.

      iex> Vagus.Dist.disable()

  `status/0` answers what is true now — `alive?`, `node`, `cookie_present?`,
  `ports`, and `last_error`, which is why a boot refused to bring the node up.

  ## The cookie file is not operator-editable

  `enable/0` is the only thing that creates it. Anything else on disk is
  corruption and is refused rather than adopted: empty is `:cookie_empty`,
  content that is not 64 lowercase hex is `:cookie_malformed`, and a mode that
  is not 0600 is refused without being read. Adopting such a file once yielded a
  live node with the cookie `:''`.
  """

  use GenServer

  require Logger

  import Bitwise, only: [band: 2]

  @port_min 9100
  @port_max 9105

  # Exactly what mint/1 writes: 32 bytes, lowercase hex.
  @cookie_format ~r/\A[0-9a-f]{64}\z/
  @cookie_mode 0o600
  @erlang_cookie_mode 0o400

  # Flat, not exponential, and it never gives up: the only thing worth waiting
  # for is an address, and a board that gets one at minute ten should come up.
  @retry_ms 5_000

  @type status :: %{
          alive?: boolean(),
          node: node() | nil,
          cookie_present?: boolean(),
          ports: Range.t(),
          last_error: term() | nil
        }

  @doc """
  Starts the gate keeper — `:ignore` (no process) unless
  `config :vagus, :dist_cookie_path` is set (target.exs only).

  The process starts whether or not the cookie file exists: the file gates
  *distribution*, not the GenServer, and `enable/0` needs something to call
  into.
  """
  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :cookie_path) || Application.get_env(:vagus, :dist_cookie_path) do
      nil ->
        :ignore

      path ->
        GenServer.start_link(__MODULE__, Keyword.put(opts, :cookie_path, path),
          name: Keyword.get(opts, :name, __MODULE__)
        )
    end
  end

  @doc """
  Mints the cookie if absent, then reboots the board so it comes back
  distributed.

  Returns everything needed to connect before the reboot happens, because after
  it the SSH session is gone. Already-distributed boards return the same and do
  not reboot.
  """
  @spec enable(GenServer.server()) ::
          {:ok, %{node: node() | nil, cookie: String.t(), ports: Range.t()}} | {:error, term()}
  def enable(server \\ __MODULE__), do: GenServer.call(server, :enable, 30_000)

  @doc """
  Deletes both cookie files and reboots, so the board comes back a single node.

  `{:error, {:cookie_not_removed, path, reason}}` means a file is still there
  and no reboot was attempted — while it remains, the next boot brings
  distribution back.
  """
  @spec disable(GenServer.server()) :: :ok | {:error, term()}
  def disable(server \\ __MODULE__), do: GenServer.call(server, :disable, 30_000)

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Flags the CALLING process `async_dist`, then runs `fun` and returns its value.

  Distribution buffer flow-control suspends a sending process when the outbound
  buffer fills, which can defer a long `:erpc.call` past its timeout — the
  failure mode for the multi-minute, multi-megabyte runs this mode exists to
  serve. `async_dist` makes those sends buffer instead of blocking.

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

  @impl GenServer
  def init(opts) do
    state = %{
      cookie_path: Keyword.fetch!(opts, :cookie_path),
      node: nil,
      last_error: nil,
      retry_ref: nil,
      seams: seams(opts)
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl GenServer
  def handle_continue(:boot, state), do: {:noreply, boot(state)}

  def handle_continue(:reboot, state) do
    state.seams.reboot_fun.()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:enable, _from, state) do
    # Writes a file, then reboots. Nothing here can block on the outside world,
    # which is what keeps this call unable to wedge the server.
    case read_or_mint(state) do
      {:ok, cookie} ->
        # The name has to come back NOW: after the reboot the SSH session that
        # asked is gone, and without it the caller has a cookie and nowhere to
        # point it.
        reply = %{
          node: state.node || planned_node(state),
          cookie: cookie,
          ports: @port_min..@port_max
        }

        # {:continue, :reboot}, NOT a reboot while building this tuple: the
        # third element is evaluated before gen_server sends the reply, so
        # rebooting there killed the board with the cookie still in flight and
        # the caller saw only a call timeout. handle_continue/2 runs after the
        # reply is on the wire.
        if state.seams.alive_fun.() do
          {:reply, {:ok, reply}, state}
        else
          {:reply, {:ok, reply}, state, {:continue, :reboot}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disable, _from, state) do
    case Enum.find([delete_cookie(state), delete_erlang_cookie(state)], &(&1 != :ok)) do
      # Only reboot once the gate is actually shut — restarting with a cookie
      # still on disk would bring distribution straight back — and only after
      # the reply is sent, for the same reason enable/1 does.
      nil ->
        {:reply, :ok, state, {:continue, :reboot}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       alive?: state.seams.alive_fun.(),
       node: state.node,
       cookie_present?: File.exists?(state.cookie_path),
       ports: @port_min..@port_max,
       last_error: state.last_error
     }, state}
  end

  @impl GenServer
  def handle_info(:retry_start, %{node: nil} = state),
    do: {:noreply, boot(%{state | retry_ref: nil})}

  def handle_info(:retry_start, state), do: {:noreply, %{state | retry_ref: nil}}

  ## Boot path

  # The whole path is guarded: a raise escaping handle_continue/2 reaches the
  # top-level supervisor, whose restart budget is shared with every other child.
  # With the cookie file still present the next boot raises again — on a fresh
  # flash that is a crash loop and a `startup_guard` rollback across the fleet.
  defp boot(state) do
    case guarded(fn -> attempt_boot(state) end) do
      {:error, reason} -> retry(state, reason)
      booted -> booted
    end
  end

  defp attempt_boot(state) do
    if File.exists?(state.cookie_path) do
      case read_or_mint(state) do
        {:ok, cookie} -> start(state, cookie)
        {:error, reason} -> idle(state, reason)
      end
    else
      state
    end
  end

  defp guarded(fun) do
    fun.()
  rescue
    exception ->
      # Frame ARGUMENTS appear in an Erlang stacktrace for function_clause and
      # BIF badarg, and the cookie is an argument the whole length of start/2 —
      # so the banner is built without the stacktrace and every frame is reduced
      # to its arity before formatting.
      Logger.error(
        "Vagus.Dist: #{Exception.format_banner(:error, exception)}\n" <>
          Exception.format_stacktrace(redact(__STACKTRACE__))
      )

      {:error, {:crashed, :error, exception}}
  catch
    kind, reason ->
      Logger.error("Vagus.Dist: boot path #{kind} #{inspect(reason)}")
      {:error, {:crashed, kind, reason}}
  end

  defp redact(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
  end

  defp idle(state, reason) do
    Logger.warning("Vagus.Dist: staying idle (#{inspect(reason)})")
    %{state | last_error: reason}
  end

  defp retry(state, reason) do
    state = cancel_retry(state)
    Logger.info("Vagus.Dist: not up yet (#{inspect(reason)}), retrying in #{@retry_ms}ms")

    %{
      state
      | last_error: reason,
        retry_ref: Process.send_after(self(), :retry_start, @retry_ms)
    }
  end

  defp cancel_retry(%{retry_ref: nil} = state), do: state

  defp cancel_retry(state) do
    Process.cancel_timer(state.retry_ref)

    receive do
      :retry_start -> :ok
    after
      0 -> :ok
    end

    %{state | retry_ref: nil}
  end

  ## Start sequence

  defp start(%{node: node} = state, _cookie) when node != nil, do: state

  defp start(state, cookie) do
    # A GenServer crash-restart rebuilds state.node as nil while net_kernel
    # survives, so the guard above cannot fire and none of the bring-up below is
    # wanted. Node.self/0 is authoritative — this module's bookkeeping is not.
    if state.seams.alive_fun.() do
      %{cancel_retry(state) | node: state.seams.self_node_fun.(), last_error: nil}
    else
      bring_up(state, cookie)
    end
  end

  # The ordering is load-bearing and not the obvious one:
  #
  #   * ports first — `inet_tcp_dist` reads the range from the kernel app env at
  #     LISTEN time.
  #   * epmd next — it only auto-starts when the VM was booted with
  #     `-name`/`-sname`, and Nerves deliberately passes neither.
  #   * `$HOME/.erlang.cookie` before net_kernel — MEASURED on OTP 29:
  #     `set_cookie/1` before net_kernel raises `:distribution_not_started`, and
  #     starting net_kernel mints a RANDOM cookie into that file when it is
  #     absent. Pre-seeding closes the window in which the node is live on the
  #     LAN under a secret we did not choose, because `auth:init_cookie/0` falls
  #     through to `read_cookie/0` on that file.
  #   * the `get_cookie` read-back LAST, because a node alive under a cookie
  #     that is not ours is the one state this must never leave behind.
  defp bring_up(state, cookie) do
    with {:ok, address} <- address(state),
         :ok <- pin_ports(state),
         :ok <- start_epmd(state),
         :ok <- seed_erlang_cookie(state, cookie),
         name = node_name(address),
         {:ok, _pid} <- state.seams.net_kernel_start_fun.(name, %{name_domain: :longnames}),
         :ok <- apply_cookie(state, cookie) do
      Logger.info("Vagus.Dist: #{name} alive, dist ports #{@port_min}-#{@port_max}")
      %{cancel_retry(state) | node: name, last_error: nil}
    else
      # Measured: net_kernel answers this even under a DIFFERENT name, so a
      # restart that also changed address lands here. The node is UP.
      {:error, {:already_started, _pid}} ->
        %{cancel_retry(state) | node: state.seams.self_node_fun.(), last_error: nil}

      {:error, reason} ->
        retry(roll_back(state, reason), reason)

      other ->
        retry(roll_back(state, other), other)
    end
  end

  # Nothing this function started may outlive the failure: an epmd left
  # listening on a board whose status/0 says there is no node is a port open for
  # no reason.
  defp roll_back(state, _reason) do
    kill_epmd(state)
    state
  end

  # The node name carries an address so connecting needs no lookup — that is its
  # only job, since the listener binds the wildcard. Container and link-local
  # ranges are excluded because a name on one of those is unreachable from the
  # LAN the operator is calling from; nothing else is ranked or preferred.
  defp address(state) do
    state.seams.ifaddrs_fun.()
    |> Enum.find_value(fn {_ifname, opts} ->
      Enum.find(Keyword.get_values(opts, :addr), &reachable?/1)
    end)
    |> case do
      nil -> {:error, :no_address}
      address -> {:ok, address}
    end
  end

  defp reachable?({127, _, _, _}), do: false
  defp reachable?({169, 254, _, _}), do: false
  defp reachable?({172, b, _, _}) when b >= 16 and b <= 31, do: false
  defp reachable?({0, 0, 0, 0}), do: false
  defp reachable?({_, _, _, _}), do: true
  defp reachable?(_not_ipv4), do: false

  defp pin_ports(state) do
    with :ok <- state.seams.put_env_fun.(:inet_dist_listen_min, @port_min) do
      state.seams.put_env_fun.(:inet_dist_listen_max, @port_max)
    end
  end

  # Launched by hand from the release's own ERTS — it is on no PATH the BEAM
  # inherits. No `ERL_EPMD_ADDRESS`: the listener binds the wildcard, so pinning
  # epmd to one address would only make it disagree with the node it serves.
  defp start_epmd(state) do
    with :ok <- clear_foreign_epmd(state) do
      case state.seams.epmd_fun.(["-daemon"], []) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:epmd_failed, status, output}}
      end
    end
  end

  # `epmd -daemon` exits 0 when another epmd already holds the port: it does
  # nothing at all. Nerves starts no epmd of its own, so a live one is a prior
  # enable — replace it rather than start a node behind a daemon whose state we
  # do not know.
  defp clear_foreign_epmd(state) do
    if epmd_running?(state), do: kill_epmd(state), else: :ok
  end

  # The exit status of `epmd -names` is not consistent across OTP versions when
  # it cannot reach a daemon, so match the banner it prints when it can.
  defp epmd_running?(state) do
    {output, _status} = state.seams.epmd_fun.(["-names"], [])
    String.contains?(output, "up and running")
  end

  defp kill_epmd(state) do
    case state.seams.epmd_fun.(["-kill"], []) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:epmd_kill_failed, status, output}}
    end
  end

  defp seed_erlang_cookie(state, cookie) do
    case state.seams.erlang_cookie_path_fun.() do
      # No mode read-back: `auth:check_attributes/4` rejects any cookie file
      # with a group or other permission bit set, and `auth`'s init — which runs
      # as part of net_kernel.start — then raises rather than falling back. A
      # too-loose file therefore fails the start outright.
      {:ok, path} -> write_secret(state, path, cookie, @erlang_cookie_mode)
      {:error, reason} -> {:error, {:erlang_cookie_path, reason}}
    end
  end

  defp apply_cookie(state, cookie) do
    atom = cookie_atom(cookie)
    state.seams.set_cookie_fun.(atom)

    if state.seams.get_cookie_fun.() == atom do
      :ok
    else
      state.seams.net_kernel_stop_fun.()
      {:error, :cookie_not_applied}
    end
  rescue
    exception ->
      # Stop first, then propagate: a raise from a seam must not walk past the
      # read-back and leave distribution live under an unverified cookie.
      state.seams.net_kernel_stop_fun.()
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      state.seams.net_kernel_stop_fun.()
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # One atom per boot, from a file this module minted and matched against
  # @cookie_format, so the 255-character limit is unreachable.
  # sobelow_skip ["DOS.StringToAtom"]
  defp cookie_atom(cookie), do: String.to_atom(cookie)

  # sobelow_skip ["DOS.BinToAtom"]
  defp node_name(address), do: :"vagus@#{address |> :inet.ntoa() |> to_string()}"

  # What the board will call itself after the reboot. nil only when it has no
  # reachable address yet — the same condition the boot path retries on.
  defp planned_node(state) do
    case address(state) do
      {:ok, address} -> node_name(address)
      {:error, _reason} -> nil
    end
  end

  ## Cookie store
  #
  # Two files, two modes, deliberately: /data/vagus.cookie is 0600 because this
  # module re-reads it on every boot; $HOME/.erlang.cookie is 0400 because
  # auth:read_cookie/0 refuses anything looser.

  # path is config-derived (app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_or_mint(state) do
    case File.stat(state.cookie_path) do
      # enable/0 is the only writer, so a zero-byte file is a truncated write or
      # a hand-made one, never a request to start.
      {:ok, %File.Stat{size: 0}} -> {:error, :cookie_empty}
      {:ok, %File.Stat{mode: mode}} -> read_existing(state, band(mode, 0o777))
      {:error, :enoent} -> mint(state)
      {:error, reason} -> {:error, {:cookie_unreadable, reason}}
    end
  end

  # Mode first, and refuse WITHOUT reading: adopting a secret out of a file
  # whose mode cannot be vouched for is the thing being guarded against.
  defp read_existing(_state, mode) when mode != @cookie_mode, do: {:error, {:mode_unproven, mode}}

  # sobelow_skip ["Traversal.FileModule"]
  defp read_existing(state, _mode) do
    case File.read(state.cookie_path) do
      {:ok, contents} -> validate(String.trim(contents))
      {:error, reason} -> {:error, {:cookie_unreadable, reason}}
    end
  end

  defp validate(""), do: {:error, :cookie_empty}

  defp validate(cookie) do
    if Regex.match?(@cookie_format, cookie), do: {:ok, cookie}, else: {:error, :cookie_malformed}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp mint(state) do
    cookie = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    with :ok <- File.mkdir_p(Path.dirname(state.cookie_path)),
         :ok <- write_secret(state, state.cookie_path, cookie, @cookie_mode),
         :ok <- verify_mode(state.cookie_path, @cookie_mode) do
      {:ok, cookie}
    else
      {:error, {:cookie_unwritable, _}} = unwritable ->
        unwritable

      {:error, reason} ->
        # A cookie whose mode cannot be proven must not survive to the next
        # boot, where read_or_mint/1 refuses it outright instead of re-minting.
        _ = File.rm(state.cookie_path)
        {:error, {:cookie_unwritable, reason}}
    end
  end

  # Created at its final mode BEFORE any content exists, then renamed into
  # place: `File.write` + `File.chmod` leaves a window in which the cookie is
  # world-readable, and this runs as root, so a symlink planted at the target
  # would be followed. `:exclusive` refuses an existing temp, symlink or not.
  #
  # `:raw` + `:file.write/2` rather than `IO.binwrite/2`, as
  # `Vagus.Addon.Store.Assets.write_exclusive/2` documents: on Elixir 1.20
  # `IO.binwrite/2` RAISES on a write error instead of returning a tagged one,
  # which would escape the never-crash boot path and skip the cleanup below.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp write_secret(state, path, contents, mode) do
    tmp = path <> ".tmp"
    _ = File.rm(tmp)

    case File.open(tmp, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} ->
        written =
          try do
            with :ok <- state.seams.chmod_fun.(tmp, mode),
                 :ok <- :file.write(io, contents) do
              File.close(io)
            end
          after
            File.close(io)
          end

        place_secret(written, tmp, path)

      {:error, reason} ->
        {:error, {:cookie_unwritable, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp place_secret(:ok, tmp, path) do
    case File.rename(tmp, path) do
      :ok -> :ok
      {:error, reason} -> discard_secret(tmp, reason)
    end
  end

  defp place_secret({:error, reason}, tmp, _path), do: discard_secret(tmp, reason)

  # A half-written cookie left behind is read as the whole secret next boot.
  # sobelow_skip ["Traversal.FileModule"]
  defp discard_secret(tmp, reason) do
    _ = File.rm(tmp)
    {:error, {:cookie_unwritable, reason}}
  end

  # The mode is set AND read back, as `Vagus.SSHAccess` does for its private
  # key: a silently-failed chmod would leave a world-readable cookie.
  # sobelow_skip ["Traversal.FileModule"]
  defp verify_mode(path, expected) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if band(mode, 0o777) == expected,
          do: :ok,
          else: {:error, {:mode_unproven, band(mode, 0o777)}}

      {:error, reason} ->
        {:error, {:mode_unproven, reason}}
    end
  end

  defp delete_cookie(state), do: remove(state.cookie_path)

  defp delete_erlang_cookie(state) do
    case state.seams.erlang_cookie_path_fun.() do
      {:error, _no_home} -> :ok
      {:ok, path} -> remove(path)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:cookie_not_removed, path, reason}}
    end
  end

  ## Seams
  #
  # Every OS-touching edge is injectable so the module is provable on host
  # without ever starting real distribution. Where a default is a raw OTP call,
  # the suite pins the shape that default has to satisfy.

  # The `&File.chmod/2` default is a capture, not a call on a path from
  # anywhere; the paths it receives are `:dist_cookie_path` and $HOME-derived.
  # sobelow_skip ["Traversal.FileModule"]
  defp seams(opts) do
    %{
      chmod_fun: Keyword.get(opts, :chmod_fun, &File.chmod/2),
      ifaddrs_fun: Keyword.get(opts, :ifaddrs_fun, &default_ifaddrs/0),
      put_env_fun: Keyword.get(opts, :put_env_fun, &default_put_env/2),
      set_cookie_fun: Keyword.get(opts, :set_cookie_fun, &default_set_cookie/1),
      get_cookie_fun: Keyword.get(opts, :get_cookie_fun, &:erlang.get_cookie/0),
      erlang_cookie_path_fun: Keyword.get(opts, :erlang_cookie_path_fun, &erlang_cookie_path/0),
      net_kernel_start_fun: Keyword.get(opts, :net_kernel_start_fun, &:net_kernel.start/2),
      net_kernel_stop_fun: Keyword.get(opts, :net_kernel_stop_fun, &:net_kernel.stop/0),
      alive_fun: Keyword.get(opts, :alive_fun, &Node.alive?/0),
      self_node_fun: Keyword.get(opts, :self_node_fun, &Node.self/0),
      epmd_fun: Keyword.get(opts, :epmd_fun, &default_epmd/2),
      reboot_fun: Keyword.get(opts, :reboot_fun, &default_reboot/0)
    }
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

  @doc false
  # Public only so the suite can pin it without writing the developer's real
  # home: this derivation is the assumption the whole pre-seed rests on. `auth`
  # takes the path from `init:get_argument(home)`, NOT from the OS environment,
  # so that is what is asked first — the two coincide on Nerves (erlinit sets
  # HOME=/root) but only by convention. Never fall back to a relative path.
  @spec erlang_cookie_path() :: {:ok, Path.t()} | {:error, :no_home}
  def erlang_cookie_path do
    case erlang_home() do
      nil -> {:error, :no_home}
      home -> {:ok, Path.join(home, ".erlang.cookie")}
    end
  end

  defp erlang_home do
    case :init.get_argument(:home) do
      {:ok, [[home] | _]} -> List.to_string(home)
      _no_home_argument -> System.get_env("HOME")
    end
  end

  # `System.cmd/3` deliberately, NOT MuonTrap. MEASURED on a dragon_q6a:
  # `MuonTrap.cmd/3` hangs unbounded on `epmd -kill` with no daemon to kill and
  # its `:timeout` does not fire, and because MuonTrap ties the child to the
  # port OWNER that hang lasts as long as the GenServer. Unbounded is acceptable
  # here only because these run once at boot, never on a call path.
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

  if Mix.target() == :host do
    # Nerves.Runtime is targets-only; `:dist_cookie_path` is unset on host too,
    # so start_link/1 returns :ignore and this never runs outside tests.
    defp default_reboot, do: :ok
  else
    defp default_reboot, do: Nerves.Runtime.reboot()
  end
end
