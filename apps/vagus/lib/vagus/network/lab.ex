defmodule Vagus.Network.Lab do
  @moduledoc """
  Routes a target device wired to an extra NIC out through the board's
  primary interface: a static address on the NIC (VintageNet, never
  persisted) plus forward and masquerade rules in Vagus's nft table
  (`Vagus.Network.Nat.set_lab/2`). Nothing survives a reboot.

  Meant to be driven over distribution, e.g.
  `:erpc.call(board, Vagus.Network.Lab, :up, ["eth1", "10.42.0.1/24"])`;
  every public call returns a value, `{:error, :not_running}` when the
  server is absent (appliance flavor) and `{:error, :timeout}` when it is
  slow, never an exit.

  `up/3` refuses an interface VintageNet already holds a configuration for
  (`:configured`), and a cidr overlapping the `hassio` bridge's
  `172.30.32.0/23`, the primary interface's own subnet or another lab
  interface's (`:overlap`).

  When the nft load fails and so does the rollback's deconfigure, the NIC
  still carries its address: the entry is kept as `state: :broken`, no rules
  forward for it, and `up/3` returns `{:error, {:nat, reason, {:rollback,
  deconfigure_reason}}}`. `down/1` then deconfigures it, and `up/3` on it
  tries the whole bring-up again.
  """

  use GenServer

  require Logger

  alias Vagus.Network.Nat

  # The links that keep the board reachable. usb0 is the gadget link on the
  # rpi boards (config/rpi3_64.exs).
  @protected ["eth0", "wlan0", "lo", "usb0"]

  @bridge {{172, 30, 32, 0}, 23}

  # A configure, Nat's lock wait (~24 s at most) and a bounded nft load (10 s)
  # with its rollback load, and the deconfigure.
  @change_timeout_ms 60_000
  @status_timeout_ms 5_000

  # Survives this process but not the VM, which is exactly the "not
  # persisted across reboot" contract, and writes are rare (one per up/down).
  @state_key {__MODULE__, :ifaces}

  @type entry :: %{
          ifname: String.t(),
          cidr: String.t(),
          primary: String.t(),
          state: :up | :broken
        }

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &Vagus.Flavor.agent?/0) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @spec up(String.t(), String.t(), keyword()) ::
          :ok
          | {:error,
             :protected
             | :invalid_ifname
             | :invalid_cidr
             | :primary
             | :already_up
             | :nat_disabled
             | :configured
             | :overlap
             | :not_running
             | :timeout
             | {:vintage_net, term()}
             | {:nat, term()}
             | {:nat, term(), {:rollback, term()}}}
  def up(ifname, cidr, opts \\ []) do
    with :ok <- check_ifname(ifname),
         {:ok, address, prefix} <- parse_cidr(cidr) do
      call(opts, {:up, ifname, cidr, address, prefix}, @change_timeout_ms)
    end
  end

  @spec down(String.t(), keyword()) ::
          :ok
          | {:error, :not_up | :not_running | :timeout | {:nat, term()} | {:vintage_net, term()}}
  def down(ifname, opts \\ []), do: call(opts, {:down, ifname}, @change_timeout_ms)

  @spec status(keyword()) :: [entry()] | {:error, :not_running | :timeout}
  def status(opts \\ []), do: call(opts, :status, @status_timeout_ms)

  defp call(opts, msg, timeout) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), msg, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {{:nodedown, _}, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    state_key = Keyword.get(opts, :state_key, @state_key)

    state = %{
      up: :persistent_term.get(state_key, %{}),
      state_key: state_key,
      configure: Keyword.get(opts, :configure, &default_configure/2),
      deconfigure: Keyword.get(opts, :deconfigure, &default_deconfigure/1),
      primary: Keyword.get(opts, :primary, &default_primary/0),
      configured: Keyword.get(opts, :configured, &default_configured/0),
      addresses: Keyword.get(opts, :addresses, &default_addresses/1),
      nat_opts: Keyword.get(opts, :nat_opts, [])
    }

    {:ok, state, {:continue, :adopt}}
  end

  # A crashed instance's interfaces are still configured; render their rules
  # again so kernel and state agree. At boot both lists are empty and no nft
  # run is needed.
  @impl true
  def handle_continue(:adopt, state) do
    # A `:lab` in nat_opts would answer for itself instead of the stored list.
    stored = Nat.lab(Keyword.delete(state.nat_opts, :lab))

    if state.up != %{} or stored != [] do
      case Nat.set_lab(pairs(state.up), state.nat_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Vagus.Network.Lab: rules not re-rendered: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:up, ifname, cidr, address, prefix}, _from, state) do
    case Map.fetch(state.up, ifname) do
      {:ok, %{state: :broken}} -> do_up(ifname, cidr, address, prefix, state)
      {:ok, %{cidr: ^cidr}} -> {:reply, :ok, state}
      {:ok, _other} -> {:reply, {:error, :already_up}, state}
      :error -> do_up(ifname, cidr, address, prefix, state)
    end
  end

  def handle_call({:down, ifname}, _from, state) do
    case Map.pop(state.up, ifname) do
      {nil, _} ->
        {:reply, {:error, :not_up}, state}

      # No rules forward for it, so only the address is left to remove.
      {%{state: :broken}, rest} ->
        case state.deconfigure.(ifname) do
          :ok -> {:reply, :ok, store(state, rest)}
          {:error, reason} -> {:reply, {:error, {:vintage_net, reason}}, state}
        end

      {entry, rest} ->
        # Rules first, so forwarding stops before the address goes away. A
        # refused load keeps the entry as it was; a refused deconfigure after
        # the rules are gone marks it broken, so up/3 restores them.
        with {:nat, :ok} <- {:nat, Nat.set_lab(pairs(rest), state.nat_opts)},
             {:vintage_net, :ok} <- {:vintage_net, state.deconfigure.(ifname)} do
          {:reply, :ok, store(state, rest)}
        else
          {:nat, {:error, reason}} ->
            {:reply, {:error, {:nat, reason}}, state}

          {:vintage_net, {:error, reason}} ->
            broken = Map.put(state.up, ifname, %{entry | state: :broken})
            {:reply, {:error, {:vintage_net, reason}}, store(state, broken)}
        end
    end
  end

  def handle_call(:status, _from, state) do
    entries =
      state.up
      |> Enum.sort_by(fn {ifname, _} -> ifname end)
      |> Enum.map(fn {ifname, entry} -> Map.put(entry, :ifname, ifname) end)

    {:reply, entries, state}
  end

  defp do_up(ifname, cidr, address, prefix, state) do
    primary = state.primary.()

    with :ok <- check_primary(ifname, primary),
         :ok <- check_nat(state),
         :ok <- check_configured(ifname, state),
         :ok <- check_overlap(ifname, address, prefix, primary, state) do
      up = Map.put(state.up, ifname, %{cidr: cidr, primary: primary, state: :up})

      with {:vintage_net, :ok} <-
             {:vintage_net, state.configure.(ifname, config(address, prefix))},
           {:nat, :ok} <- {:nat, Nat.set_lab(pairs(up), state.nat_opts)} do
        {:reply, :ok, store(state, up)}
      else
        {:vintage_net, {:error, reason}} ->
          {:reply, {:error, {:vintage_net, reason}}, state}

        {:nat, {:error, reason}} ->
          case state.deconfigure.(ifname) do
            :ok ->
              {:reply, {:error, {:nat, reason}}, forget(state, ifname)}

            {:error, rollback} ->
              broken = Map.put(state.up, ifname, %{cidr: cidr, primary: primary, state: :broken})
              {:reply, {:error, {:nat, reason, {:rollback, rollback}}}, store(state, broken)}
          end
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp forget(state, ifname) do
    if Map.has_key?(state.up, ifname), do: store(state, Map.delete(state.up, ifname)), else: state
  end

  defp store(state, up) do
    :persistent_term.put(state.state_key, up)
    %{state | up: up}
  end

  defp check_primary(ifname, ifname), do: {:error, :primary}
  defp check_primary(_ifname, _primary), do: :ok

  # supervisor_nat is target-only: without it up would configure an address
  # that forwards nothing.
  defp check_nat(state) do
    if Keyword.get_lazy(state.nat_opts, :enabled, &Nat.enabled?/0),
      do: :ok,
      else: {:error, :nat_disabled}
  end

  # A broken entry's configuration is the one this server made.
  defp check_configured(ifname, state) do
    cond do
      Map.has_key?(state.up, ifname) -> :ok
      ifname in state.configured.() -> {:error, :configured}
      true -> :ok
    end
  end

  defp check_overlap(ifname, address, prefix, primary, state) do
    {:ok, ip} = :inet.parse_ipv4strict_address(String.to_charlist(address))

    # Broken entries count: their address is still on the NIC.
    labs =
      for {other, %{cidr: cidr}} <- state.up,
          other != ifname,
          {:ok, net, bits} <- [parse_cidr(cidr)],
          {:ok, net_ip} <- [to_ip(net)],
          do: {net_ip, bits}

    taken = [@bridge | ipv4_subnets(state.addresses.(primary))] ++ labs

    if Enum.any?(taken, fn {net, bits} -> overlap?(ip, prefix, net, bits) end),
      do: {:error, :overlap},
      else: :ok
  end

  defp ipv4_subnets(addresses) do
    for %{family: :inet, address: address} = entry <- List.wrap(addresses),
        {:ok, ip} <- [to_ip(address)],
        bits when is_integer(bits) <- [prefix_bits(entry)],
        do: {ip, bits}
  end

  defp to_ip({_, _, _, _} = ip), do: {:ok, ip}

  defp to_ip(ip) when is_binary(ip),
    do: :inet.parse_ipv4strict_address(String.to_charlist(ip))

  defp to_ip(_), do: :error

  defp prefix_bits(%{prefix_length: bits}) when bits in 0..32, do: bits

  defp prefix_bits(%{netmask: mask}) do
    case to_ip(mask) do
      {:ok, ip} -> ip |> to_int() |> Integer.digits(2) |> Enum.count(&(&1 == 1))
      :error -> nil
    end
  end

  defp prefix_bits(_), do: nil

  # Two prefixes overlap iff they agree on the shorter one's bits.
  defp overlap?(a, a_bits, b, b_bits) do
    shift = 32 - min(a_bits, b_bits)
    Bitwise.bsr(to_int(a), shift) == Bitwise.bsr(to_int(b), shift)
  end

  defp to_int({a, b, c, d}), do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d

  defp pairs(up) do
    for {ifname, %{state: :up} = e} <- Enum.sort(up), do: {ifname, e.primary}
  end

  defp config(address, prefix) do
    %{
      type: VintageNetEthernet,
      ipv4: %{method: :static, address: address, prefix_length: prefix}
    }
  end

  defp check_ifname(ifname) when is_binary(ifname) do
    cond do
      # hassio* is the app bridge and its anchor port.
      ifname in @protected or String.starts_with?(ifname, "hassio") -> {:error, :protected}
      Nat.valid_ifname?(ifname) -> :ok
      true -> {:error, :invalid_ifname}
    end
  end

  defp check_ifname(_), do: {:error, :invalid_ifname}

  defp parse_cidr(cidr) when is_binary(cidr) do
    with [ip, bits] <- String.split(cidr, "/"),
         {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(ip)),
         {prefix, ""} when prefix in 1..32 <- Integer.parse(bits) do
      {:ok, :inet.ntoa(address) |> to_string(), prefix}
    else
      _ -> {:error, :invalid_cidr}
    end
  end

  defp parse_cidr(_), do: {:error, :invalid_cidr}

  # vintage_net is target-only.
  if Mix.target() == :host do
    defp default_configure(_ifname, _config), do: {:error, :no_vintage_net}
    defp default_deconfigure(_ifname), do: {:error, :no_vintage_net}
    defp default_primary, do: "eth0"
    defp default_configured, do: []
    defp default_addresses(_ifname), do: []
  else
    defp default_configure(ifname, config),
      do: VintageNet.configure(ifname, config, persist: false)

    defp default_deconfigure(ifname), do: VintageNet.deconfigure(ifname, persist: false)
    defp default_primary, do: Vagus.Backend.Network.VintageNet.primary_interface() || "eth0"
    defp default_configured, do: VintageNet.configured_interfaces()

    defp default_addresses(ifname),
      do: VintageNet.get(["interface", ifname, "addresses"], [])
  end
end
