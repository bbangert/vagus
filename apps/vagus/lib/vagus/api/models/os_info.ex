defmodule Vagus.API.Models.OSInfo do
  @moduledoc """
  `GET os/info` — `aiohasupervisor/models/os.py` `OSInfo`
  (`docs/contract-2026.7.md` §13).

  `boot_slots` is a `dict[str, BootSlot]`; the emulator ships an idle empty
  map for it rather than building a dedicated `BootSlot` sub-model (no boot
  slots are simulated in this phase).
  """

  use Vagus.API.Model,
    required: [
      :update_available,
      :boot_slots
    ],
    nullable: [
      :version,
      :version_latest,
      :board,
      :boot,
      :data_disk
    ]
end
