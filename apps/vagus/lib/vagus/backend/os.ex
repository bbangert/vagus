defmodule Vagus.Backend.OS do
  @moduledoc """
  Behaviour for the OS-management backend, shaped by the endpoints that
  call into it (`docs/contract-2026.7.md` §13).

  Implementations: `Vagus.Backend.OS.Nerves` (real target, backed by
  `Nerves.Runtime.KV` + `/proc/mounts`), `Vagus.Backend.OS.HostStub`
  (host-dev, reads the same `Nerves.Runtime.KV` against the InMemory
  backend), and a Mox mock in `Mix.env() == :test` (`config/test.exs`).
  Selected via `Vagus.Backend.os/0`.
  """

  @doc "Attrs for `Vagus.API.Models.OSInfo` (`GET os/info`)."
  @callback info() :: map()

  @doc """
  The data-disk device list (no dedicated route in this phase — exposed
  for a future `GET os/datadisk/list`; both implementations return an
  honest empty list since no data-disk enumeration is simulated yet).
  """
  @callback datadisk_list() :: [map()]
end
