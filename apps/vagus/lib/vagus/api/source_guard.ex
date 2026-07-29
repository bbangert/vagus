defmodule Vagus.API.SourceGuard do
  @moduledoc """
  Refuses Supervisor-API requests that didn't originate from this machine or
  the `hassio` bridge.

  ## Why the API needs this at all

  The API binds `0.0.0.0:80`, exactly as upstream does
  (`web.TCPSite(runner, host="0.0.0.0", port=80)`), but the two are not
  equally exposed: upstream's Supervisor is a **container**, so its `0.0.0.0`
  is the docker namespace — reachable from Core and add-ons and nothing else.
  Vagus is host-networked, so the same bind is reachable from the whole LAN.
  Matching upstream's code does not match upstream's blast radius, and since
  P2-A there is a route that answers without a token at all (an add-on's
  icon/logo — see `Vagus.API.Auth.unauthenticated?/1`).

  ## Why the allowlist is shaped the way it is

  The obvious predicate — "inside `172.30.32.0/23` plus loopback" — was the
  plan of record until it was measured, and it is **wrong**. Core runs
  `NetworkMode: "host"` and targets `172.30.32.2`, so the reasoning went that
  its packets carry a bridge address. On hardware they do not: every socket
  the API accepted from Core carried the board's **LAN** address.

      :erlang.ports()
      |> Enum.map(&{:inet.peername(&1), :inet.sockname(&1)})
      |> Enum.filter(&match?({{:ok, _}, {:ok, {_, 80}}}, &1))
      #=> peer {192,168,2,149} on sockname {172,30,32,2}:80

  `/proc/net/tcp` is no help here and actively misleads: the client row reads
  `172.30.32.1:<port>` while the server row for the same port reads
  `192.168.2.149:<port>`, i.e. something SNATs between the two sockets on one
  host. The accepting socket's own view — which is what `conn.remote_ip` is —
  is the only one that decides the request.

  So the allowlist is **loopback + the hassio subnet + every address bound on
  a local interface**. That admits Core, add-ons on the bridge, and anything
  running on the board, and refuses the rest of the LAN, which is the entire
  point.

  ## Freshness

  The local-address set is cached in `:persistent_term` and refreshed on a
  timer. It is deliberately *not* refreshed on a miss: a miss is the hostile
  case, and turning it into a syscall would hand a LAN attacker a cheap way
  to make the device work.

  The interval is therefore how long a newly-bound address stays refused,
  which matters most at boot, where it races DHCP. Measured on the Q6A: the
  guard's first read saw 2 addresses, the next tick saw 11, and every
  Core -> Supervisor call in between was refused. So the timer runs once a
  second for the first minute of uptime and settles to every 30s after — a
  syscall a second for a minute costs nothing, and the boot window closes to
  about a second.

  Gated by `config :vagus, :api_source_guard`, so `:host` and `:test` (which
  answer from `127.0.0.1` regardless) are unaffected and `start_link/1`
  returns `:ignore` rather than running a timer nothing consults — the same
  convention `Vagus.Addon.BootStarter` uses.
  """

  use GenServer

  require Logger

  @key {__MODULE__, :local_addresses}
  @refresh_ms 30_000

  # A cold boot races DHCP: the guard's first read happens while the LAN
  # interface may still be unconfigured, and until the address lands every
  # Core -> Supervisor call is refused. Measured on the Q6A — `init` saw 2
  # addresses, the 30s tick saw 11, and the refusals in between came from the
  # board's own address. So poll fast for the first minute of uptime, then
  # settle. This is a syscall, not a fetch; the cost is noise.
  @boot_refresh_ms 1_000
  @boot_fast_ticks 60

  def start_link(opts \\ []) do
    if enabled?() do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      # Say so out loud. The guard is off by default and only a target config
      # turns it on, so a dropped key would otherwise leave a LAN-exposed API
      # wide open with nothing in the boot log to show for it — the one
      # fail-open this design has, and it is a configuration one.
      Logger.info(
        "Vagus.API.SourceGuard: DISABLED (:api_source_guard unset) — " <>
          "the API answers any source address"
      )

      :ignore
    end
  end

  @doc """
  Records a refused request for the periodic summary.

  Counting rather than logging per refusal is deliberate: the caller is by
  definition unauthorised and can repeat at will, so a line each would let
  them push real evidence out of `RingLogger`'s ring. A `cast` also keeps the
  refusal path off `:persistent_term`, whose writes trigger a global scan —
  attacker-triggered global GC would be a worse bug than the noise.

  Safe to call when the guard is disabled (the process isn't running):
  `GenServer.cast/2` to an unregistered name is a no-op.
  """
  @spec record_refusal(:inet.ip_address() | nil) :: :ok
  def record_refusal(ip), do: GenServer.cast(__MODULE__, {:refused, ip})

  @doc "Whether the guard is switched on (`config :vagus, :api_source_guard`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:vagus, :api_source_guard, false) == true

  @doc """
  Whether `remote_ip` may talk to the API.

  Answers `true` for everything when the guard is disabled, so the check is
  safe to call unconditionally from the pipeline.
  """
  @spec allowed?(:inet.ip_address() | nil) :: boolean()
  def allowed?(nil), do: not enabled?()

  def allowed?(ip) do
    not enabled?() or loopback?(ip) or hassio?(ip) or local?(ip)
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # An IPv4 loopback arriving over a dual-stack listener.
  defp loopback?({0, 0, 0, 0, 0, 65_535, ab, cd}), do: loopback?(v4(ab, cd))
  defp loopback?(_ip), do: false

  # 172.30.32.0/23 — the /23 makes .32.x and .33.x both bridge addresses.
  defp hassio?({172, 30, third, _fourth}) when third in [32, 33], do: true
  defp hassio?({0, 0, 0, 0, 0, 65_535, ab, cd}), do: hassio?(v4(ab, cd))
  defp hassio?(_ip), do: false

  defp local?({0, 0, 0, 0, 0, 65_535, ab, cd} = ip) do
    MapSet.member?(local_addresses(), ip) or local?(v4(ab, cd))
  end

  defp local?(ip), do: MapSet.member?(local_addresses(), ip)

  # `::ffff:a.b.c.d` — an IPv4 peer seen through an IPv6 socket. Plug hands
  # it over in that form, so every rule has to see through it or a
  # dual-stack listener would refuse traffic the same rules admit on IPv4.
  defp v4(ab, cd),
    do: {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}

  defp local_addresses, do: :persistent_term.get(@key, MapSet.new())

  ## GenServer

  @impl GenServer
  def init(_opts) do
    refresh()

    Logger.info(
      "Vagus.API.SourceGuard: enabled — allowing loopback, 172.30.32.0/23 and " <>
        "#{MapSet.size(local_addresses())} local address(es)"
    )

    {:ok, %{refused: 0, sources: MapSet.new(), fast_ticks: @boot_fast_ticks},
     {:continue, :schedule}}
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    schedule(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:refused, ip}, state) do
    # Cap the sampled sources: the count is the useful number, and an
    # unbounded set is memory a spoofed-source flood could grow.
    sources =
      if MapSet.size(state.sources) < 5, do: MapSet.put(state.sources, ip), else: state.sources

    {:noreply, %{state | refused: state.refused + 1, sources: sources}}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    refresh()
    state = %{state | fast_ticks: max(state.fast_ticks - 1, 0)}
    schedule(state)

    # Summarised on every tick, including the fast boot ones. Refusals during
    # the boot window are the most diagnostic thing this module emits — they
    # are how the DHCP race above was found — so suppressing them to save a
    # line would hide the signal that matters most.
    {:noreply, report_refusals(state)}
  end

  defp report_refusals(%{refused: 0} = state), do: state

  defp report_refusals(state) do
    Logger.warning(
      "Vagus.API.SourceGuard: refused #{state.refused} request(s) from " <>
        "#{Enum.map_join(state.sources, ", ", &format_ip/1)}" <>
        if(MapSet.size(state.sources) >= 5, do: " and others", else: "")
    )

    %{state | refused: 0, sources: MapSet.new()}
  end

  # `:inet.ntoa/1` raises on nil, and a nil peer is a case `allowed?/1`
  # already names — formatting it must not turn a decided 403 into a 500.
  defp format_ip(nil), do: "unknown"
  defp format_ip(ip), do: to_string(:inet.ntoa(ip))

  defp schedule(%{fast_ticks: ticks}) when ticks > 0,
    do: Process.send_after(self(), :refresh, @boot_refresh_ms)

  defp schedule(_state), do: Process.send_after(self(), :refresh, @refresh_ms)

  # Only a write when the set actually changed: `:persistent_term.put/2`
  # triggers a global scan, and on a quiet device this runs every 30s forever.
  defp refresh do
    addresses = read_addresses()

    if addresses != local_addresses() do
      :persistent_term.put(@key, addresses)
      Logger.debug("Vagus.API.SourceGuard: #{MapSet.size(addresses)} local address(es)")
    end
  end

  defp read_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces, {:addr, addr} <- opts, into: MapSet.new(), do: addr

      {:error, reason} ->
        # Keep whatever we had rather than emptying the set — an empty set
        # would refuse Core until the next successful read.
        Logger.warning("Vagus.API.SourceGuard: getifaddrs failed (#{inspect(reason)})")
        local_addresses()
    end
  end
end
