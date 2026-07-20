defmodule Vagus.API.Models.HostInfo do
  @moduledoc """
  `GET host/info` — `aiohasupervisor/models/host.py` `HostInfo`
  (`docs/contract-2026.7.md` §14).
  """

  use Vagus.API.Model,
    required: [
      :disk_free,
      :disk_total,
      :disk_used,
      :features
    ],
    nullable: [
      :agent_version,
      :apparmor_version,
      :chassis,
      :virtualization,
      :cpe,
      :deployment,
      :disk_life_time,
      :hostname,
      :llmnr_hostname,
      :kernel,
      :operating_system,
      :timezone,
      :dt_utc,
      :dt_synchronized,
      :use_ntp,
      :startup_time,
      :boot_timestamp,
      :broadcast_llmnr,
      :broadcast_mdns
    ]
end
