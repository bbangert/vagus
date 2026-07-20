defmodule Vagus.Backend.Network do
  @moduledoc """
  Behaviour for the network-management backend, shaped by the endpoints
  that call into it (`docs/contract-2026.7.md` §15).

  Implementations: `Vagus.Backend.Network.VintageNet` (real target,
  backed by `vintage_net` property reads), `Vagus.Backend.Network.HostStub`
  (host-dev), and a Mox mock in `Mix.env() == :test`
  (`config/test.exs`). Selected via `Vagus.Backend.network/0`.
  """

  @doc "Attrs for `Vagus.API.Models.NetworkInfo` (`GET network/info`)."
  @callback info() :: map()

  @doc """
  Attrs for `Vagus.API.Models.NetworkInterface`
  (`GET network/interface/:ifname/info`), or an honest error (e.g. no such
  interface) as `{:error, reason}` where `reason` is a human-readable
  string suitable for the error envelope's `message`.
  """
  @callback interface_info(ifname :: String.t()) :: {:ok, map()} | {:error, String.t()}

  @doc """
  A list of attrs for `Vagus.API.Models.AccessPoint`
  (`GET network/interface/:ifname/accesspoints`), or an honest error (e.g.
  `ifname` isn't a wireless interface).
  """
  @callback access_points(ifname :: String.t()) :: {:ok, [map()]} | {:error, String.t()}

  @doc """
  Applies `params` (already-parsed JSON body, string keys) to `ifname`
  (`POST network/interface/:ifname/update`). `:ok` on success; `{:error,
  reason}` for anything unsupported or invalid — implementations validate
  and reject unsupported fields themselves rather than silently ignoring
  them.
  """
  @callback configure(ifname :: String.t(), params :: map()) :: :ok | {:error, String.t()}
end
