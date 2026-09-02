defmodule Vagus.Platform.MemoryTest do
  @moduledoc "Field parsing out of /proc/meminfo."
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

  # The same board once `Vagus.Host.Swap` has brought zram up.
  @rpi3_with_swap @rpi3_meminfo <>
                    """
                    SwapCached:         1024 kB
                    SwapTotal:        485320 kB
                    SwapFree:         480000 kB
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

  describe "available_bytes/1" do
    test "parses MemAvailable from a real rpi3 /proc/meminfo" do
      assert Memory.available_bytes(fixture(@rpi3_meminfo)) == {:ok, 801_920 * 1024}
    end

    test "does not confuse MemAvailable with MemTotal or MemFree" do
      path = fixture(@rpi3_meminfo)
      assert Memory.available_bytes(path) != Memory.total_bytes(path)
      refute Memory.available_bytes(path) == {:ok, 612_340 * 1024}
    end

    test "a zero MemAvailable parses rather than failing" do
      assert {:ok, 0} = Memory.available_bytes(fixture("MemAvailable: 0 kB\n"))
    end

    test "a file with no MemAvailable line is :error" do
      assert :error = Memory.available_bytes(fixture("MemTotal: 2048 kB\n"))
    end

    test "a missing file is :error" do
      assert :error = Memory.available_bytes(Path.join(System.tmp_dir!(), "vagus_no_meminfo"))
    end

    test "a non-numeric MemAvailable is :error" do
      assert :error = Memory.available_bytes(fixture("MemAvailable: plenty kB\n"))
    end
  end

  describe "swap_bytes/1" do
    test "parses SwapTotal and SwapFree" do
      assert Memory.swap_bytes(fixture(@rpi3_with_swap)) ==
               {:ok, %{total: 485_320 * 1024, free: 480_000 * 1024}}
    end

    # The normal case on every board until the memory-tuning system release
    # lands: swap exists as fields, at size zero.
    test "zero swap parses as zero, not :error" do
      assert Memory.swap_bytes(fixture(@rpi3_meminfo <> "SwapTotal: 0 kB\nSwapFree: 0 kB\n")) ==
               {:ok, %{total: 0, free: 0}}
    end

    test "does not confuse SwapCached with SwapFree" do
      assert {:ok, %{free: free}} = Memory.swap_bytes(fixture(@rpi3_with_swap))
      assert free == 480_000 * 1024
    end

    test "a missing SwapFree line is :error" do
      assert :error = Memory.swap_bytes(fixture("SwapTotal: 100 kB\n"))
    end

    test "a missing SwapTotal line is :error" do
      assert :error = Memory.swap_bytes(fixture("SwapFree: 100 kB\n"))
    end

    test "a missing file is :error" do
      assert :error = Memory.swap_bytes(Path.join(System.tmp_dir!(), "vagus_no_meminfo"))
    end

    test "a garbage SwapTotal is :error" do
      assert :error = Memory.swap_bytes(fixture("SwapTotal: lots kB\nSwapFree: 1 kB\n"))
    end

    test "reads the real /proc/meminfo on Linux" do
      if File.exists?("/proc/meminfo") do
        assert {:ok, %{total: total, free: free}} = Memory.swap_bytes()
        assert total >= 0 and free >= 0
      end
    end
  end
end
