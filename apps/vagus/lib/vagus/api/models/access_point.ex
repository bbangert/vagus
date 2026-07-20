defmodule Vagus.API.Models.AccessPoint do
  @moduledoc """
  `AccessPoint`, nested inside `AccessPointList.accesspoints`
  (`aiohasupervisor/models/network.py`, `docs/contract-2026.7.md` §15).

  All five fields are required and non-null on the wire — no `nullable`
  list here, unlike most models in this app.
  """

  use Vagus.API.Model,
    required: [:mode, :ssid, :frequency, :signal, :mac]
end
