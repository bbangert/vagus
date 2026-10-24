defmodule Vagus.Runtime.Engine.NetworkSpec do
  @moduledoc false

  @type t :: %__MODULE__{
          name: String.t(),
          driver: :bridge,
          subnet: String.t() | nil,
          gateway: String.t() | nil,
          ip_range: String.t() | nil,
          interface_name: String.t() | nil,
          internal: boolean()
        }

  @enforce_keys [:name]
  defstruct name: nil,
            driver: :bridge,
            subnet: nil,
            gateway: nil,
            ip_range: nil,
            interface_name: nil,
            internal: false
end
