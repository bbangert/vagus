defmodule Vagus.Flavor do
  @moduledoc """
  The firmware's build-time flavor: `:default`, the Home Assistant
  appliance, or `:agent_dev_board`, a dragon_q6a image that never starts
  Home Assistant Core at boot and never provisions or watches it. The Core
  HTTP routes (`POST /core/start` etc.) are not guarded, so a deliberate call
  can still install or start Core (follow-up). Set by `VAGUS_FLAVOR` through `config/flavor.exs`.

  A flavor is config rather than a mix target because a target needs its
  own `nerves_system` dependency, and this board is otherwise identical.
  """

  @type t :: :default | :agent_dev_board

  @spec get() :: t()
  def get, do: Application.get_env(:vagus, :flavor, :default)

  @spec agent?() :: boolean()
  def agent?, do: get() == :agent_dev_board
end
