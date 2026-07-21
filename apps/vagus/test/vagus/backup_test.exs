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

  test "an add-on with no data dir still backs up (empty data)", %{data: _data} do
    s = %{
      slug: "b",
      name: "n",
      addons: [%{slug: "x", name: "X", version: "1.0", data_dir: "/nonexistent"}]
    }

    {:ok, tar} = Backup.create(s)
    {:ok, %{data: files}} = Backup.extract_addon(tar, "x")
    assert files == []
  end
end
