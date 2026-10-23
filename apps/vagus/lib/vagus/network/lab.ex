defmodule Vagus.Network.Lab do
  @moduledoc """
  Routes a target device wired to an extra NIC out through the board's
  primary interface: a static address on the NIC (VintageNet, never
  persisted) plus forward and masquerade rules in Vagus's nft table
  (`Vagus.Network.Nat.set_lab/2`). Nothing survives a reboot.

  Meant to be driven over distribution, e.g.
  `:erpc.call(board, Vagus.Network.Lab, :up, ["eth1", "10.42.0.1/24"])`.
  """

  use GenServer

  require Logger

  alias Vagus.Network.Nat

  @protected ["eth0", "wlan0", "lo"]
  # IFNAMSIZ is 16 including the NUL; the name is also interpolated into
  # the nft ruleset, so nothing outside this set reaches it.
  @ifname ~r/\A[A-Za-z0-9_.-]{1,15}\z/

  @type entry :: %{ifname: String.t(), cidr: String.t(), primary: String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec up(String.t(), String.t(), keyword()) ::
          :ok
          | {:error,
             :protected
             | :invalid_ifname
             | :invalid_cidr
             | :primary
             | :already_up
             | {:vintage_net, term()}
             | {:nat, term()}}
  def up(ifname, cidr, opts \\ []) do
    with :ok <- check_ifname(ifname),
         {:ok, address, prefix} <- parse_cidr(cidr) do
      GenServer.call(server(opts), {:up, ifname, cidr, address, prefix}, :infinity)
    end
  end

  @spec down(String.t(), keyword()) ::
          :ok | {:error, :not_up | {:nat, term()} | {:vintage_net, term()}}
  def down(ifname, opts \\ []), do: GenServer.call(server(opts), {:down, ifname}, :infinity)

  @spec status(keyword()) :: [entry()]
  def status(opts \\ []), do: GenServer.call(server(opts), :status)

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      up: %{},
      configure: Keyword.get(opts, :configure, &default_configure/2),
      deconfigure: Keyword.get(opts, :deconfigure, &default_deconfigure/1),
      primary: Keyword.get(opts, :primary, &default_primary/0),
      nat_opts: Keyword.get(opts, :nat_opts, [])
    }

    {:ok, state, {:continue, :clear}}
  end

  # A crashed instance's rules are still loaded; at boot the list is empty
  # and no nft run is needed.
  @impl true
  def handle_continue(:clear, state) do
    if Nat.lab(Keyword.delete(state.nat_opts, :lab)) != [] do
      case Nat.set_lab([], state.nat_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Vagus.Network.Lab: stale rules kept: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:up, ifname, cidr, address, prefix}, _from, state) do
    case Map.fetch(state.up, ifname) do
      {:ok, %{cidr: ^cidr}} -> {:reply, :ok, state}
      {:ok, _other} -> {:reply, {:error, :already_up}, state}
      :error -> do_up(ifname, cidr, address, prefix, state)
    end
  end

  def handle_call({:down, ifname}, _from, state) do
    case Map.pop(state.up, ifname) do
      {nil, _} ->
        {:reply, {:error, :not_up}, state}

      {_entry, rest} ->
        # Rules first: forwarding stops before the address goes away.
        case Nat.set_lab(pairs(rest), state.nat_opts) do
          :ok ->
            reply =
              case state.deconfigure.(ifname) do
                :ok -> :ok
                {:error, reason} -> {:error, {:vintage_net, reason}}
              end

            {:reply, reply, %{state | up: rest}}

          {:error, reason} ->
            {:reply, {:error, {:nat, reason}}, state}
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

    if primary == ifname do
      {:reply, {:error, :primary}, state}
    else
      up = Map.put(state.up, ifname, %{cidr: cidr, primary: primary})

      with {:vintage_net, :ok} <-
             {:vintage_net, state.configure.(ifname, config(address, prefix))},
           {:nat, :ok} <- {:nat, Nat.set_lab(pairs(up), state.nat_opts)} do
        {:reply, :ok, %{state | up: up}}
      else
        {:vintage_net, {:error, reason}} ->
          {:reply, {:error, {:vintage_net, reason}}, state}

        {:nat, {:error, reason}} ->
          state.deconfigure.(ifname)
          {:reply, {:error, {:nat, reason}}, state}
      end
    end
  end

  defp pairs(up), do: up |> Enum.sort() |> Enum.map(fn {ifname, e} -> {ifname, e.primary} end)

  defp config(address, prefix) do
    %{
      type: VintageNetEthernet,
      ipv4: %{method: :static, address: address, prefix_length: prefix}
    }
  end

  defp check_ifname(ifname) when is_binary(ifname) do
    cond do
      ifname in @protected or String.starts_with?(ifname, "hassio") -> {:error, :protected}
      Regex.match?(@ifname, ifname) -> :ok
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
  else
    defp default_configure(ifname, config),
      do: VintageNet.configure(ifname, config, persist: false)

    defp default_deconfigure(ifname), do: VintageNet.deconfigure(ifname, persist: false)
    defp default_primary, do: Vagus.Backend.Network.VintageNet.primary_interface() || "eth0"
  end
end
