defmodule Vagus.API.Models.DatadiskList do
  @moduledoc """
  `GET os/datadisk/list` — upstream `supervisor/api/os.py::list_data`
  (frontend `DatadiskList`, `src/data/hassio/host.ts`). A Nerves device
  boots from a fixed SD/eMMC with A/B firmware slots — there is no
  movable data-disk concept, so both lists are honestly empty (the
  frontend's Move-data-disk dialog then offers no targets instead of
  erroring).
  """

  use Vagus.API.Model,
    required: [:devices, :disks]
end
