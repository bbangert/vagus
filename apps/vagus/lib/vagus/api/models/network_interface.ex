defmodule Vagus.API.Models.NetworkInterface do
  @moduledoc """
  `NetworkInterface`, nested inside `NetworkInfo.interfaces`
  (`aiohasupervisor/models/network.py`, `docs/contract-2026.7.md` §15).

  A sub-builder used by `Vagus.API.Models.NetworkInfo`'s interface list, not
  a route on its own.
  """

  use Vagus.API.Model,
    required: [
      :interface,
      :type,
      :enabled,
      :connected,
      :primary,
      :mac
    ],
    nullable: [
      :ipv4,
      :ipv6,
      :wifi,
      :vlan,
      :mdns,
      :llmnr
    ]
end
