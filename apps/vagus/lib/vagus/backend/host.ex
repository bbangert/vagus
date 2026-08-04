defmodule Vagus.Backend.Host do
  @moduledoc """
  Behaviour for the host-management backend, shaped by the endpoints that
  call into it (`docs/contract-2026.7.md` §14).

  Implementations: `Vagus.Backend.Host.Nerves` (real target),
  `Vagus.Backend.Host.HostStub` (host-dev), and a Mox mock in
  `Mix.env() == :test` (`config/test.exs`). Selected via
  `Vagus.Backend.host/0`.
  """

  @doc "Attrs for `Vagus.API.Models.HostInfo` (`GET host/info`)."
  @callback info() :: map()

  @doc """
  Reboots the host (`POST host/reboot`). The router sends the ok envelope
  to the caller BEFORE invoking this — Core expects the HTTP response
  before the box actually goes down, so implementations that don't return
  (a real target reboot) are fine; the router never waits on this call to
  respond.

  Real (`Nerves`) implementations must route through `Vagus.Host.Shutdown`
  — never call `Nerves.Runtime` directly — so Core + add-on containers are
  always stopped gracefully before the hardware-watchdog reboot arms.
  """
  @callback reboot() :: :ok

  @doc "Shuts down the host (`POST host/shutdown`). Same ordering as `reboot/0`."
  @callback shutdown() :: :ok
end
