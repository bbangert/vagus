defmodule Vagus.Backend do
  @moduledoc """
  Selects the host-management backend modules the API router calls into.

  Three behaviours — `Vagus.Backend.Network`, `Vagus.Backend.Host`,
  `Vagus.Backend.OS` — each have a real implementation (compiled only for
  real Nerves targets, reading `vintage_net`/`Nerves.Runtime`/the
  filesystem), a host-dev stub (plausible-but-honest static-ish data, used
  on `:host`), and — in `Mix.env() == :test` — a Mox mock. Which module
  backs each behaviour is a **compile-time** choice, `config :vagus,
  :backends` (a `%{network: ..., host: ..., os: ...}` map set once per
  environment in `config/host.exs`, `config/target.exs`, `config/test.exs`)
  read via `Application.compile_env/3` here, mirroring how the rest of the
  app already treats environment selection as build-time, not
  runtime-configurable.

  Callers never reference a backend module directly — always through
  `network/0`, `host/0`, `os/0`:

      Vagus.Backend.os().info()

  so swapping the configured module (e.g. test overriding to a Mox mock)
  requires no change at any call site.
  """

  @backends Application.compile_env(:vagus, :backends, %{})

  # Each accessor below reads `@backends` with its OWN literal key
  # (`:network`/`:host`/`:os`) directly, rather than through one shared
  # `defp fetch(key)` taking `key` as a parameter — with a parameterized
  # helper, the type checker analyzes that single function body once,
  # generically over `key :: atom()`, so it has to infer `Map.fetch!/2`'s
  # result as the union of ALL three backend modules' types instead of
  # narrowing per call site. That union then makes every accessor look
  # like it could return any of the three unrelated behaviour's
  # implementations, and the checker flags real callback functions (e.g.
  # `Vagus.Backend.Host.HostStub.reboot/0`) as "undefined" when called
  # through what it thinks might be `Vagus.Backend.Network.HostStub`
  # instead. Repeating the three one-line lookups keeps each `Map.fetch!/2`
  # call's key a literal at its own call site, which the checker CAN
  # narrow correctly.

  @doc "The configured `Vagus.Backend.Network` implementation."
  @spec network() :: module()
  def network, do: Map.fetch!(@backends, :network)

  @doc "The configured `Vagus.Backend.Host` implementation."
  @spec host() :: module()
  def host, do: Map.fetch!(@backends, :host)

  @doc "The configured `Vagus.Backend.OS` implementation."
  @spec os() :: module()
  def os, do: Map.fetch!(@backends, :os)
end
