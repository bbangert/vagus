defmodule Vagus.API.Models.AvailableUpdates do
  @moduledoc """
  `GET available_updates` — `aiohasupervisor/models/root.py`
  `AvailableUpdates` (`docs/contract-2026.7.md` §21). Not polled by the
  `hassio` coordinator in this Core version, but still a real route the
  frontend may call via the `supervisor/api` WS passthrough — implemented
  as a valid, idle (empty list) response. Note: unlike most wrapper
  models, `aiohasupervisor`'s client method unwraps this itself into a bare
  list; the wire JSON body still carries the `available_updates` wrapper
  key, which is what this model (and the emulator's `data` envelope field)
  represents.
  """

  use Vagus.API.Model,
    required: [:available_updates],
    nullable: []
end
