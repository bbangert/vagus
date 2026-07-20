defmodule Vagus.API.Models.AccessPointList do
  @moduledoc """
  Wrapper for `GET network/interface/:ifname/accesspoints`
  (`aiohasupervisor/models/network.py`, `docs/contract-2026.7.md` §15) —
  a single required `accesspoints: list[AccessPoint]` field, each entry
  built via `Vagus.API.Models.AccessPoint`.
  """

  use Vagus.API.Model,
    required: [:accesspoints]
end
