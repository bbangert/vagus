defmodule Vagus.Runtime.ResolvConf do
  @moduledoc """
  The `/run/resolv.conf` content podman hands its containers, written by
  `Vagus.Runtime.Host` each boot from vintage_net's name servers.

  `/etc/resolv.conf` on the target is a symlink to this path (in
  `nerves_system_vagus`), but vintage_net's own `NameResolver` writes it
  only as leases arrive; the Host creates it when missing so a file exists
  before the first container starts, and leaves it to vintage_net after
  that. With no name servers reported (a static interface with no DNS), a
  fallback is written rather than an empty file.

  `Vagus.Runtime.Engine.Podman` binds it into host-network containers:
  vintage_net rewrites it in place, so they follow lease changes, where
  podman's own copy would freeze whatever the file held at their start.
  """

  @path "/run/resolv.conf"
  @fallback_servers [{1, 1, 1, 1}, {8, 8, 8, 8}]

  @typedoc "Anything VintageNet's `[\"name_servers\"]` property or a plain IP tuple can hand us."
  @type server :: :inet.ip_address() | %{address: :inet.ip_address()}

  @doc "Where `Vagus.Runtime.Host` writes it."
  @spec path() :: String.t()
  def path, do: @path

  @doc "The static fallback name servers used when `servers` is empty."
  @spec fallback_servers() :: [:inet.ip_address()]
  def fallback_servers, do: @fallback_servers

  @doc """
  Renders `servers` as `resolv.conf` content: one `nameserver <ip>` line per
  server. Falls back to `fallback_servers/0` when given an empty list.
  """
  @spec build([server()]) :: String.t()
  def build([]), do: build(@fallback_servers)

  def build(servers) when is_list(servers) do
    Enum.map_join(servers, fn server -> "nameserver #{server |> address() |> format_ip()}\n" end)
  end

  defp address(%{address: ip}), do: ip
  defp address(ip) when is_tuple(ip), do: ip

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
