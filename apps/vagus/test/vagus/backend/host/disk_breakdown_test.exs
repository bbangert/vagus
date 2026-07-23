defmodule Vagus.Backend.Host.DiskBreakdownTest do
  use ExUnit.Case, async: true

  alias Vagus.Backend.Host.DiskBreakdown

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "vagus_disk_breakdown_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write_bytes(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, bytes))
  end

  defp usage(root, opts) do
    defaults = [
      data_root: root,
      homeassistant_path: Path.join(root, "ha_config"),
      df: fn _path -> {1_000_000, 400_000} end
    ]

    DiskBreakdown.usage(Keyword.merge(defaults, opts))
  end

  test "root node shape: totals from df, used = total - free", %{root: root} do
    result = usage(root, [])

    assert result.id == "root"
    assert result.label == "Root"
    assert result.total_bytes == 1_000_000
    assert result.used_bytes == 600_000
    assert [%{id: "system"} | _known] = result.children
  end

  test "known dirs report recursive sizes; system child absorbs the rest", %{root: root} do
    write_bytes(Path.join(root, "backup/one.tar"), 1_000)
    write_bytes(Path.join(root, "backup/two.tar"), 2_000)
    write_bytes(Path.join(root, "share/nested/deep/file"), 500)
    write_bytes(Path.join(root, "ha_config/configuration.yaml"), 300)

    result = usage(root, [])
    by_id = Map.new(result.children, &{&1.id, &1})

    assert by_id["backup"].used_bytes == 3_000
    assert by_id["share"].used_bytes == 500
    assert by_id["homeassistant"].used_bytes == 300
    # 600_000 used minus the 3_800 attributed above.
    assert by_id["system"].used_bytes == 596_200
    # Every known dir is present even when empty/missing.
    for id <- ~w(addons_data addons_config media share backup ssl homeassistant system) do
      assert Map.has_key?(by_id, id), "missing child #{id}"
    end
  end

  test "missing dirs honestly report zero with no children key", %{root: root} do
    result = usage(root, [])
    media = Enum.find(result.children, &(&1.id == "media"))

    assert media.used_bytes == 0
    refute Map.has_key?(media, :children)
  end

  test "children nest only to max_depth; sizes stay fully recursive", %{root: root} do
    write_bytes(Path.join(root, "backup/inner/deep/file"), 700)

    shallow = usage(root, max_depth: 1)
    backup = Enum.find(shallow.children, &(&1.id == "backup"))
    assert backup.used_bytes == 700
    refute Map.has_key?(backup, :children)

    deep = usage(root, max_depth: 3)
    backup = Enum.find(deep.children, &(&1.id == "backup"))

    assert [%{id: "inner", label: "inner", used_bytes: 700, children: inner_children}] =
             backup.children

    assert [%{id: "deep", used_bytes: 700}] = inner_children
  end

  test "empty subdirectories are not listed as children", %{root: root} do
    File.mkdir_p!(Path.join(root, "backup/empty"))
    write_bytes(Path.join(root, "backup/full/file"), 10)

    result = usage(root, max_depth: 2)
    backup = Enum.find(result.children, &(&1.id == "backup"))

    assert Enum.map(backup.children, & &1.id) == ["full"]
  end

  test "symlinks are skipped entirely (loop safety)", %{root: root} do
    write_bytes(Path.join(root, "share/real"), 100)
    File.ln_s!(Path.join(root, "share"), Path.join(root, "share/loop"))

    result = usage(root, max_depth: 2)
    share = Enum.find(result.children, &(&1.id == "share"))

    assert share.used_bytes == 100
  end

  test "system child never goes negative when attribution exceeds df's used", %{root: root} do
    write_bytes(Path.join(root, "backup/big.tar"), 5_000)

    result = usage(root, df: fn _path -> {10_000, 9_000} end)
    system = Enum.find(result.children, &(&1.id == "system"))

    assert system.used_bytes == 0
    assert result.used_bytes == 1_000
  end
end
