defmodule Vagus.BackupTest do
  @moduledoc "P6-T1: unprotected backup create/read/extract round-trip."
  use ExUnit.Case, async: true

  alias Vagus.Backup

  setup do
    root = Path.join(System.tmp_dir!(), "vagus-bk-test-#{System.unique_integer([:positive])}")
    data = Path.join(root, "data")
    File.mkdir_p!(Path.join(data, "sub"))
    File.write!(Path.join(data, "options.json"), ~s({"require_certificate":false}))
    File.write!(Path.join(data, "sub/nested.txt"), "nested content")
    on_exit(fn -> File.rm_rf(root) end)
    %{data: data}
  end

  defp spec(data) do
    %{
      slug: "backup_abc",
      name: "Test backup",
      supervisor_version: "vagus",
      addons: [
        %{slug: "core_mosquitto", name: "Mosquitto broker", version: "7.1.0", data_dir: data}
      ]
    }
  end

  test "create produces a readable backup.json with the §A4 shape", %{data: data} do
    {:ok, tar} = Backup.create(spec(data), date: "2026-07-21T00:00:00Z")
    {:ok, %{backup: b, members: members}} = Backup.read(tar)

    assert b["slug"] == "backup_abc"
    assert b["type"] == "partial"
    assert b["version"] == 2
    assert b["protected"] == false
    assert b["compressed"] == true
    assert b["date"] == "2026-07-21T00:00:00Z"

    assert [
             %{
               "slug" => "core_mosquitto",
               "name" => "Mosquitto broker",
               "version" => "7.1.0",
               "size" => sz
             }
           ] = b["addons"]

    assert sz > 0
    assert "./backup.json" in members
    assert "./core_mosquitto.tar.gz" in members
  end

  test "extract_addon round-trips addon.json + the /data tree", %{data: data} do
    {:ok, tar} = Backup.create(spec(data))
    {:ok, %{addon: addon, data: files}} = Backup.extract_addon(tar, "core_mosquitto")

    assert addon["version"] == "7.1.0"
    assert addon["state"] == "started"

    map = Map.new(files)
    assert map["options.json"] == ~s({"require_certificate":false})
    assert map["sub/nested.txt"] == "nested content"
  end

  test "extract_addon on an absent add-on → :not_in_backup", %{data: data} do
    {:ok, tar} = Backup.create(spec(data))
    assert {:error, :not_in_backup} = Backup.extract_addon(tar, "core_ghost")
  end

  test "read rejects a non-backup tar" do
    assert {:error, _} = Backup.read("not a tar at all")
  end

  test "extract_addon refuses a data member that escapes /data (zip-slip, W4)" do
    # Hand-build a malicious backup: inner tar with a `data/../escape` member.
    inner =
      build_tar(
        [
          {~c"./addon.json", ~s({"version":"1","state":"started"})},
          {~c"./data/../escape.txt", "pwned"}
        ],
        compressed: true
      )

    outer = build_tar([{~c"./evil.tar.gz", inner}], compressed: false)

    case Backup.extract_addon(outer, "evil") do
      {:error, {:unsafe_path, _}} -> :ok
      {:ok, %{data: data}} -> refute Enum.any?(data, fn {p, _} -> String.contains?(p, "..") end)
    end
  end

  # Build a tar in memory (mirrors Vagus.Backup's own erl_tar temp-file sink).
  defp build_tar(members, compressed: compressed?) do
    path = Path.join(System.tmp_dir!(), "vagus-mal-#{System.unique_integer([:positive])}.tar")
    open = if compressed?, do: [:write, :compressed], else: [:write]
    {:ok, t} = :erl_tar.open(String.to_charlist(path), open)
    Enum.each(members, fn {n, b} -> :ok = :erl_tar.add(t, b, n, []) end)
    :ok = :erl_tar.close(t)
    bin = File.read!(path)
    File.rm(path)
    bin
  end

  test "an add-on with no data dir still backs up (empty data)", %{data: _data} do
    s = %{
      slug: "b",
      name: "n",
      supervisor_version: "2026.07.3",
      addons: [%{slug: "x", name: "X", version: "1.0", data_dir: "/nonexistent"}]
    }

    {:ok, tar} = Backup.create(s)
    {:ok, %{data: files}} = Backup.extract_addon(tar, "x")
    assert files == []
  end

  # The file API (audit C6) — nothing here may load the outer tar, and every
  # guard has to hold against a tar the caller wrote (a `hassio_role: backup`
  # add-on can upload one since phase 1).
  describe "file API: read_file/1 + extract_addon_file/2" do
    setup %{data: data} do
      path =
        Path.join(System.tmp_dir!(), "vagus-fileapi-#{System.unique_integer([:positive])}.tar")

      {:ok, tar} = Backup.create(spec(data), date: "2026-07-30T00:00:00Z")
      File.write!(path, tar)
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "read_file/1 matches read/1 without loading the tar", %{path: path} do
      {:ok, %{backup: from_file, members: members}} = Backup.read_file(path)
      {:ok, %{backup: from_binary}} = Backup.read(File.read!(path))

      assert from_file == from_binary
      assert "./backup.json" in members
      assert "./core_mosquitto.tar.gz" in members
    end

    test "extract_addon_file/2 matches extract_addon/2, and 404s an absent add-on", %{path: path} do
      {:ok, %{addon: addon, data: files}} = Backup.extract_addon_file(path, "core_mosquitto")
      assert addon["version"] == "7.1.0"
      assert Map.new(files)["options.json"] == ~s({"require_certificate":false})

      assert {:error, :not_in_backup} = Backup.extract_addon_file(path, "core_ghost")
    end

    # The compressed pre-filter must not be the uncompressed cap: gzip can
    # exceed its input on incompressible data, so an add-on that inflates to
    # just under 256MB can have a member just over it (Copilot, PR #30).
    # Proven at small scale — random bytes are incompressible, so the gzipped
    # member here is LARGER than its payload, and the read must still succeed.
    test "an inner member whose gzip exceeds its payload still extracts" do
      payload = :crypto.strong_rand_bytes(200_000)

      inner =
        build_tar(
          [
            {~c"./addon.json", ~s({"version":"1","state":"stopped"})},
            {~c"./data/random.bin", payload}
          ],
          compressed: true
        )

      assert byte_size(inner) > byte_size(payload),
             "expected incompressible data to grow under gzip"

      path = write_raw([{~c"./grow.tar.gz", inner}])

      assert {:ok, %{data: files}} = Backup.extract_addon_file(path, "grow")
      assert Map.new(files)["random.bin"] == payload
      File.rm(path)
    end

    test "read_file/1 on a tar with no backup.json is a missing-member error" do
      path = write_raw([{~c"./nothing.txt", "x"}])
      assert {:error, {:missing_member, "backup.json"}} = Backup.read_file(path)
      File.rm(path)
    end

    test "an oversized backup.json is refused by size, before extraction" do
      # 1MB cap; 2MB of JSON never reaches Jason.
      big = Jason.encode!(%{"slug" => "big", "pad" => String.duplicate("x", 2_000_000)})
      path = write_raw([{~c"./backup.json", big}])

      assert {:error, :too_large} = Backup.read_file(path)
      File.rm(path)
    end

    # The bypass a first-match size check cannot see: `{:files, [name]}` is
    # set membership applied to EVERY member, so a small first entry would
    # otherwise let a huge same-named second one be materialised.
    test "a duplicated member name is refused rather than size-checked once" do
      path =
        write_raw([
          {~c"./backup.json", "{}"},
          {~c"./backup.json", String.duplicate("x", 2_000_000)}
        ])

      assert {:error, {:duplicate_member, "backup.json"}} = Backup.read_file(path)
      File.rm(path)
    end

    test "a non-regular member standing in for backup.json is refused" do
      path = Path.join(System.tmp_dir!(), "vagus-link-#{System.unique_integer([:positive])}.tar")

      real =
        Path.join(System.tmp_dir!(), "vagus-link-target-#{System.unique_integer([:positive])}")

      File.write!(real, "{}")
      link = Path.join(System.tmp_dir!(), "backup.json")
      File.rm(link)
      :ok = File.ln_s(real, link)

      {:ok, t} = :erl_tar.open(String.to_charlist(path), [:write])
      :ok = :erl_tar.add(t, String.to_charlist(link), ~c"./backup.json", [])
      :ok = :erl_tar.close(t)

      assert {:error, {:not_a_regular_file, "backup.json"}} = Backup.read_file(path)

      File.rm(path)
      File.rm(link)
      File.rm(real)
    end

    # A forged GNU longname ('L') header makes erl_tar materialise the
    # claimed payload as a charlist (~16 bytes per byte) during the TABLE
    # pass — measured at a 970MB heap delta for a 19MB payload, i.e. an OOM
    # from a small upload. The read runs in a heap-capped process so the
    # amplification is bounded to an error instead.
    test "a long-name amplification bomb is bounded to an error, not an OOM" do
      payload = 40_000_000
      path = write_longname_bomb(payload)

      assert {:error, {:tar_read_failed, _reason}} = Backup.read_file(path)
      File.rm(path)
    end
  end

  defp write_raw(members) do
    path = Path.join(System.tmp_dir!(), "vagus-raw-#{System.unique_integer([:positive])}.tar")
    {:ok, t} = :erl_tar.open(String.to_charlist(path), [:write])
    Enum.each(members, fn {name, bin} -> :ok = :erl_tar.add(t, bin, name, []) end)
    :ok = :erl_tar.close(t)
    path
  end

  # Hand-forged tar: an `'L'` (GNU longname) header claiming `size` bytes of
  # name payload. erl_tar resolves it inline on the table pass.
  defp write_longname_bomb(size) do
    path = Path.join(System.tmp_dir!(), "vagus-bomb-#{System.unique_integer([:positive])}.tar")

    header =
      fn name, sz, typeflag ->
        prefix =
          String.pad_trailing(name, 100, <<0>>) <>
            String.pad_trailing("0000644", 8, <<0>>) <>
            String.pad_trailing("0000000", 8, <<0>>) <>
            String.pad_trailing("0000000", 8, <<0>>) <>
            String.pad_trailing(to_string(:io_lib.format("~11.8.0B", [sz])), 12, <<0>>) <>
            String.pad_trailing("00000000000", 12, <<0>>)

        tail =
          typeflag <>
            String.duplicate(<<0>>, 100) <>
            "ustar" <> <<0>> <> "00" <> String.duplicate(<<0>>, 247)

        probe = binary_part(prefix <> String.duplicate(" ", 8) <> tail, 0, 512)
        sum = probe |> :binary.bin_to_list() |> Enum.sum()

        checksum =
          String.pad_trailing(to_string(:io_lib.format("~6.8.0B", [sum])) <> <<0, 32>>, 8, <<0>>)

        prefix <> checksum <> binary_part(probe, 156, 512 - 156)
      end

    pad = fn bin ->
      case rem(byte_size(bin), 512) do
        0 -> bin
        r -> bin <> String.duplicate(<<0>>, 512 - r)
      end
    end

    File.write!(
      path,
      header.("././@LongLink", size, "L") <>
        pad.(String.duplicate("A", size)) <>
        header.("shortname", 0, "0") <>
        String.duplicate(<<0>>, 1024)
    )

    path
  end
end
