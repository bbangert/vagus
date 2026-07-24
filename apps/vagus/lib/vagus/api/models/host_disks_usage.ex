defmodule Vagus.API.Models.HostDisksUsage do
  @moduledoc """
  `GET host/disks/default/usage` — upstream `supervisor/api/host.py::
  disk_usage` (no aiohasupervisor model; consumed by the frontend's
  `HostDisksUsage` type in `src/data/hassio/host.ts`). This validates the
  ROOT node only; nested `children` nodes are plain maps whose optional
  keys (`children`, `total_bytes`) are omitted-when-absent, matching
  upstream.
  """

  use Vagus.API.Model,
    required: [:id, :label, :total_bytes, :used_bytes, :children]
end
