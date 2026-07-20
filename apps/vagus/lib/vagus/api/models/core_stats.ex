defmodule Vagus.API.Models.CoreStats do
  @moduledoc """
  Shared `ContainerStats` shape (`aiohasupervisor/models/base.py`) reused
  verbatim by `GET core/stats`, `GET supervisor/stats`, and
  `GET addons/{slug}/stats` (`docs/contract-2026.7.md` §19) —
  `HomeAssistantStats`, `SupervisorStats`, and `AddonsStats` are all empty
  subclasses with no fields of their own.
  """

  use Vagus.API.Model,
    required: [
      :cpu_percent,
      :memory_usage,
      :memory_limit,
      :memory_percent,
      :network_rx,
      :network_tx,
      :blk_read,
      :blk_write
    ],
    nullable: []
end
