defmodule Vagus.API.Models.JobsInfo do
  @moduledoc """
  `GET jobs/info` — `aiohasupervisor/models/jobs.py` `JobsInfo`
  (`docs/contract-2026.7.md` §17). Both fields are required, non-null
  lists; idle state is an empty list for each.
  """

  use Vagus.API.Model,
    required: [
      :ignore_conditions,
      :jobs
    ],
    nullable: []
end
