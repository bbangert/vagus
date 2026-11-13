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

  `Vagus.Runtime.Engine.Podman` binds it into a host-network container that
  asks for no DNS of its own: vintage_net rewrites it in place, so it
  follows lease changes, where podman's own copy would freeze whatever the
  file held at its start.

  One that asks for DNS, Core and every app as upstream does, gets a stub
  of the spec's own settings instead (`stub/3`), written under the Host's
  run dir. Only `Vagus.DNS` is in it: musl, Core's libc, asks every
  `nameserver` at once and takes the first reply, so a LAN server listed
  beside it would answer NXDOMAIN for the app names before it did. LAN
  names still resolve, through `Vagus.DNS`'s forward.
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

  @doc "`resolv.conf` content for a spec's own DNS settings."
  @spec stub([String.t()] | nil, [String.t()] | nil, [String.t()] | nil) :: String.t()
  def stub(dns, search, options) do
    Enum.map_join(dns || [], &"nameserver #{&1}\n") <>
      line("search", search) <> line("options", options)
  end

  @doc """
  Where the stub of these settings lives under `dir`. Named by its content,
  so containers created with different settings never share one, and a
  container whose settings are unchanged finds its own again after a reboot
  once the Host has rewritten it.
  """
  @spec stub_path(String.t(), [String.t()] | nil, [String.t()] | nil, [String.t()] | nil) ::
          String.t()
  def stub_path(dir, dns, search, options), do: path_of(dir, stub(dns, search, options))

  defp path_of(dir, content) do
    hash = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join(dir, hash <> ".conf")
  end

  @doc """
  Writes the stub of these settings under `dir`, unless it is there already
  (then only its mode is set), and returns its path. Through a rename, so a
  create running beside another never binds a half-written file, and so one
  there is whole.

  One there is never rewritten: a bind holds the inode it was made on, so a
  replaced file would leave every running container reading the old one,
  and its name already fixes its content.

  The mode is forced to 0644: the device's umask is 0077, and non-root
  container users must be able to read the bound file.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_stub(String.t(), [String.t()] | nil, [String.t()] | nil, [String.t()] | nil) ::
          {:ok, String.t()} | {:error, File.posix()}
  def write_stub(dir, dns, search, options) do
    content = stub(dns, search, options)
    path = path_of(dir, content)
    tmp = "#{path}.#{System.unique_integer([:positive])}"

    with false <- File.regular?(path),
         :ok <- write_new(dir, tmp, path, content) do
      {:ok, path}
    else
      true ->
        # chmod keeps the inode, so running binds are unaffected.
        with :ok <- File.chmod(path, 0o644), do: {:ok, path}

      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_new(dir, tmp, path, content) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, content),
         :ok <- File.chmod(tmp, 0o644),
         do: File.rename(tmp, path)
  end

  defp line(_key, empty) when empty in [nil, []], do: ""
  defp line(key, values), do: "#{key} #{Enum.join(values, " ")}\n"

  defp address(%{address: ip}), do: ip
  defp address(ip) when is_tuple(ip), do: ip

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
