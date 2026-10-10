defmodule Vagus.Backup.WalkTest do
  use ExUnit.Case, async: true

  alias Vagus.Backup.Walk

  @moduletag :tmp_dir

  @root? elem(System.cmd("id", ["-u"]), 0) == "0\n"

  defp spool_dir(tmp) do
    dir = Path.join(tmp, "spool")
    File.mkdir_p!(dir)
    dir
  end

  defp walk(tmp, root, acc, fun, opts \\ []),
    do: Walk.each_entry(root, acc, fun, [spool_dir: spool_dir(tmp)] ++ opts)

  # Reads each spooled file inside the callback, while it still exists.
  defp collect(tmp, root, opts \\ []) do
    fun = fn
      {:file, rel, meta, path}, acc -> {:cont, [{:file, rel, meta, File.read!(path)} | acc]}
      entry, acc -> {:cont, [entry | acc]}
    end

    with {:ok, entries} <- walk(tmp, root, [], fun, opts), do: {:ok, Enum.reverse(entries)}
  end

  defp rels(entries), do: Enum.map(entries, &elem(&1, 1))

  defp frame({:file, rel, mode, mtime, size}),
    do: "F" <> Enum.join([rel, mode, mtime, size], <<0>>)

  defp frame(frame), do: frame

  # A stand-in walker that replays fixed frames, for the failures the real
  # walker cannot be made to produce on demand. Like the real one it waits
  # for an ack after each frame but X and Z; `{:raw, bytes}` is written as
  # is and `{:file, rel, mode, mtime, size}` becomes an F frame.
  defp fake_walker(dir, frames, exit_code, tail \\ nil) do
    lines =
      frames
      |> Enum.with_index()
      |> Enum.map(fn {frame, i} ->
        bin = Path.join(dir, "frame#{i}.bin")
        cat = ~s(cat "$dir/frame#{i}.bin")

        case frame(frame) do
          {:raw, bytes} ->
            File.write!(bin, bytes)
            cat

          <<tag, _::binary>> = payload ->
            File.write!(bin, <<byte_size(payload)::32, payload::binary>>)
            if tag in [?X, ?Z], do: cat, else: cat <> "; head -c 4 >/dev/null"
        end
      end)

    script = Path.join(dir, "walker.sh")

    body =
      Enum.join(
        [~s|#!/bin/sh\ndir="$(dirname "$0")"\necho $$ > "$dir/walker.pid"|] ++ lines,
        "\n"
      )

    File.write!(script, body <> "\n" <> (tail || "exit #{exit_code}") <> "\n")
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

    assert {:ok, entries} = collect(tmp, root)

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

    assert File.ls!(spool_dir(tmp)) == []
    assert own_ports() == []
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "a spool file the callback keeps is left for it to move", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    kept = Path.join(tmp, "kept")
    File.mkdir_p!(root)
    File.mkdir_p!(kept)
    File.write!(Path.join(root, "one"), "1")
    File.write!(Path.join(root, "two"), "22")

    move = fn {:file, rel, _, path}, acc ->
      File.rename!(path, Path.join(kept, rel))
      {:cont, acc, :keep}
    end

    assert {:ok, nil} = walk(tmp, root, nil, move)
    assert File.read!(Path.join(kept, "one")) == "1"
    assert File.read!(Path.join(kept, "two")) == "22"
    assert File.ls!(spool_dir(tmp)) == []

    # :keep promises the file was moved; one left in place is not clobbered.
    assert {:error, {:spool, :eexist}} =
             walk(tmp, root, nil, fn {:file, _, _, _}, acc -> {:cont, acc, :keep} end)
  end

  test "symlinks to a file and to a directory are skipped, never followed", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "marker"), "SECRET")
    File.ln_s!(Path.join(outside, "marker"), Path.join(root, "file_link"))
    File.ln_s!(outside, Path.join(root, "dir_link"))

    assert {:ok, entries} = collect(tmp, root)
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
    end

    # readdir order is the filesystem's, so learn which top-level directory
    # comes second. The swap runs in the callback for the first entry, while
    # the walker waits for its ack and has not yet opened the second.
    {:ok, dry} = collect(tmp, root)
    [_first, second] = for {:dir, top} <- dry, not String.contains?(top, "/"), do: top
    victim = Path.join([root, second, "sub"])

    swap = fn entry, acc ->
      if acc == [] do
        File.rm_rf!(victim)
        File.ln_s!(outside, victim)
      end

      {:cont, [entry | acc]}
    end

    swapped = "#{second}/sub"
    assert {:ok, entries} = walk(tmp, root, [], swap)
    assert {:skip, ^swapped, reason} = Enum.find(entries, &(elem(&1, 1) == swapped))
    assert reason in [:symlink, :eloop]
    refute Enum.any?(entries, &String.starts_with?(elem(&1, 1), swapped <> "/"))
    refute Enum.any?(entries, &match?({:file, _, _, "SECRET"}, &1))
  end

  test "a consumer slower than the walker never has more than a frame queued",
       %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(root)
    for i <- 1..20, do: File.write!(Path.join(root, "f#{i}"), :binary.copy("x", 100_000))

    slow = fn _entry, acc ->
      Process.sleep(20)
      {:message_queue_len, n} = Process.info(self(), :message_queue_len)
      {:cont, max(n, acc)}
    end

    assert {:ok, 0} = walk(tmp, root, 0, slow)
  end

  test "a directory deeper than 64 levels is skipped, the rest walked", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join([root | List.duplicate("d", 70)]))
    File.write!(Path.join([root | List.duplicate("d", 64)] ++ ["f"]), "deep")

    assert {:ok, entries} = collect(tmp, root)
    assert length(for {:dir, _} <- entries, do: 1) == 64
    assert {:skip, Enum.join(List.duplicate("d", 65), "/"), :depth} in entries

    deep_file = Enum.join(List.duplicate("d", 64) ++ ["f"], "/")
    assert Enum.any?(entries, &match?({:file, ^deep_file, %{size: 4}, "deep"}, &1))

    assert length(entries) == 66
  end

  test "a fifo is skipped without blocking the walk", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("mkfifo", [Path.join(root, "pipe")])
    File.write!(Path.join(root, "after"), "x")

    task = Task.async(fn -> collect(tmp, root) end)
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

    assert {:error, {:read, "locked", :eacces}} = collect(tmp, root)
  end

  test "a missing root fails the walk with its reason", %{tmp_dir: tmp} do
    assert {:error, {:read, "", :enoent}} = collect(tmp, Path.join(tmp, "nope"))
  end

  test "a missing walker binary is an error, not a raise", %{tmp_dir: tmp} do
    assert {:error, :no_walker} = collect(tmp, tmp, executable: Path.join(tmp, "nope"))
  end

  test "an X frame fails the walk after the entries before it", %{tmp_dir: tmp} do
    walker = fake_walker(tmp, [{:file, "f", 0o644, 0, 3}, "Cabc", "E", "Xg\0eio"], 1)

    assert {:error, {:read, "g", :eio}} =
             walk(tmp, tmp, nil, fn {:file, _, _, _} = e, _ -> {:cont, e} end, executable: walker)
  end

  test "an X frame in the middle of a file is that file's read error", %{tmp_dir: tmp} do
    walker = fake_walker(tmp, [{:file, "f", 0o644, 0, 3}, "Cab", "Xf\0eio"], 1)
    assert {:error, {:read, "f", :eio}} = collect(tmp, tmp, executable: walker)
    assert File.ls!(spool_dir(tmp)) == []
  end

  test "a walker that exits non-zero mid-walk fails it", %{tmp_dir: tmp} do
    walker = fake_walker(tmp, ["Da"], 3)
    assert {:error, {:walker, 3}} = collect(tmp, tmp, executable: walker)
    assert own_ports() == []
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "a walker that exits 0 without Z is not a complete walk", %{tmp_dir: tmp} do
    assert {:error, {:walker, 0}} = collect(tmp, tmp, executable: fake_walker(tmp, ["Da"], 0))
  end

  test "a frame cut short by the walker's exit fails the walk", %{tmp_dir: tmp} do
    walker = fake_walker(tmp, [{:raw, <<0, 0, 0, 9, "Dab">>}], 0)
    assert {:error, {:walker, 0}} = collect(tmp, tmp, executable: walker)
  end

  for {name, frames} <- [
        unknown_tag: ["Q"],
        escaping_path: ["D../etc"],
        absolute_path: ["D/etc"],
        empty_segment: ["Da//b"],
        dot: ["D."],
        dot_segment: ["Da/./b"],
        nul_in_path: ["Da\0b"],
        chunk_outside_a_file: ["Cabc"],
        overlong_file: [{:file, "f", 0o644, 0, 1}, "Cab"],
        unknown_skip_reason: ["Sx\0whatever"],
        # Complete files, so only the bad field can be what fails them.
        bad_number: [{:file, "f", "rw", 0, 1}, "Cx", "E"],
        mode_out_of_range: [{:file, "f", 0o10000, 0, 1}, "Cx", "E"],
        negative_mode: [{:file, "f", -5, 0, 1}, "Cx", "E"]
      ] do
    test "a malformed frame fails the walk: #{name}", %{tmp_dir: tmp} do
      walker = fake_walker(tmp, unquote(Macro.escape(frames)) ++ ["Z"], 0)
      assert {:error, :malformed} = collect(tmp, tmp, executable: walker)
    end
  end

  test "the byte cap fails the walk", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join(root, "d"))
    File.write!(Path.join(root, "d/one"), :binary.copy("a", 60))
    File.write!(Path.join(root, "two"), :binary.copy("b", 60))

    assert {:error, :too_large} = collect(tmp, root, max_bytes: 100)
    assert {:ok, _} = collect(tmp, root, max_bytes: 120)
  end

  test "halting stops the walk and closes the port", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    for i <- 1..50, do: File.mkdir_p!(Path.join(root, "d#{i}"))

    assert {:ok, :stopped} = walk(tmp, root, nil, fn _, _ -> {:halt, :stopped} end)
    assert own_ports() == []
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "halting kills a walker that would not notice its port closing", %{tmp_dir: tmp} do
    walker = fake_walker(tmp, [{:raw, <<0, 0, 0, 2, "Da">>}], 0, "exec sleep 30")

    assert {:ok, :stopped} =
             walk(tmp, tmp, nil, fn _, _ -> {:halt, :stopped} end, executable: walker)

    proc = "/proc/" <> String.trim(File.read!(Path.join(tmp, "walker.pid")))
    # Reaped by erl_child_setup shortly after the kill.
    assert Enum.any?(1..100, fn _ -> not File.exists?(proc) or (Process.sleep(20) && false) end)
  end

  test "a caller that traps exits is left with an empty mailbox", %{tmp_dir: tmp} do
    root = Path.join(tmp, "data")
    for i <- 1..5, do: File.mkdir_p!(Path.join(root, "d#{i}"))
    File.write!(Path.join(root, "f"), "x")
    me = self()

    # The capped walk closes a live walker (parked on its ack); the others
    # close a port whose walker has already exited.
    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      done = collect(tmp, root)
      halted = walk(tmp, root, nil, fn _, _ -> {:halt, :stopped} end)
      capped = collect(tmp, root, max_bytes: 0)
      failed = collect(tmp, tmp, executable: fake_walker(tmp, ["Da"], 3))
      Process.sleep(200)
      send(me, {[done, halted, capped, failed], Process.info(self(), :messages)})
    end)

    assert_receive {[{:ok, _}, {:ok, :stopped}, {:error, :too_large}, {:error, {:walker, 3}}],
                    {:messages, []}},
                   5_000
  end
end
