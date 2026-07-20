defmodule Vagus.API.Models.HomeAssistantInfo do
  @moduledoc """
  `GET core/info` — `aiohasupervisor/models/homeassistant.py`
  `HomeAssistantInfo` (`docs/contract-2026.7.md` §12).
  """

  use Vagus.API.Model,
    required: [
      :update_available,
      :ip_address,
      :image,
      :boot,
      :port,
      :ssl,
      :watchdog,
      :backups_exclude_database,
      :duplicate_log_file
    ],
    nullable: [
      :version,
      :version_latest,
      :machine,
      :arch,
      :audio_input,
      :audio_output
    ]
end
