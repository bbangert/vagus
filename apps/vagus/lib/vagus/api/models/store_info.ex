defmodule Vagus.API.Models.StoreInfo do
  @moduledoc """
  `GET store` (note: NOT `/store/info`) — `aiohasupervisor/models/addons.py`
  `StoreInfo` (`docs/contract-2026.7.md` §20; the class lives in `addons.py`,
  not a `store.py` — there is no such module in aiohasupervisor 0.6.0).
  Idle state (no store addons cached, no repositories configured) is an
  empty list for each field.
  """

  use Vagus.API.Model,
    required: [:addons, :repositories],
    nullable: []
end
