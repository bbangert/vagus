defmodule Vagus.Dist do
  @moduledoc """
  Runtime Erlang distribution, gated by the presence of a cookie file.

  Every board ships this module; no board distributes until
  `config :vagus, :dist_cookie_path` points at a file that exists. An agent
  with SSH access runs `Vagus.Dist.enable/0` and gets back a node name and a
  cookie; `Vagus.Dist.disable/0` closes the gate again.

  ## Why a file rather than a config flag

  There is no `config/runtime.exs` in this umbrella, so a config-only switch
  would need a firmware build and an OTA to flip — the exact cost this
  feature exists to avoid. The cookie file is both the secret and the gate:
  present means distribute, absent means stay a single node.

  Presence is the switch, so `touch`ing the file is a gesture this module has
  to answer for. An **empty or whitespace-only** file mints a fresh cookie
  over itself, which is what that gesture is asking for. A file with content
  that is not 64 lowercase hex characters is **refused** —
  `{:error, :cookie_malformed}`, board stays idle — rather than adopted,
  because adopting it once yielded a live node with the cookie `:''`.

  ## Two cookie files, two modes

  `/data/vagus.cookie` is 0600: this module minted it and re-reads it on every
  boot. `$HOME/.erlang.cookie` (`/root/.erlang.cookie` on Nerves) is 0400,
  because `auth:read_cookie/0` refuses anything looser. The second file is
  written deliberately — see `start_distribution/2` — and `disable/0` removes
  both.

  ## Why only physical interfaces

  Distribution binds exactly one address (`:inet_dist_use_interface`), so the
  choice has to be deterministic. Candidates are the VintageNet-managed
  interfaces whose names look physical (`eth*`/`wlan*`/`usb*`), preferred
  `eth0` → `wlan0` → `usb0`. An overlay (Tailscale, WireGuard, any future
  tunnel) is brought up by its own daemon and never appears in
  `VintageNet.configured_interfaces/0`, so it is excluded by construction
  rather than by a denylist that would rot. Without this, the dist port
  wildcard-binds; what keeps an add-on container out is the cookie's secrecy,
  not the bind — see `docs/divergences.md`.

  ## Agent runbook

  **1. Open the gate**, over the SSH access you already have:

      iex> Vagus.Dist.enable()
      {:ok, %{node: :"vagus@192.168.2.58", cookie: "a1b2c3..."}}

  `status/0` answers the same question at any point, including before you
  start: `alive?`, `node`, `cookie_present?`, `address`, `ifname`, `ports`,
  and `drift`.

  **2. Connect from the dev host.** TCP 4369 (epmd) and 9100-9105 (the pinned
  distribution range) must be open to the board; nothing else is needed, and
  no DNS — the node name is a bare IPv4 longname, which does no lookup.

      iex --name agent@<your-host-ip> --cookie a1b2c3... -S mix
      iex> board = :"vagus@192.168.2.58"
      iex> Node.connect(board)
      true
      iex> :erpc.call(board, Vagus.Dist, :status, [], :infinity)

  **3. Wrap bulk or long work in `run/1`**, on the board side of the call:

      iex> :erpc.call(board, Vagus.Dist, :run, [fn -> collect_everything() end], :infinity)

  A plain `:erpc.call` returning megabytes can suspend on distribution
  buffer flow-control and blow its own timeout — see `run/1`. A small MFA
  does not need it.

  **4. Close the gate** when the work is done. Distribution is an
  unauthenticated-root-equivalent surface on the LAN segment (see
  `docs/divergences.md`); leaving it open is the mistake this call exists to
  prevent. `disable/0` can fail — `{:error, {:disable_incomplete, _}}` means
  the node may still be up and **both cookie files are still on disk**, which
  is deliberate: see `stop_distribution/1`.

      iex> Vagus.Dist.disable()
      :ok

  The node name embeds the address, so it is fixed at start. If the address
  changes the node keeps its old name; `status/0` reports the drift. Give
  test boards a DHCP reservation, or `disable/0` then `enable/0` to re-name.
  """

  use GenServer

  require Logger

  import Bitwise, only: [band: 2]

  @port_min 9100
  @port_max 9105
  @epmd_port 4369
  @mdns_service_id :vagus_epmd

  # `eth*` before `wlan*` before `usb*`. usb0 is last but deliberately still
  # eligible: it is the only interface a board has on a bench with a USB
  # cable and no switch, and it reaches exactly the attached host.
  @physical_name ~r/^(eth|wlan|usb)(\d+)$/
  @prefix_rank %{"eth" => 0, "wlan" => 1, "usb" => 2}

  # Exactly what mint/1 writes: 32 bytes, lowercase hex.
  @cookie_format ~r/\A[0-9a-f]{64}\z/

  @cookie_mode 0o600
  @erlang_cookie_mode 0o400

  @retry_ms 5_000
  @retry_max_ms 60_000
  @retry_attempts 10
  @epmd_kill_retry_ms 250

  @type status :: %{
          alive?: boolean(),
          node: node() | nil,
          cookie_present?: boolean(),
          address: :inet.ip4_address() | nil,
          ifname: String.t() | nil,
          ports: Range.t(),
          drift: String.t() | nil
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
  Mints the cookie if absent, then brings the node up. Idempotent.
  """
  @spec enable(GenServer.server()) ::
          {:ok, %{node: node(), cookie: String.t()}} | {:error, term()}
  def enable(server \\ __MODULE__), do: GenServer.call(server, :enable, 30_000)

  @doc """
  Closes the gate: withdraws the mDNS advertisement, stops `net_kernel`,
  kills epmd, and deletes both cookie files.

  `{:error, {:disable_incomplete, _}}` means at least one of those did not
  happen. The cookie files are then left in place on purpose — see
  `stop_distribution/1` — and `status/0` keeps reporting the node as up if it
  still is.
  """
  @spec disable(GenServer.server()) :: :ok | {:error, term()}
  def disable(server \\ __MODULE__), do: GenServer.call(server, :disable, 30_000)

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Runs `fun` in a process flagged `async_dist`, returning its value.

  Distribution buffer flow-control suspends a sending process when the
  outbound buffer fills, which can defer a long `:erpc.call` past its
  timeout — the failure mode for the multi-minute, multi-megabyte runs this
  feature exists to serve. `async_dist` makes those sends buffer instead of
  blocking. Wrap bulk transfers in it; a small MFA does not need it.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    Task.async(fn ->
      Process.flag(:async_dist, true)
      fun.()
    end)
    |> Task.await(:infinity)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      cookie_path: Keyword.fetch!(opts, :cookie_path),
      node: nil,
      address: nil,
      ifname: nil,
      drift: nil,
      attempt: 0,
      retry_ref: nil,
      gave_up?: false,
      subscribed?: false,
      seams: seams(opts)
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    {:noreply, boot(state)}
  end

  @impl GenServer
  def handle_call(:enable, _from, state) do
    # Deliberately NOT wrapped the way try_boot_start/1 is: an interactive
    # caller should see a raise, and a crash here restarts a GenServer whose
    # supervisor did not ask the app to come down.
    with {:ok, cookie} <- read_or_mint(state),
         {:ok, state} <- start_distribution(state, cookie) do
      state = state |> settled() |> ensure_subscribed()
      {:reply, {:ok, %{node: state.node, cookie: cookie}}, state}
    else
      # The bookkeeping IS repaired — state.node names the live node and
      # status/0 carries the drift — but the caller must not be handed a cookie
      # that will not authenticate. Rotating the secret under a running node
      # takes disable/0 then enable/0; the node name is immutable anyway.
      {:cookie_mismatch, state} -> {:reply, {:error, :cookie_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disable, _from, state) do
    case stop_distribution(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, {:disable_incomplete, reason}}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      alive?: state.node != nil,
      node: state.node,
      cookie_present?: File.exists?(state.cookie_path),
      address: state.address,
      ifname: state.ifname,
      ports: @port_min..@port_max,
      drift: state.drift
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_info({VintageNet, _property, _old, _new, _meta}, state) do
    {:noreply, on_address_event(state)}
  end

  def handle_info(:retry_start, %{node: nil} = state) do
    {:noreply, try_boot_start(%{state | retry_ref: nil})}
  end

  # Already up — a retry raced a successful address event.
  def handle_info(:retry_start, state), do: {:noreply, %{state | retry_ref: nil}}

  ## Boot path

  # The guard wraps the WHOLE path, not just the start call. `ensure_subscribed/1`
  # reaches VintageNet, and a raise from it escapes `handle_continue/2` into the
  # top-level supervisor's restart budget — which is shared with every other
  # child. The cookie file is still present on the next boot, so it raises again:
  # on a fresh flash that is a crash loop and a `startup_guard` rollback across
  # the fleet. Retrying is the recovery, because "VintageNet is not up yet" is
  # exactly the transient this hits.
  defp boot(state) do
    case guarded(fn -> attempt_boot(state) end) do
      {:error, reason} -> schedule_retry(state, reason)
      booted -> booted
    end
  end

  defp attempt_boot(state) do
    if File.exists?(state.cookie_path) do
      state |> ensure_subscribed() |> try_boot_start()
    else
      state
    end
  end

  # Best-effort by design: a board that cannot resolve an address at boot
  # stays idle and reachable over SSH, where `enable/0` still works.
  defp try_boot_start(state) do
    case guarded(fn -> read_or_mint(state) end) do
      {:ok, cookie} ->
        case guarded(fn -> start_distribution(state, cookie) end) do
          {:ok, state} -> settled(state)
          # Adopting the live node is still the right bookkeeping, and retrying
          # cannot fix a cookie mismatch — only an operator can.
          {:cookie_mismatch, state} -> settled(state)
          {:error, reason} -> schedule_retry(state, reason)
        end

      {:error, reason} ->
        Logger.warning("Vagus.Dist: cookie unusable (#{inspect(reason)}), staying idle")
        state
    end
  end

  # Turns any raise on the boot path into an idle board rather than a dead app.
  #
  # The formatting is deliberate and MEASURED: an Erlang stacktrace carries each
  # frame's ARGUMENTS, not just its arity, for `function_clause` and for BIF
  # `badarg` — and the cookie is an argument the whole length of
  # `start_distribution/2`. `Exception.format/3` renders them, which would print
  # the secret into RingLogger at `:error` level. So the banner is built without
  # the stacktrace (no blame-time argument expansion) and every frame is reduced
  # to its arity before it is formatted.
  defp guarded(fun) do
    fun.()
  rescue
    exception ->
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

  defp schedule_retry(state, reason) do
    state = cancel_retry(state)
    attempt = state.attempt + 1

    if attempt > @retry_attempts do
      Logger.warning(
        "Vagus.Dist: giving up after #{@retry_attempts} attempts (#{inspect(reason)}); " <>
          "an address event or Vagus.Dist.enable/0 can still start it"
      )

      %{state | attempt: attempt, gave_up?: true}
    else
      delay = min(@retry_ms * 2 ** (attempt - 1), @retry_max_ms)

      Logger.info(
        "Vagus.Dist: not starting yet (#{inspect(reason)}), attempt #{attempt}, " <>
          "retrying in #{delay}ms"
      )

      %{state | attempt: attempt, retry_ref: Process.send_after(self(), :retry_start, delay)}
    end
  end

  # Without this, address flapping stacks concurrent pending `:retry_start`
  # messages and burns the 10-attempt budget in wall-clock time bearing no
  # relation to the backoff schedule. The selective receive drops a timer that
  # already fired: it is the message this cancel exists to prevent, and nothing
  # else sends it.
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

  defp settled(state), do: %{cancel_retry(state) | attempt: 0, gave_up?: false}

  # An address event either starts a node that has not started yet, or —
  # once alive — reports drift. The node name embeds the address and is
  # immutable, so re-binding would silently drop in-flight calls; a stale
  # name is at least diagnosable.
  defp on_address_event(%{node: nil} = state) do
    # A fresh event is a legitimate trigger, so a spent budget must not carry
    # over: after a give-up the next real cable plug would otherwise get zero
    # attempts. Cancelling first is what keeps a flap from stacking timers.
    state |> cancel_retry() |> reset_after_give_up() |> boot()
  end

  defp on_address_event(state) do
    case resolve_address(state) do
      {:ok, ifname, address} when ifname == state.ifname and address == state.address ->
        %{state | drift: nil}

      {:ok, ifname, address} ->
        drift =
          "bound to #{ifname} #{ip_to_string(state.address)} as #{state.node}, but " <>
            "#{ifname} #{ip_to_string(address)} is now preferred; node name is immutable"

        Logger.warning("Vagus.Dist: #{drift}")
        %{state | drift: drift}

      {:error, reason} ->
        drift =
          "bound to #{ip_to_string(state.address)} as #{state.node}, but no " <>
            "physical address resolves now (#{inspect(reason)})"

        Logger.warning("Vagus.Dist: #{drift}")
        %{state | drift: drift}
    end
  end

  defp reset_after_give_up(%{gave_up?: true} = state), do: %{state | attempt: 0, gave_up?: false}
  defp reset_after_give_up(state), do: state

  ## Cookie store

  # path is config-derived (app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_or_mint(state) do
    case File.stat(state.cookie_path) do
      # `touch /data/vagus.cookie` is the exact gesture the moduledoc and
      # config/target.exs invite by calling the file's presence the switch, so
      # an empty file mints — whatever its mode, because there is no secret in
      # it to adopt.
      {:ok, %File.Stat{size: 0}} -> mint(state)
      {:ok, %File.Stat{mode: mode}} -> read_existing(state, band(mode, 0o777))
      {:error, :enoent} -> mint(state)
      {:error, reason} -> {:error, {:cookie_unreadable, reason}}
    end
  end

  # Mode first, and refuse WITHOUT reading. Adopting a secret out of a file
  # whose mode cannot be vouched for is the thing being guarded against, so
  # reading it to find that out defeats the guard.
  defp read_existing(_state, mode) when mode != @cookie_mode,
    do: {:error, {:mode_unproven, mode}}

  # path is config-derived (app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_existing(state, _mode) do
    case File.read(state.cookie_path) do
      {:ok, contents} -> validate(state, String.trim(contents))
      {:error, reason} -> {:error, {:cookie_unreadable, reason}}
    end
  end

  # Whitespace-only is the same operator gesture as an empty file. Anything
  # else that is not what mint/1 writes is refused rather than guessed at: it
  # would otherwise reach `String.to_atom/1` on the never-crash boot path,
  # where the 255-character atom limit is a `SystemLimitError`.
  defp validate(state, ""), do: mint(state)

  defp validate(_state, cookie) do
    if Regex.match?(@cookie_format, cookie),
      do: {:ok, cookie},
      else: {:error, :cookie_malformed}
  end

  # path is config-derived (app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp mint(state) do
    cookie = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    case File.mkdir_p(Path.dirname(state.cookie_path)) do
      :ok -> mint_at(state, cookie)
      {:error, reason} -> {:error, {:cookie_unwritable, reason}}
    end
  end

  # path is config-derived (app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp mint_at(state, cookie) do
    with :ok <- write_secret(state, state.cookie_path, cookie, @cookie_mode),
         :ok <- verify_mode(state.cookie_path, @cookie_mode) do
      {:ok, cookie}
    else
      {:error, {:cookie_unwritable, _}} = unwritable ->
        unwritable

      {:error, reason} ->
        # A cookie whose mode cannot be proven must not survive to the next
        # boot, where read_or_mint/1 refuses it outright instead of re-minting.
        _ = File.rm(state.cookie_path)
        {:error, reason}
    end
  end

  # Created at its final mode BEFORE any content exists, in the same directory,
  # then renamed into place. `File.write` followed by `File.chmod` leaves a
  # window in which the cookie is world-readable, and this runs as root, so a
  # symlink planted at the target would be followed; `:exclusive` refuses an
  # existing temp, symlink or not. The rename is what makes a torn write
  # impossible — a half-written file is read as the whole secret next boot.
  #
  # path is config-derived (app env) or $HOME-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp write_secret(state, path, contents, mode) do
    tmp = path <> ".tmp"
    _ = File.rm(tmp)

    case File.open(tmp, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        # `File.close/1` is where a buffered write actually fails (`:enospc` on
        # /data), so its result is part of the write, not cleanup: without it a
        # truncated cookie gets renamed into place and only its MODE is proven.
        written =
          with :ok <- state.seams.chmod_fun.(tmp, mode),
               :ok <- IO.binwrite(io, contents) do
            File.close(io)
          else
            error ->
              File.close(io)
              error
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

  # sobelow_skip ["Traversal.FileModule"]
  defp discard_secret(tmp, reason) do
    _ = File.rm(tmp)
    {:error, {:cookie_unwritable, reason}}
  end

  # The mode is set AND read back, as `Vagus.SSHAccess` does for its private
  # key: a silently-failed `File.chmod/2` would leave a world-readable cookie,
  # and an unverifiable-mode cookie is worse than no distribution at all.
  #
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

  ## Address resolution

  @doc false
  @spec resolve_address(map()) :: {:ok, String.t(), :inet.ip4_address()} | {:error, :no_address}
  def resolve_address(state) do
    state.seams.configured_interfaces_fun.()
    |> candidates()
    |> Enum.find_value(fn ifname ->
      with true <- connected?(state, ifname),
           {:ok, address} <- first_ipv4(addresses(state, ifname)) do
        {ifname, address}
      else
        _not_usable -> nil
      end
    end)
    |> case do
      {ifname, address} -> {:ok, ifname, address}
      nil -> {:error, :no_address}
    end
  end

  defp candidates(ifnames) do
    ifnames
    |> Enum.filter(&Regex.match?(@physical_name, &1))
    |> Enum.sort_by(&rank/1)
  end

  defp rank(ifname) do
    [_, prefix, index] = Regex.run(@physical_name, ifname)
    {Map.fetch!(@prefix_rank, prefix), String.to_integer(index)}
  end

  # `:lan` is enough. Deliberately NOT the aggregate `["connection"]`
  # property `Vagus.Backend.Network.VintageNet` ranks by: that is a
  # best-of-all-interfaces roll-up, so a `wlan0` that reached `:internet`
  # would beat a wired-but-WAN-less `eth0`. A board with no WAN still has to
  # be reachable.
  defp connected?(state, ifname) do
    state.seams.vintage_net_fun.(["interface", ifname, "connection"], :disconnected) !=
      :disconnected
  end

  defp addresses(state, ifname) do
    state.seams.vintage_net_fun.(["interface", ifname, "addresses"], [])
  end

  defp first_ipv4(addresses) do
    addresses
    |> Enum.find_value(fn
      %{address: {_, _, _, _} = ip} -> if routable?(ip), do: ip
      _not_ipv4 -> nil
    end)
    |> case do
      nil -> {:error, :no_address}
      ip -> {:ok, ip}
    end
  end

  defp routable?({127, _, _, _}), do: false
  defp routable?({169, 254, _, _}), do: false
  defp routable?(_ip), do: true

  ## Start / stop sequence

  # Idempotent but not blind: being up already is no reason to report a cookie as
  # applied when the live node does not accept it.
  defp start_distribution(%{node: node} = state, cookie) when node != nil do
    if cookie_mismatch?(state, cookie), do: {:cookie_mismatch, state}, else: {:ok, state}
  end

  defp start_distribution(state, cookie) do
    # A GenServer crash-restart rebuilds state.node as nil while net_kernel,
    # epmd and the mDNS advertisement all survive, so the guard above cannot
    # fire and none of the bring-up below is wanted. Cheaper to ask than to
    # discover it from net_kernel.start's return.
    if state.seams.alive_fun.() do
      reconcile(state, cookie)
    else
      bring_up(state, cookie)
    end
  end

  # The ordering is load-bearing and not the obvious one:
  #
  #   * ports and `:inet_dist_use_interface` first — `inet_tcp_dist` reads both
  #     from the kernel app env at LISTEN time, and `use_interface` is a forced
  #     option `merge_options/3` cannot override.
  #   * epmd next — it only auto-starts when the VM was booted with
  #     `-name`/`-sname`, and Nerves deliberately passes neither.
  #   * `$HOME/.erlang.cookie` before net_kernel — MEASURED on OTP 29:
  #     `set_cookie/1` before net_kernel raises `:distribution_not_started`, and
  #     starting net_kernel mints a RANDOM cookie into that file when it is
  #     absent. Setting the cookie afterwards works, but leaves a window in
  #     which the node is live on the LAN authenticating with a secret we did
  #     not choose; pre-seeding closes it, because `auth:init_cookie/0` falls
  #     through to `read_cookie/0` on that file.
  #   * `set_cookie` after the start anyway — it is the only thing that can
  #     repair a pre-seed that landed on a path `auth` does not read.
  #   * the `get_cookie` read-back LAST. A node alive under a cookie that is
  #     not ours is the one state this must never leave behind, so the mismatch
  #     stops the node rather than merely reporting it.
  defp bring_up(state, cookie) do
    with {:ok, ifname, address} <- resolve_address(state),
         :ok <- pin_ports(state),
         :ok <- state.seams.put_env_fun.(:inet_dist_use_interface, address),
         :ok <- start_epmd(state, address),
         :ok <- seed_erlang_cookie(state, cookie),
         name = node_name(address),
         {:ok, _pid} <- state.seams.net_kernel_start_fun.(name, %{name_domain: :longnames}),
         :ok <- apply_cookie(state, cookie) do
      advertise(state)
      Logger.info("Vagus.Dist: #{name} alive on #{ifname}, dist ports #{@port_min}-#{@port_max}")
      {:ok, %{state | node: name, address: address, ifname: ifname, drift: nil}}
    else
      # Measured: net_kernel answers this even under a DIFFERENT name, so a
      # restart that also changed address lands here. Retrying it to the
      # 10-attempt give-up while status/0 calls a live node down is the
      # permanent desync this replaces.
      {:error, {:already_started, _pid}} -> reconcile(state, cookie)
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # `Node.self/0` is authoritative here, not anything this module remembers:
  # the node is up, and the only question is what the bookkeeping should say
  # about it. A live name we would not have chosen is drift, not a failure —
  # renaming is impossible and pretending would be worse.
  defp reconcile(state, cookie) do
    case state.seams.self_node_fun.() do
      :nonode@nohost ->
        {:error, :alive_without_node}

      live ->
        address = node_address(live)
        mismatch? = cookie_mismatch?(state, cookie)

        state = %{
          state
          | node: live,
            address: address,
            ifname: ifname_for(state, address),
            drift: reconcile_drift(state, live, mismatch?)
        }

        Logger.info("Vagus.Dist: reconciled to already-live node #{live}")
        if mismatch?, do: {:cookie_mismatch, state}, else: {:ok, state}
    end
  end

  defp reconcile_drift(state, live, mismatch?) do
    [name_drift(state, live), cookie_drift(state, mismatch?)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        nil

      drifts ->
        drift = Enum.join(drifts, "; ")
        Logger.warning("Vagus.Dist: #{drift}")
        drift
    end
  end

  defp name_drift(state, live) do
    case resolve_address(state) do
      {:ok, ifname, address} ->
        renamed(live, ifname, address, node_name(address))

      {:error, reason} ->
        "live node is #{live}, but no physical address resolves now (#{inspect(reason)})"
    end
  end

  defp renamed(live, _ifname, _address, wanted) when live == wanted, do: nil

  defp renamed(live, ifname, address, wanted) do
    "live node is #{live}, but #{ifname} #{ip_to_string(address)} would now name it " <>
      "#{wanted}; the node name is immutable"
  end

  # Surfaced, never acted on: stopping a live node from a bookkeeping path
  # would drop whatever erpc call is in flight over it. The mismatch means the
  # file was replaced under a running node, and the operator needs to know
  # which secret still authenticates it.
  defp cookie_drift(_state, false), do: nil

  defp cookie_drift(state, true) do
    "the live node authenticates with a cookie that is not the one in #{state.cookie_path}"
  end

  defp cookie_mismatch?(state, cookie), do: state.seams.get_cookie_fun.() != cookie_atom(cookie)

  defp ifname_for(_state, nil), do: nil

  defp ifname_for(state, address) do
    state.seams.configured_interfaces_fun.()
    |> candidates()
    |> Enum.find(&match?({:ok, ^address}, first_ipv4(addresses(state, &1))))
  end

  defp node_address(name) do
    with [_vagus, host] <- String.split(Atom.to_string(name), "@", parts: 2),
         {:ok, ip} <- :inet.parse_ipv4_address(String.to_charlist(host)) do
      ip
    else
      _not_an_ipv4_longname -> nil
    end
  end

  defp apply_cookie(state, cookie) do
    atom = cookie_atom(cookie)
    state.seams.set_cookie_fun.(atom)

    if state.seams.get_cookie_fun.() == atom do
      :ok
    else
      abandon(state)
    end
  end

  # Discarding the stop here would be the same fail-open B3 fixed in
  # stop_distribution/1, in the one place it matters most: the whole point of
  # the read-back is that a node alive under a cookie we did not choose must not
  # survive, so a stop that did not take has to say so rather than be reported
  # as a clean refusal.
  defp abandon(state) do
    state.seams.net_kernel_stop_fun.()

    if state.seams.alive_fun.() do
      {:error, {:cookie_not_applied, :still_alive}}
    else
      {:error, :cookie_not_applied}
    end
  end

  # One atom per enable, out of a file this module minted and then matched
  # against @cookie_format, so the 255-character limit is unreachable; the node
  # name is built from an `:inet` address, not from anything read.
  # sobelow_skip ["DOS.StringToAtom"]
  defp cookie_atom(cookie), do: String.to_atom(cookie)

  # sobelow_skip ["DOS.BinToAtom"]
  defp node_name(address), do: :"vagus@#{ip_to_string(address)}"

  defp advertise(state) do
    # Only after the node is up: advertising a node that is not listening yet
    # invites a connection that cannot be served.
    state.seams.mdns_add_fun.(%{
      id: @mdns_service_id,
      protocol: "epmd",
      transport: "tcp",
      port: @epmd_port
    })
  end

  # Pinned so the range is firewallable and the device gate can assert on it;
  # without `:inet_dist_use_interface` above, the listener would also
  # wildcard-bind.
  defp pin_ports(state) do
    with :ok <- state.seams.put_env_fun.(:inet_dist_listen_min, @port_min) do
      state.seams.put_env_fun.(:inet_dist_listen_max, @port_max)
    end
  end

  # It has to be launched by hand, from the release's own ERTS — it is on no
  # PATH the BEAM inherits. `ERL_EPMD_ADDRESS` keeps it off the wildcard; epmd
  # always adds `127.0.0.1` implicitly.
  defp start_epmd(state, address) do
    with :ok <- clear_foreign_epmd(state) do
      case state.seams.epmd_fun.(["-daemon"], [{"ERL_EPMD_ADDRESS", ip_to_string(address)}]) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:epmd_failed, status, output}}
      end
    end
  end

  # `epmd -daemon` exits 0 when another epmd already holds the port: it simply
  # does nothing, `ERL_EPMD_ADDRESS` is silently ignored, and the surviving
  # daemon may be wildcard-bound — quietly defeating half the reason this
  # module pins anything. Nerves starts no epmd of its own, so a live one is a
  # prior `enable/0`, possibly at a different address; the node is not alive
  # (checked above), so `-kill` should be accepted.
  defp clear_foreign_epmd(state) do
    {output, _status} = state.seams.epmd_fun.(["-names"], [])
    if epmd_running?(output), do: kill_foreign_epmd(state), else: :ok
  end

  # The exit status of `epmd -names` is not consistent across OTP versions when
  # it cannot reach a daemon, so match the banner it prints when it can.
  defp epmd_running?(output), do: String.contains?(output, "up and running")

  defp kill_foreign_epmd(state) do
    case kill_epmd(state) do
      :ok ->
        Logger.warning("Vagus.Dist: replaced a pre-existing epmd of unknown binding")
        :ok

      # Refusing is the point. A surviving epmd this module did not launch may
      # be bound to the wildcard and there is no way to tell from here, so
      # starting a node behind it would ship exactly the exposure the pinning
      # exists to prevent.
      {:error, reason} ->
        {:error, {:epmd_not_ours, reason}}
    end
  end

  defp seed_erlang_cookie(state, cookie) do
    case state.seams.erlang_cookie_path_fun.() do
      {:ok, path} ->
        # No mode read-back here, because a wrong mode cannot pass silently:
        # `auth:check_attributes/4` rejects any cookie file with a group or
        # other permission bit set (`Mode band 8#077`), and `auth`'s init —
        # which runs as part of `net_kernel.start`, not before it — then calls
        # `erlang:error/1` rather than falling back. A too-loose file therefore
        # FAILS the start outright, where `bring_up/2`'s `with` surfaces it.
        # Minting only ever happens on `enoent` (`auth:read_cookie/0`), which is
        # the window this pre-seed closes.
        write_secret(state, path, cookie, @erlang_cookie_mode)

      {:error, reason} ->
        {:error, {:erlang_cookie_path, reason}}
    end
  end

  # Deliberately NOT gated on `state.node`: after a GenServer crash-restart the
  # node can be live while state.node is nil, and disable/0 is then the only
  # way back. Keep it ungated.
  defp stop_distribution(state) do
    mdns = withdraw(state)
    net_kernel = state.seams.net_kernel_stop_fun.()
    epmd = kill_epmd(state)

    # `Node.alive?/0` decides, not either return value: `net_kernel.stop/0`
    # answers `{:error, not_allowed | not_found}` and this module used to
    # hard-code `:ok` over it, and `epmd -kill` exits non-zero on the
    # deregistration race kill_epmd/1 retries through.
    alive? = state.seams.alive_fun.()

    errors =
      [if(alive?, do: {:still_alive, net_kernel}), reason_of(epmd), reason_of(mdns)]
      |> Enum.reject(&is_nil/1)

    finish_stop(errors, if(alive?, do: state, else: cleared(state)))
  end

  # Both cookie files go LAST and only on a clean stop. Deleting them over a
  # node that is still up destroys the only record of the secret that still
  # authenticates it, while status/0 reports the gate shut — the worst
  # available outcome, and the one this ordering exists to prevent.
  defp finish_stop([], state) do
    [delete_cookie(state), delete_erlang_cookie(state)]
    |> Enum.map(&reason_of/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> {:ok, state}
      errors -> {:error, errors, state}
    end
  end

  defp finish_stop(errors, state) do
    Logger.warning("Vagus.Dist: disable incomplete (#{inspect(errors)}); cookies left in place")
    {:error, errors, state}
  end

  defp reason_of(:ok), do: nil
  defp reason_of({:error, reason}), do: reason

  # `disable/0` promises `{:error, {:disable_incomplete, _}}` covers the
  # withdrawal, so the result has to be threaded rather than dropped — and
  # `MdnsLite.remove_mdns_service/1` exits when its `TableServer` is down, which
  # would otherwise take out the caller mid-teardown, after net_kernel has
  # already been stopped.
  defp withdraw(state) do
    state.seams.mdns_remove_fun.(@mdns_service_id)
  catch
    kind, reason -> {:error, {:mdns_not_withdrawn, kind, reason}}
  end

  defp cleared(state) do
    %{
      cancel_retry(state)
      | node: nil,
        address: nil,
        ifname: nil,
        drift: nil,
        attempt: 0,
        gave_up?: false
    }
  end

  # Safe only after net_kernel deregistered: epmd refuses to die while a node
  # is still registered with it, and that deregistration is asynchronous, so
  # the first attempt losing the race is normal rather than a failure.
  defp kill_epmd(state) do
    case state.seams.epmd_fun.(["-kill"], []) do
      {_output, 0} ->
        :ok

      {_output, _status} ->
        state.seams.sleep_fun.(@epmd_kill_retry_ms)

        case state.seams.epmd_fun.(["-kill"], []) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:epmd_kill_failed, status, output}}
        end
    end
  end

  defp delete_cookie(state), do: remove(state.cookie_path)

  defp delete_erlang_cookie(state) do
    case state.seams.erlang_cookie_path_fun.() do
      # Nothing was ever written, so nothing is left behind.
      {:error, _no_home} -> :ok
      {:ok, path} -> remove(path)
    end
  end

  # path is config-derived (app env) or $HOME-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp remove(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Vagus.Dist: #{path} not removed (#{inspect(reason)})")
        {:error, {:cookie_not_removed, path, reason}}
    end
  end

  # Per-interface `addresses`, never the aggregate `["connection"]`: that
  # roll-up reports ready on interfaces this feature refuses to bind. Kept
  # live after the node is up so drift is noticed; a duplicate subscribe
  # would double every event, hence the flag.
  defp ensure_subscribed(%{subscribed?: true} = state), do: state

  defp ensure_subscribed(state) do
    state.seams.configured_interfaces_fun.()
    |> candidates()
    |> Enum.each(&state.seams.subscribe_fun.(["interface", &1, "addresses"]))

    %{state | subscribed?: true}
  end

  defp ip_to_string(nil), do: "nil"
  defp ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()

  ## Seams
  #
  # Every OS- and network-touching edge is injectable so the whole module is
  # provable on host without ever starting real distribution. The VintageNet
  # and MdnsLite defaults are compile-time branched because neither dep
  # exists in the :host build (both come from nerves_pack, targets-only) —
  # same reason `Vagus.Engine.Manager` branches.
  #
  # A seam's default is the part tests cannot see, so where one wraps a raw
  # OTP call the test suite pins the shape that default has to satisfy.

  # The `&File.chmod/2` default below is a capture, not a call on a path from
  # anywhere; the paths it eventually receives are `:dist_cookie_path` and
  # `$HOME/.erlang.cookie`.
  # sobelow_skip ["Traversal.FileModule"]
  defp seams(opts) do
    %{
      chmod_fun: Keyword.get(opts, :chmod_fun, &File.chmod/2),
      configured_interfaces_fun:
        Keyword.get(opts, :configured_interfaces_fun, &default_configured_interfaces/0),
      vintage_net_fun: Keyword.get(opts, :vintage_net_fun, &default_property/2),
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &default_subscribe/1),
      mdns_add_fun: Keyword.get(opts, :mdns_add_fun, &default_mdns_add/1),
      mdns_remove_fun: Keyword.get(opts, :mdns_remove_fun, &default_mdns_remove/1),
      put_env_fun: Keyword.get(opts, :put_env_fun, &default_put_env/2),
      set_cookie_fun: Keyword.get(opts, :set_cookie_fun, &default_set_cookie/1),
      get_cookie_fun: Keyword.get(opts, :get_cookie_fun, &:erlang.get_cookie/0),
      erlang_cookie_path_fun: Keyword.get(opts, :erlang_cookie_path_fun, &erlang_cookie_path/0),
      net_kernel_start_fun: Keyword.get(opts, :net_kernel_start_fun, &:net_kernel.start/2),
      net_kernel_stop_fun: Keyword.get(opts, :net_kernel_stop_fun, &default_net_kernel_stop/0),
      alive_fun: Keyword.get(opts, :alive_fun, &Node.alive?/0),
      self_node_fun: Keyword.get(opts, :self_node_fun, &Node.self/0),
      epmd_fun: Keyword.get(opts, :epmd_fun, &default_epmd/2),
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    }
  end

  defp default_put_env(key, value) do
    Application.put_env(:kernel, key, value)
  end

  defp default_set_cookie(cookie) do
    :erlang.set_cookie(cookie)
    :ok
  end

  @doc false
  # Public only so the test suite can pin it without writing into the developer's
  # real home: this derivation is the single assumption the whole pre-seed rests
  # on. `auth` takes the path from `init:get_argument(home)`, NOT from the OS
  # environment, so that is what is asked first — the two coincide on Nerves
  # (erlinit sets `HOME=/root`) but only by convention. Never fall back to a
  # relative path: `auth` would read a different file, the node would come up
  # with an OTP-minted cookie, and the read-back in apply_cookie/2 would stop it
  # again for a reason that looks nothing like the cause.
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

  # Threaded, not discarded: `net_kernel.stop/0` answers
  # `{:error, not_allowed | not_found}` and hard-coding `:ok` over it is what
  # let disable/0 report a shut gate over a live node. `Node.alive?/0` is what
  # decides; this value is the diagnostic that says why.
  defp default_net_kernel_stop, do: :net_kernel.stop()

  # Not injectable: the binary is `:code.root_dir()`-relative and every
  # argument this module passes is a literal.
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
    # No VintageNet or MdnsLite in the :host build. `:dist_cookie_path` is
    # unset there too, so `start_link/1` returns `:ignore` and none of these
    # run outside tests, which inject their own seams.
    defp default_configured_interfaces, do: []
    defp default_property(_property, default), do: default
    defp default_subscribe(_property), do: :ok
    defp default_mdns_add(_service), do: :ok
    defp default_mdns_remove(_id), do: :ok
  else
    defp default_configured_interfaces, do: VintageNet.configured_interfaces()
    defp default_property(property, default), do: VintageNet.get(property, default)
    defp default_subscribe(property), do: VintageNet.subscribe(property)
    defp default_mdns_add(service), do: MdnsLite.add_mdns_service(service)
    defp default_mdns_remove(id), do: MdnsLite.remove_mdns_service(id)
  end
end
