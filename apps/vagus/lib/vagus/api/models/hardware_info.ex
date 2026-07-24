defmodule Vagus.API.Models.HardwareInfo do
  @moduledoc """
  `GET hardware/info` — upstream `supervisor/api/hardware.py::info`
  (frontend `HassioHardwareInfo`, `src/data/hassio/hardware.ts`).
  Per-device maps are built by `Vagus.Backend.Host.Hardware` (upstream
  `device_struct/1` key set); `drives` is `[]` on Vagus (no UDisks2 —
  see that module's moduledoc).
  """

  use Vagus.API.Model,
    required: [:devices, :drives]
end
