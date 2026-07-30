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
  temp file (erl_tar's write sink).

  Two read surfaces (audit C6): the original binary API (`read/1`,
  `extract_addon/2`) loads the whole outer tar and is bounded by
  `@max_outer`; the file API (`read_file/1`, `extract_addon_file/2`) never
  materialises the outer tar — it lists members via `:erl_tar.table/2`,
  size-checks the one member it needs, and extracts only that member to
  memory. A real HAOS backup runs to gigabytes, so anything touching an
  on-disk tar (upload, boot rescan, restore) must use the file API; the
  binary API remains for the create path (whose tar was just built in
  memory) and tests.
  """

  @version 2
  # Bomb guards. Binary API: the outer tar is uncompressed so its own size
  # is the bound (@max_outer applies to `read/1`/`extract_addon/2` ONLY —
  # the file API is not size-limited on the outer tar, per the C6 cap
  # revisit: real HAOS backups exceed 512MB routinely, and the file API
  # never loads the outer tar anyway). Per-member: `backup.json` is capped
  # at 1MB, an inner add-on tar.gz member at @max_inner_uncompressed (kept
  # at 256MB after the revisit — the gunzipped members ARE materialised in
  # memory on restore, and 256MB is what a 1GB board can absorb).
  @max_outer 536_870_912
  @max_inner_uncompressed 268_435_456
  @max_backup_json 1_048_576

  # The COMPRESSED allowance for an inner `<slug>.tar.gz` member, used only as
  # a cheap pre-filter so a giant member is never read into memory.
  # `@max_inner_uncompressed` would be the wrong bound here: gzip is not
  # guaranteed to shrink its input — incompressible data grows by the header
  # plus ~0.03% of stored-block overhead — so an add-on whose data legitimately
  # inflates to just under the cap can have a compressed member just over it
  # (Copilot, PR #30). The authoritative uncompressed guard remains
  # `Vagus.Targz.extract_capped/2` during inflation; this only has to be
  # generous enough never to reject something that guard would accept.
  @max_inner_compressed @max_inner_uncompressed + 1_048_576

  # Heap ceiling for the tar-reading child processes (`bounded/1`), in WORDS
  # — 32M words ≈ 256MB on a 64-bit VM, matching `@max_inner_uncompressed`
  # (the largest member any read path legitimately materialises).
  @tar_read_heap_words 32 * 1024 * 1024

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
  `read/1` for an on-disk tar, without loading it: lists the members
  (`:erl_tar.table/2`), size-caps `backup.json` at #{@max_backup_json}
  bytes, and extracts only that member. Same return shape as `read/1`.
  """
  @spec read_file(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_file(path) do
    with {:ok, entries} <- table(path),
         {:ok, {name, size}} <- find_table_entry(entries, "backup.json"),
         :ok <- guard_member_size(size, @max_backup_json),
         {:ok, json} <- extract_one(path, name),
         {:ok, backup} <- Jason.decode(json) do
      {:ok, %{backup: backup, members: Enum.map(entries, fn {n, _type, _size} -> n end)}}
    else
      :error -> {:error, {:missing_member, "backup.json"}}
      other -> other
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
         {:ok, inner_gz} <- member(entries, "#{slug}.tar.gz") do
      decode_addon_inner(inner_gz)
    else
      :error -> {:error, :not_in_backup}
      other -> other
    end
  end

  @doc """
  `extract_addon/2` for an on-disk tar: only the one `<slug>.tar.gz` member
  is loaded (pre-filtered at `@max_inner_compressed`, with
  `Vagus.Targz.extract_capped/2` the authoritative uncompressed guard),
  never the whole outer tar.
  """
  @spec extract_addon_file(Path.t(), String.t()) ::
          {:ok, %{addon: map(), data: [{String.t(), binary()}]}} | {:error, term()}
  def extract_addon_file(path, slug) do
    with {:ok, entries} <- table(path),
         {:ok, {name, size}} <- find_table_entry(entries, "#{slug}.tar.gz"),
         :ok <- guard_member_size(size, @max_inner_compressed),
         {:ok, inner_gz} <- extract_one(path, name) do
      decode_addon_inner(inner_gz)
    else
      :error -> {:error, :not_in_backup}
      other -> other
    end
  end

  # The shared inner half of `extract_addon/2` and `extract_addon_file/2`:
  # capped gunzip, `addon.json`, zip-slip-guarded `data/` collection.
  defp decode_addon_inner(inner_gz) do
    with {:ok, inner} <- Vagus.Targz.extract_capped(inner_gz, @max_inner_uncompressed),
         {:ok, addon_json} <- fetch_member(inner, "addon.json"),
         {:ok, addon} <- Jason.decode(addon_json),
         {:ok, data} <- collect_data(inner) do
      {:ok, %{addon: addon, data: data}}
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

  # `supervisor_version` is required of the caller (`Map.fetch!/2`, no
  # default): the old `"vagus"` fallback is what made every Vagus tar raise
  # inside a restoring HAOS's AwesomeVersion comparison (audit C2). The
  # caller passes `Vagus.API.StaticData.supervisor_version/0` — one constant
  # for the whole wire. `extra` round-trips (audit C5): Core writes
  # `supervisor.backup_request_date` + automatic-backup identity into it on
  # every create and reads it back.
  defp backup_json(spec, addon_meta, date) do
    %{
      "slug" => spec.slug,
      "type" => "partial",
      "name" => spec.name,
      "date" => date,
      "version" => @version,
      "supervisor_version" => Map.fetch!(spec, :supervisor_version),
      "compressed" => true,
      "protected" => false,
      "homeassistant" => nil,
      "folders" => [],
      "addons" => addon_meta,
      "repositories" => [],
      "extra" => Map.get(spec, :extra) || %{}
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
            # An MB float, not bytes — upstream's `Backup.size` unit
            # (audit C5; the old bytes value was off by 1048576×). Raw
            # division, no rounding: upstream's is `st_size / 1024 / 1024`.
            "size" => size / 1_048_576
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

  ## file-API helpers (read_file/extract_addon_file)

  # Member listing WITHOUT extraction — `{stored_name, type, size}` triples.
  # The verbose table tuple is `{name, type, size, mtime, mode, uid, gid}`;
  # `type` is KEPT (not discarded) because `find_table_entry/2` below refuses
  # anything but a regular file.
  #
  # Runs heap-bounded (see `bounded/1`): `:erl_tar.table/2` is NOT a
  # size-safe operation. OTP 29's `foldl_read1/5` resolves GNU longname
  # (`'L'`) and PAX headers inline on the *table* pass, reading the claimed
  # payload and converting it through `unicode:characters_to_list/1` — a
  # charlist at ~16 bytes per payload byte. Measured 2026-07-30: a 19MB
  # forged longname payload cost a **970MB** heap delta, i.e. an OOM from a
  # small upload on a 1GB board, before any of this module's caps could run.
  # (erl_tar's own `{max_size, N}` is not the fix: `extract1/4`'s
  # `size_tracked` clause counts skipped members too, so it would reject
  # legitimate multi-GB backups.)
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp table(path) do
    bounded(fn ->
      case :erl_tar.table(String.to_charlist(path), [:verbose]) do
        {:ok, entries} ->
          {:ok,
           Enum.map(entries, fn {name, type, size, _mtime, _mode, _uid, _gid} ->
             {to_string(name), type, size}
           end)}

        {:error, reason} ->
          {:error, {:untar, reason}}
      end
    end)
  end

  # Finds `wanted` among the table entries by its `./`-stripped name,
  # returning the name AS STORED (extraction must match it exactly).
  #
  # **Exactly one match, and it must be a regular file.** A tar may legally
  # carry the same name twice, and `:erl_tar.extract/2`'s `{:files, [...]}`
  # is set membership applied to EVERY member — so a size-checked first
  # match does not bound what extraction then materialises. The concrete
  # bypass: a 0-byte first `./backup.json` passes the cap, a huge second one
  # is extracted anyway. Refusing duplicates closes it at the only place
  # that can see both. The typeflag check goes with it: a link member
  # contributes no content in memory mode, so it could stand in as the
  # "small" entry.
  defp find_table_entry(entries, wanted) do
    case Enum.filter(entries, fn {name, _type, _size} -> strip_dot(name) == wanted end) do
      [{name, :regular, size}] -> {:ok, {name, size}}
      [] -> :error
      [{_name, _type, _size}] -> {:error, {:not_a_regular_file, wanted}}
      _duplicates -> {:error, {:duplicate_member, wanted}}
    end
  end

  defp guard_member_size(size, max) when size > max, do: {:error, :too_large}
  defp guard_member_size(_size, _max), do: :ok

  # Extracts exactly one member to memory; the rest of the tar is never read
  # into the BEAM. Heap-bounded for the same reason as `table/1` — the
  # extract pass resolves the same long-name headers.
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp extract_one(path, stored_name) do
    bounded(fn ->
      case :erl_tar.extract(String.to_charlist(path), [
             :memory,
             {:files, [String.to_charlist(stored_name)]}
           ]) do
        {:ok, [{_name, content}]} -> {:ok, content}
        {:ok, _other} -> {:error, {:missing_member, strip_dot(stored_name)}}
        {:error, reason} -> {:error, {:untar, reason}}
      end
    end)
  end

  # Runs `fun` in a throwaway process the VM kills if it exceeds
  # `@tar_read_heap_words`, so no amount of header forgery inside `:erl_tar`
  # can exhaust the node — the caller gets `{:error, {:tar_read_failed, _}}`
  # instead. The returned binary is not copied out of the child (refc
  # binaries are shared), so this costs a process spawn, not a data copy.
  defp bounded(fun) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(parent, {ref, fun.()}) end, [
        :monitor,
        {:max_heap_size, %{size: @tar_read_heap_words, kill: true, error_logger: true}}
      ])

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:tar_read_failed, reason}}
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
