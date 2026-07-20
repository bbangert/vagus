defmodule Vagus.API.Models.MountsInfo do
  @moduledoc """
  `GET mounts` (note: NOT `/mounts/info`) — `aiohasupervisor/models/mounts.py`
  `MountsInfo` (`docs/contract-2026.7.md` §20). Idle state (no mounts
  configured) is an empty list.
  """

  use Vagus.API.Model,
    required: [:mounts],
    nullable: [:default_backup_mount]
end
