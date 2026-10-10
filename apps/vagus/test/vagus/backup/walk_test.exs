defmodule Vagus.Backup.WalkTest do
  use ExUnit.Case, async: true

  alias Vagus.Backup.Walk

  @moduletag :tmp_dir

  @root? elem(System.cmd("id", ["-u"]), 0) == "0\n"

  defp collect(root, opts \\ []) do
    with {:ok, entries} <- Walk.each_entry(root, [], &{:cont, [&1 | &2]}, opts) do
      {:ok, Enum.reverse(entries)}
    end
  end

  defp rels(entries), do: Enum.map(entries, &elem(&1, 1))

  defp frame(payload), do: <<byte_size(payload)::32, payload::binary>>

  # A stand-in walker that replays fixed frames, for the failures the real
  # walker cannot be made to produce on demand.
  defp fake_walker(dir, frames, exit_code) do
    bin = Path.join(dir, "frames.bin")
    File.write!(bin, Enum.map(frames, &frame/1))
    script = Path.join(dir, "walker.sh")
    File.write!(script, "#!/bin/sh\ncat '#{bin}'\nexit #{exit_code}\n")
    File.chmod!(script, 0o755)
    script
  end

  defp own_ports do
    Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, self()}))
  end

  test "a nested tree round-trips with names, modes, sizes and bytes", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join(root, "a/b"))
    File.mkdir_p!(Path.join(root, "empty"))
    big = :crypto.strong_rand_bytes(200_000)
    File.write!(Path.join(root, "a/b/big.bin"), big)
    File.write!(Path.join(root, "a/small.txt"), "hello")
    File.write!(Path.join(root, "zero"), "")
    File.chmod!(Path.join(root, "a/small.txt"), 0o640)
    File.chmod!(Path.join(root, "a/b/big.bin"), 0o755)

    assert {:ok, entries} = collect(root)

    assert Enum.sort(rels(entries)) ==
             ["a", "a/b", "a/b/big.bin", "a/small.txt", "empty", "zero"]

    files = for {:file, rel, meta, bytes} <- entries, into: %{}, do: {rel, {meta, bytes}}
    assert {%{mode: 0o755, size: 200_000}, ^big} = files["a/b/big.bin"]
    assert {%{mode: 0o640, size: 5, mtime: mtime}, "hello"} = files["a/small.txt"]
    assert mtime == File.stat!(Path.join(root, "a/small.txt"), time: :posix).mtime
    assert {%{size: 0}, ""} = files["zero"]

    assert {:dir, "a"} in entries and {:dir, "a/b"} in entries
    # A parent is always announced before anything under it.
    assert Enum.find_index(entries, &(&1 == {:dir, "a/b"})) <
             Enum.find_index(entries, &match?({:file, "a/b/big.bin", _, _}, &1))

    assert own_ports() == []
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "symlinks to a file and to a directory are skipped, never followed", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "marker"), "SECRET")
    File.ln_s!(Path.join(outside, "marker"), Path.join(root, "file_link"))
    File.ln_s!(outside, Path.join(root, "dir_link"))

    assert {:ok, entries} = collect(root)
    assert {:skip, "file_link", :symlink} in entries
    assert {:skip, "dir_link", :symlink} in entries
    assert length(entries) == 2
    refute Enum.any?(entries, &match?({:file, _, _, "SECRET"}, &1))
  end

  test "a directory swapped for a symlink during the walk is not followed", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "marker"), "SECRET")

    for top <- ["one", "two"] do
      File.mkdir_p!(Path.join([root, top, "sub"]))
      File.write!(Path.join([root, top, "sub", "ok"]), "ok")
      File.write!(Path.join([root, top, "big"]), :binary.copy(<<0>>, 16 * 1024 * 1024))
    end

    # readdir order is the filesystem's; learn which top-level directory the
    # walker reaches second, so the swap lands while it is still streaming
    # the first one's 16 MiB file.
    {:ok, dry} = collect(root)
    [_first, second] = for {:dir, top} <- dry, not String.contains?(top, "/"), do: top
    victim = Path.join([root, second, "sub"])

    swap = fn entry, acc ->
      if acc == [] do
        File.rm_rf!(victim)
        File.ln_s!(outside, victim)
      end

      {:cont, [entry | acc]}
    end

    assert {:ok, entries} = Walk.each_entry(root, [], swap)
    assert {:skip, rel, reason} = Enum.find(entries, &(elem(&1, 1) == "#{second}/sub"))
    assert rel == "#{second}/sub" and reason in [:symlink, :eloop]
    refute Enum.any?(entries, &String.starts_with?(elem(&1, 1), "#{second}/sub/"))
    refute Enum.any?(entries, &match?({:file, _, _, "SECRET"}, &1))
  end

  test "a fifo is skipped without blocking the walk", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("mkfifo", [Path.join(root, "pipe")])
    File.write!(Path.join(root, "after"), "x")

    task = Task.async(fn -> collect(root) end)
    assert {:ok, entries} = Task.await(task, 5_000)
    assert {:skip, "pipe", :fifo} in entries
    assert Enum.any?(entries, &match?({:file, "after", _, "x"}, &1))
  end

  if @root?, do: @tag(skip: "root opens a mode-000 file")

  test "a file the walker cannot open fails the walk", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(root)
    path = Path.join(root, "locked")
    File.write!(path, "x")
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)

    assert {:error, {:read, "locked", :eacces}} = collect(root)
  end

  test "an X frame fails the walk after the entries before it", %{tmp_dir: tmp} do
    walker =
      fake_walker(tmp, ["Ff\0420\0" <> "0\0" <> "3", "Cabc", "E", "Xg\0eio"], 1)

    me = self()

    fun = fn entry, acc ->
      send(me, {:entry, entry})
      {:cont, acc}
    end

    assert {:error, {:read, "g", :eio}} = Walk.each_entry(tmp, nil, fun, executable: walker)
    assert_received {:entry, {:file, "f", %{mode: 0o644, size: 3}, "abc"}}
  end

  test "a walker that exits non-zero mid-walk fails it", %{tmp_dir: tmp} do
    walker = fake_walker(tmp, ["Da"], 3)
    assert {:error, {:walker, 3}} = collect(tmp, executable: walker)
    assert own_ports() == []
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "a walker that exits 0 without Z is not a complete walk", %{tmp_dir: tmp} do
    assert {:error, {:walker, 0}} = collect(tmp, executable: fake_walker(tmp, ["Da"], 0))
  end

  for {name, frames} <- [
        unknown_tag: ["Q"],
        escaping_path: ["D../etc"],
        absolute_path: ["D/etc"],
        chunk_outside_a_file: ["Cabc"],
        overlong_file: ["Ff\0420\0" <> "0\0" <> "1", "Cab"],
        unknown_skip_reason: ["Sx\0whatever"],
        bad_number: ["Ff\0rw\0" <> "0\0" <> "1"]
      ] do
    test "a malformed frame fails the walk: #{name}", %{tmp_dir: tmp} do
      walker = fake_walker(tmp, unquote(frames) ++ ["Z"], 0)
      assert {:error, :malformed} = collect(tmp, executable: walker)
    end
  end

  test "the byte cap fails the walk", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join(root, "d"))
    File.write!(Path.join(root, "d/one"), :binary.copy("a", 60))
    File.write!(Path.join(root, "two"), :binary.copy("b", 60))

    assert {:error, :too_large} = collect(root, max_bytes: 100)
    assert {:ok, _} = collect(root, max_bytes: 120)
  end

  test "halting stops the walk and closes the port", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    for i <- 1..50, do: File.mkdir_p!(Path.join(root, "d#{i}"))

    assert {:ok, :stopped} = Walk.each_entry(root, nil, fn _, _ -> {:halt, :stopped} end)
    assert own_ports() == []
    assert {:messages, []} = Process.info(self(), :messages)
  end
end
