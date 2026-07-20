defmodule Vagus.API.Models.RootInfo do
  @moduledoc """
  `GET info` — `aiohasupervisor/models/root.py` `RootInfo`
  (`docs/contract-2026.7.md` §10).
  """

  use Vagus.API.Model,
    required: [
      :supervisor,
      :docker,
      :features,
      :arch,
      :state,
      :supported_arch,
      :supported,
      :channel,
      :logging,
      :timezone
    ],
    nullable: [
      :homeassistant,
      :hassos,
      :hostname,
      :operating_system,
      :machine,
      :machine_id
    ]
end
