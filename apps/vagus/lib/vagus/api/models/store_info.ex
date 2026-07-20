defmodule Vagus.API.Models.StoreInfo do
  @moduledoc """
  `GET store` (note: NOT `/store/info`) — `aiohasupervisor/models/store.py`
  `StoreInfo` (`docs/contract-2026.7.md` §20). Idle state (no store addons
  cached, no repositories configured) is an empty list for each field.
  """

  use Vagus.API.Model,
    required: [:addons, :repositories],
    nullable: []
end
