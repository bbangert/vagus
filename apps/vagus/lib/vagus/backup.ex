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
  # Bomb guards: the outer tar is uncompressed so its own size is the bound;
  # inner add-on tars are gzip'd, so their gunzip is capped during inflation.
  @max_outer 536_870_912
  @max_inner_uncompressed 268_435_456

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
    with :ok <- guard_outer_size(tar),
         {:ok, entries} <- untar_plain(tar),
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
    with :ok <- guard_outer_size(tar),
         {:ok, entries} <- untar_plain(tar),
         {:ok, inner_gz} <- member(entries, "#{slug}.tar.gz"),
         {:ok, inner} <- Vagus.Targz.extract_capped(inner_gz, @max_inner_uncompressed),
         {:ok, addon_json} <- fetch_member(inner, "addon.json"),
         {:ok, addon} <- Jason.decode(addon_json),
         {:ok, data} <- collect_data(inner) do
      {:ok, %{addon: addon, data: data}}
    else
      :error -> {:error, :not_in_backup}
      other -> other
    end
  end

  # `data/` files as {relpath, content}, rejecting any member that escapes the
  # add-on dir (`..`/absolute) — a hostile backup must not write outside /data
  # when a future restore materializes these as root (zip-slip).
  defp collect_data(inner) do
    Enum.reduce_while(inner, {:ok, []}, fn {name, content}, {:ok, acc} ->
      rel = strip_dot(name)

      cond do
        not String.starts_with?(rel, "data/") -> {:cont, {:ok, acc}}
        unsafe_path?(rel) -> {:halt, {:error, {:unsafe_path, rel}}}
        true -> {:cont, {:ok, [{String.replace_prefix(rel, "data/", ""), content} | acc]}}
      end
    end)
  end

  defp unsafe_path?(path) do
    String.starts_with?(path, "/") or ".." in Path.split(path)
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
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
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

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
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

  # Reject an oversized outer tar before extraction (it's uncompressed, so its
  # byte size is its real size — no gunzip amplification here).
  defp guard_outer_size(tar) when byte_size(tar) > @max_outer, do: {:error, :too_large}
  defp guard_outer_size(_tar), do: :ok

  # The outer tar is plain (uncompressed); inner add-on tars are gunzipped via
  # the capped `Vagus.Targz` path instead.
  defp untar_plain(bin) do
    case :erl_tar.extract({:binary, bin}, [:memory]) do
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
