defmodule Vagus.API.Models.NetworkInfo do
  @moduledoc """
  `GET network/info` — `aiohasupervisor/models/network.py` `NetworkInfo`
  (`docs/contract-2026.7.md` §15).

  `docker` (a `DockerNetwork`) and each entry of `interfaces` (a
  `Vagus.API.Models.NetworkInterface`) are nested objects; `interfaces`
  entries are built via that sub-model. `DockerNetwork` has no nullable
  fields of its own (all four are required, non-null), so it's built as a
  plain literal map here rather than via a dedicated model module.
  """

  use Vagus.API.Model,
    required: [
      :interfaces,
      :docker,
      :supervisor_internet
    ],
    nullable: [
      :host_internet
    ]
end
