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
  The latest OS/firmware version the update feed advertises, or `nil`
  when unknown (updater disabled, or no check has completed yet) — the
  caller falls back to the current version, which reads as an honest
  "no update".
  """
  @callback version_latest() :: String.t() | nil

  @doc """
  Starts an OS/firmware update (`POST os/update`). `version` is the
  optional requested tag from the request body — only the feed's latest
  can actually be installed (`{:error, {:version_mismatch, latest}}`
  otherwise; the underlying updater has no install-specific-version
  API). Returns `:ok` once the asynchronous download → flash → reboot
  pipeline is accepted. See `Vagus.OS.Updater.install/2` for the error
  vocabulary.
  """
  @callback update(String.t() | nil) :: :ok | {:error, term()}

  @doc """
  The data-disk device list (no dedicated route in this phase — exposed
  for a future `GET os/datadisk/list`; both implementations return an
  honest empty list since no data-disk enumeration is simulated yet).
  """
  @callback datadisk_list() :: [map()]
end
