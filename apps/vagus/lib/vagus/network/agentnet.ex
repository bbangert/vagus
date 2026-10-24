defmodule Vagus.Network.Agentnet do
  @moduledoc """
  The agent flavor's private bridge: the memory DB app (`agent_memory`) at
  a fixed address, and the workers the orchestrator starts with
  `--network agentnet`. `--internal`, so netavark adds no masquerade and
  gives its containers no default route: nothing on it reaches beyond the
  board. The orchestrator is host-networked and reaches the DB through the
  host's own gateway address; `Vagus.Network.Nat` keeps `hassio` apps out.
  """

  require Logger

  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Engine.NetworkSpec

  @name "agentnet"
  @subnet "172.30.40.0/24"
  @gateway "172.30.40.1"
  @prefix "24"
  @memory_ip "172.30.40.2"
  # A dummy port keeps the bridge, and the host's `.1`, while no container
  # is attached: netavark deletes a portless bridge, and the host-networked
  # orchestrator would lose its route to the DB. 15 characters, IFNAMSIZ's
  # limit.
  @bridge_port "agentnet-anchor"
  # As `Vagus.Network.Nat`'s: a backoff that outlasts one network create.
  @lock_retries 8

  @spec name() :: String.t()
  def name, do: @name

  @spec gateway() :: String.t()
  def gateway, do: @gateway

  @spec memory_ip() :: String.t()
  def memory_ip, do: @memory_ip

  # No ip_range: the only container with an address of its own asks for it
  # (`--ip`); workers take any free one.
  @spec spec() :: NetworkSpec.t()
  def spec do
    %NetworkSpec{
      name: @name,
      driver: :bridge,
      subnet: @subnet,
      gateway: @gateway,
      interface_name: @name,
      internal: true
    }
  end

  @doc """
  Ensures the network and, on a board, its host-kept bridge. A no-op off
  the agent flavor; `:agentnet` overrides `Vagus.Flavor.agent?/0` and
  `:host_bridge` `Vagus.Network.host_bridge?/1`. `{:error, :busy}` when
  another ensure holds it past `:lock_retries`.
  """
  @spec ensure(keyword()) :: :ok | {:error, Engine.error()}
  def ensure(opts \\ []) do
    if enabled?(opts), do: serialized(opts, fn -> do_ensure(opts) end), else: :ok
  end

  # The boot gate and the memory app's start both ensure it; unserialized,
  # both see it absent and the second create fails, or one remakes it
  # (`--internal` repair) under the other.
  defp serialized(opts, fun) do
    lock = {__MODULE__, self()}

    case :global.trans(lock, fun, [node()], Keyword.get(opts, :lock_retries, @lock_retries)) do
      :aborted -> {:error, :busy}
      result -> result
    end
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []), do: Keyword.get_lazy(opts, :agentnet, &Vagus.Flavor.agent?/0)

  defp do_ensure(opts) do
    result = Engine.ensure_network(spec(), opts)

    # The host must own `.1` while no container is up, or the orchestrator,
    # on the host network, has no route to the DB until netavark makes the
    # bridge; the dummy port keeps netavark from deleting it.
    with true <- Vagus.Network.host_bridge?(opts),
         {:error, {args, out, status}} <- Vagus.Network.run_ip(bridge_commands(), opts) do
      Logger.warning(
        "Vagus.Network.Agentnet: the agentnet bridge is not kept: ip #{Enum.join(args, " ")} " <>
          "failed (#{status}): #{out}"
      )
    end

    result
  end

  @spec bridge_commands() :: [[String.t()]]
  def bridge_commands,
    do: Vagus.Network.bridge_commands(@name, @bridge_port, "#{@gateway}/#{@prefix}")
end
