defmodule Vagus.API.Models.AddonsList do
  @moduledoc """
  `GET addons` — `aiohasupervisor/models/addons.py` `AddonsList`
  (`docs/contract-2026.7.md` §18). Idle state (no addons installed) is an
  empty list.
  """

  use Vagus.API.Model,
    required: [:addons],
    nullable: []
end
