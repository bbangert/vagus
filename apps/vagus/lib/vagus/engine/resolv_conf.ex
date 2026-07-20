defmodule Vagus.Engine.ResolvConf do
  @moduledoc """
  Builds and writes the `/run/resolv.conf` content that the balena-engine
  daemon (and every container it starts) resolves DNS against.

  This is deliberately separate from — and redundant with — `vintage_net`'s
  own `VintageNet.NameResolver`, which manages `/etc/resolv.conf` reactively
  as interfaces get their DHCP leases. The daemon reads resolver config once
  at start time, so `Vagus.Engine.Manager` calls `write/1` synchronously at
  the moment it observes `:internet`, guaranteeing a good file exists
  *before* the daemon is spawned (plan.md task 2.3) instead of trusting
  whatever `vintage_net`'s own async update has landed by that instant.

  `/etc/resolv.conf` on the target system is a symlink to this path (system
  task 1.7, in `nerves_system_vagus`); on `:host` there's no such symlink and
  nothing writes here in practice.

  If `vintage_net` reports no name servers at all (e.g. a statically
  configured interface with no DNS handed out), a static fallback of
  `1.1.1.1` / `8.8.8.8` is used instead of writing an empty file (task 2.3).
  """

  @path "/run/resolv.conf"
  @fallback_servers [{1, 1, 1, 1}, {8, 8, 8, 8}]

  @typedoc "Anything VintageNet's `[\"name_servers\"]` property or a plain IP tuple can hand us."
  @type server :: :inet.ip_address() | %{address: :inet.ip_address()}

  @doc "The path this module writes to."
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

  @doc """
  Writes `build(servers)` to `/run/resolv.conf`.
  """
  @spec write([server()]) :: :ok | {:error, File.posix()}
  def write(servers) do
    File.write(@path, build(servers))
  end

  defp address(%{address: ip}), do: ip
  defp address(ip) when is_tuple(ip), do: ip

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
