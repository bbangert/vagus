defmodule Vagus.Backup do
  @moduledoc """
  Reads + writes the **unprotected** HAOS partial-backup format
  (`docs/contract-2026.7-m4-addendum.md` §A4). Encrypted (securetar) interop is
  deferred (§A7); everything here is plaintext outer tar + plain-gzip inner tars,
  which HAOS restores as an unprotected backup.

  Layout: a store-only (uncompressed) outer tar whose members are `./`-prefixed:
  `./backup.json` (plaintext, always) + one `./<slug>.tar.gz` per add-on. Each
  add-on inner tar (`arcname="."`, gzipped) holds `addon.json`
  (`{user, system, version, state}`) and `data/` (the add-on's `/data`).

  `backup.json` carries the §A4 `SCHEMA_BACKUP` fields (key is `addons`,
  `version: 2`, `protected: false`). Tar bytes are produced via a short-lived
  temp file (erl_tar's write sink); reads are fully in-memory.
  """

  @version 2

  @type addon_spec :: %{
          slug: String.t(),
          name: String.t(),
          version: String.t(),
          data_dir: String.t()
        }

  @doc """
  Builds an unprotected partial backup tar for `spec`
  (`%{slug, name, addons: [addon_spec], supervisor_version}`). `opts[:date]`
  overrides the ISO8601 timestamp (for tests). Returns `{:ok, tar_binary}`.
  """
  @spec create(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def create(spec, opts \\ []) do
    addons = Map.get(spec, :addons, [])
    date = Keyword.get(opts, :date) || iso8601_now()

    with {:ok, addon_members, addon_meta} <- build_addon_members(addons) do
      backup_json = backup_json(spec, addon_meta, date)
      members = [{"./backup.json", Jason.encode!(backup_json)} | addon_members]
      {:ok, write_tar(members, compressed: false)}
    end
  end

  @doc """
  Parses an outer backup tar. Returns `{:ok, %{backup: map, members: [name]}}`
  — the decoded `backup.json` plus the member names (so callers can see which
  add-on inner tars are present). Rejects a tar without a valid `backup.json`.
  """
  @spec read(binary()) :: {:ok, map()} | {:error, term()}
  def read(tar) when is_binary(tar) do
    with {:ok, entries} <- untar(tar, compressed: false),
         {:ok, json} <- fetch_member(entries, "backup.json"),
         {:ok, backup} <- Jason.decode(json) do
      {:ok, %{backup: backup, members: Enum.map(entries, fn {name, _} -> name end)}}
    end
  end

  @doc """
  Extracts one add-on from a backup: the decoded `addon.json` plus its `data/`
  files as `[{relative_path, content}]`. Returns `{:error, :not_in_backup}` if
  the add-on's inner tar is absent.
  """
  @spec extract_addon(binary(), String.t()) ::
          {:ok, %{addon: map(), data: [{String.t(), binary()}]}} | {:error, term()}
  def extract_addon(tar, slug) when is_binary(tar) do
    with {:ok, entries} <- untar(tar, compressed: false),
         {:ok, inner_gz} <- member(entries, "#{slug}.tar.gz"),
         {:ok, inner} <- untar(inner_gz, compressed: true),
         {:ok, addon_json} <- fetch_member(inner, "addon.json"),
         {:ok, addon} <- Jason.decode(addon_json) do
      data =
        for {name, content} <- inner, String.starts_with?(strip_dot(name), "data/") do
          {String.replace_prefix(strip_dot(name), "data/", ""), content}
        end

      {:ok, %{addon: addon, data: data}}
    else
      :error -> {:error, :not_in_backup}
      other -> other
    end
  end

  ## backup.json

  defp backup_json(spec, addon_meta, date) do
    %{
      "slug" => spec.slug,
      "type" => "partial",
      "name" => spec.name,
      "date" => date,
      "version" => @version,
      "supervisor_version" => Map.get(spec, :supervisor_version, "vagus"),
      "compressed" => true,
      "protected" => false,
      "homeassistant" => nil,
      "folders" => [],
      "addons" => addon_meta,
      "repositories" => [],
      "extra" => %{}
    }
  end

  ## Inner add-on tars

  defp build_addon_members(addons) do
    Enum.reduce_while(addons, {:ok, [], []}, fn addon, {:ok, members, meta} ->
      case build_addon_tar(addon) do
        {:ok, gz, size} ->
          member = {"./#{addon.slug}.tar.gz", gz}

          m = %{
            "slug" => addon.slug,
            "name" => addon.name,
            "version" => addon.version,
            "size" => size
          }

          {:cont, {:ok, [member | members], [m | meta]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_addon_tar(addon) do
    addon_json =
      Jason.encode!(%{
        "user" => Map.get(addon, :user, %{}),
        "system" => Map.get(addon, :system, %{}),
        "version" => addon.version,
        "state" => Map.get(addon, :state, "started")
      })

    data_members =
      addon.data_dir
      |> read_dir()
      |> Enum.map(fn {rel, content} -> {"./data/#{rel}", content} end)

    gz = write_tar([{"./addon.json", addon_json} | data_members], compressed: true)
    {:ok, gz, byte_size(gz)}
  rescue
    e -> {:error, {:addon_tar, addon.slug, Exception.message(e)}}
  end

  # Recursively read a directory into [{relative_path, content}]. Absent dir → [].
  defp read_dir(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path -> {Path.relative_to(path, dir), File.read!(path)} end)
    else
      []
    end
  end

  ## tar helpers

  defp write_tar(members, compressed: compressed?) do
    path =
      Path.join(System.tmp_dir!(), "vagus-backup-#{System.unique_integer([:positive])}.tar")

    open_opts = if compressed?, do: [:write, :compressed], else: [:write]
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), open_opts)

    try do
      Enum.each(members, fn {name, bin} ->
        :ok = :erl_tar.add(tar, bin, String.to_charlist(name), [])
      end)

      :ok = :erl_tar.close(tar)
      File.read!(path)
    after
      File.rm(path)
    end
  end

  defp untar(bin, compressed: compressed?) do
    opts = if compressed?, do: [:memory, :compressed], else: [:memory]

    case :erl_tar.extract({:binary, bin}, opts) do
      {:ok, entries} -> {:ok, Enum.map(entries, fn {n, c} -> {to_string(n), c} end)}
      {:error, reason} -> {:error, {:untar, reason}}
    end
  end

  # Members may be stored `./name` or `name`; match on the `./`-stripped form.
  defp member(entries, name) do
    case Enum.find(entries, fn {n, _} -> strip_dot(n) == name end) do
      {_n, content} -> {:ok, content}
      nil -> :error
    end
  end

  defp fetch_member(entries, name) do
    case member(entries, name) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, {:missing_member, name}}
    end
  end

  defp strip_dot(name), do: String.replace_prefix(name, "./", "")

  defp iso8601_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
