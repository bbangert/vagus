defmodule Vagus.LabServices do
  @moduledoc """
  Supervises the agent-board lab services: `Vagus.Network.Lab`,
  `Vagus.NFS` and `Vagus.USBIP`. Each returns `:ignore` off the agent
  flavor, so on a stock board this supervisor has no running children.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [Vagus.Network.Lab, Vagus.NFS, Vagus.USBIP]

    # Their own budget so a flapping rpc.mountd or usbipd exhausts this
    # supervisor, not the root's 5-in-30 s that would reboot the board.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
