defmodule Vagus.Platform.MemoryTest do
  @moduledoc "P2-A P0: `MemTotal` parsing out of /proc/meminfo."
  use ExUnit.Case, async: true

  alias Vagus.Platform.Memory

  # Verbatim head of /proc/meminfo from a Raspberry Pi 3 B+ running Nerves
  # with gpu_mem=16 — the board the `:disk` asset mode exists for. The point
  # of using the real numbers is that 970644 kB is ~0.926 GiB, i.e. a "1 GB"
  # board that does not report 1 GiB.
  @rpi3_meminfo """
  MemTotal:         970644 kB
  MemFree:          612340 kB
  MemAvailable:     801920 kB
  Buffers:            8192 kB
  Cached:           142336 kB
  """

  defp fixture(contents) do
    path = Path.join(System.tmp_dir!(), "vagus_meminfo_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "parses MemTotal from a real rpi3 /proc/meminfo" do
    assert Memory.total_bytes(fixture(@rpi3_meminfo)) == {:ok, 970_644 * 1024}
  end

  test "MemTotal need not be the first line" do
    contents = "MemFree: 100 kB\nMemTotal: 2048 kB\n"
    assert Memory.total_bytes(fixture(contents)) == {:ok, 2048 * 1024}
  end

  test "a unit-less MemTotal is read as bytes" do
    assert {:ok, 4096} = Memory.total_bytes(fixture("MemTotal: 4096\n"))
  end

  test "a missing file is :error, not a raise" do
    assert :error = Memory.total_bytes(Path.join(System.tmp_dir!(), "vagus_no_such_meminfo"))
  end

  test "a file with no MemTotal line is :error" do
    assert :error = Memory.total_bytes(fixture("MemFree: 100 kB\n"))
  end

  test "an empty file is :error" do
    assert :error = Memory.total_bytes(fixture(""))
  end

  for {label, line} <- [
        {"a non-numeric value", "MemTotal: plenty kB\n"},
        {"an unrecognised unit", "MemTotal: 512 MB\n"},
        {"a zero value", "MemTotal: 0 kB\n"},
        {"a negative value", "MemTotal: -1 kB\n"},
        {"a truncated line", "MemTotal:\n"}
      ] do
    test "#{label} is :error" do
      assert :error = Memory.total_bytes(fixture(unquote(line)))
    end
  end

  test "reads the real /proc/meminfo on Linux" do
    # Guards the assumption the whole module rests on: procfs files report a
    # size of 0, and `File.read/1` still returns their contents.
    if File.exists?("/proc/meminfo") do
      assert {:ok, bytes} = Memory.total_bytes()
      assert bytes > 0
    end
  end
end
