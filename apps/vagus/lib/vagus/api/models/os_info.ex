defmodule Vagus.API.Models.OSInfo do
  @moduledoc """
  `GET os/info` — `aiohasupervisor/models/os.py` `OSInfo`
  (`docs/contract-2026.7.md` §13).

  `boot_slots` is a `dict[str, BootSlot]`; the emulator ships an idle empty
  map for it rather than building a dedicated `BootSlot` sub-model (no boot
  slots are simulated in this phase).

  `version_pending` is always `nil`: our OS updater (`Vagus.OS.Updater`)
  installs and reboots in one shot, so there is never a fwup-staged,
  not-yet-active version to report (verified against a live-device
  aiohasupervisor 0.6.0 field dump 2026-08-07 — this field is REQUIRED on
  the wire even though its value is nullable; omitting the key entirely,
  as this model did before, crashes Core's hassio coordinator with
  `mashumaro.exceptions.MissingField`).
  """

  use Vagus.API.Model,
    required: [
      :update_available,
      :boot_slots
    ],
    nullable: [
      :version,
      :version_latest,
      :version_pending,
      :board,
      :boot,
      :data_disk
    ]
end
