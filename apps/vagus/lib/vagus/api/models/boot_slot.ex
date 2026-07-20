defmodule Vagus.API.Models.BootSlot do
  @moduledoc """
  `BootSlot`, nested inside `OSInfo.boot_slots` (a `dict[str, BootSlot]`)
  (`aiohasupervisor/models/os.py`, `docs/contract-2026.7.md` §13).

  A sub-builder used by `Vagus.Backend.OS` implementations when assembling
  `boot_slots`, not a route on its own.
  """

  use Vagus.API.Model,
    required: [:state],
    nullable: [:status, :version]
end
