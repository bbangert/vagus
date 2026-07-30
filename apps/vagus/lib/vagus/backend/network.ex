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
  (`GET network/interface/:ifname/info`). Implementations resolve the
  `default` alias (compared case-insensitively) to the primary
  interface — the one whose `connection` is not `:disconnected` AND
  matches the aggregate `["connection"]` value, the same rule
  `Builder.build_interface/3` uses for `primary` — before lookup.
  Unknown/unresolvable `ifname`
  is `{:error, :not_found}` (the router turns that into upstream's 404
  `Interface {name} does not exist`); any other failure is
  `{:error, reason}` with a human-readable string suitable for the error
  envelope's `message` (400).
  """
  @callback interface_info(ifname :: String.t()) ::
              {:ok, map()} | {:error, :not_found | String.t()}

  @doc """
  A list of attrs for `Vagus.API.Models.AccessPoint`
  (`GET network/interface/:ifname/accesspoints`). Same `default`-alias
  and `{:error, :not_found}` handling as `interface_info/1`; a resolved
  interface that isn't wireless is an honest `{:error, reason}` string
  (400), not a 404.
  """
  @callback access_points(ifname :: String.t()) ::
              {:ok, [map()]} | {:error, :not_found | String.t()}

  @doc """
  Applies `params` (already-parsed JSON body, string keys) to `ifname`
  (`POST network/interface/:ifname/update`), after resolving the
  `default` alias same as `interface_info/1`. `:ok` on success (including
  a no-op when `params` validates but has nothing this backend can act
  on); `{:error, :not_found}` for an unresolvable `ifname`; `{:error,
  reason}` for anything invalid — implementations validate and reject bad
  fields themselves rather than silently ignoring or crashing on them
  (see `Vagus.Backend.Network.WireConfig` for the shared wire-body
  validation both real implementations delegate to).
  """
  @callback configure(ifname :: String.t(), params :: map()) ::
              :ok | {:error, :not_found | String.t()}
end
