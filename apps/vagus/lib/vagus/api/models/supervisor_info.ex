defmodule Vagus.API.Models.SupervisorInfo do
  @moduledoc """
  `GET supervisor/info` — `aiohasupervisor/models/supervisor.py`
  `SupervisorInfo` (`docs/contract-2026.7.md` §11).
  """

  use Vagus.API.Model,
    required: [
      :version,
      :update_available,
      :channel,
      :supported,
      :healthy,
      :ip_address,
      :logging,
      :debug,
      :debug_block,
      :auto_update,
      :detect_blocking_io,
      :feature_flags
    ],
    nullable: [
      :version_latest,
      :arch,
      :timezone,
      :diagnostics,
      :country
    ]
end
