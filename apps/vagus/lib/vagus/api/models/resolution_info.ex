defmodule Vagus.API.Models.ResolutionInfo do
  @moduledoc """
  `GET resolution/info` — `aiohasupervisor/models/resolution.py`
  `ResolutionInfo` (`docs/contract-2026.7.md` §16). All five fields are
  required, non-null lists; idle state is an empty list for each.
  """

  use Vagus.API.Model,
    required: [
      :suggestions,
      :unsupported,
      :unhealthy,
      :issues,
      :checks
    ],
    nullable: []
end
