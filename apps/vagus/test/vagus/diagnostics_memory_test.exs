defmodule Vagus.Diagnostics.MemoryTest do
  use ExUnit.Case, async: true

  alias Vagus.Diagnostics

  @meminfo """
  MemTotal:         970644 kB
  MemFree:          612340 kB
  MemAvailable:     801920 kB
  SwapTotal:        485320 kB
  SwapFree:         480000 kB
  """

  @pressure """
  some avg10=0.00 avg60=1.50 avg300=0.20 total=2383
  full avg10=0.00 avg60=0.10 avg300=0.00 total=250
  """

  @swaps """
  Filename\t\t\t\tType\t\tSize\tUsed\tPriority
  /dev/zram0                              partition\t485320\t5320\t100
  /data/swapfile                          file\t\t1048576\t0\t-2
  """

  setup context do
    dir = Path.join(System.tmp_dir!(), "vagus_diag_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    files = Map.get(context, :files, %{})

    defaults = %{
      meminfo: @meminfo,
      pressure: @pressure,
      thp_enabled: "always [madvise] never\n",
      lru_gen_enabled: "0x0007\n",
      swaps: @swaps
    }

    opts =
      for {key, default} <- defaults,
          contents = Map.get(files, key, default),
          contents != :absent do
        path = Path.join(dir, to_string(key))
        File.write!(path, contents)
        {key, path}
      end

    # Keys written as :absent get a path that does not exist, which is what
    # the caller sees for a kernel that never created the file.
    absent =
      for {key, _default} <- defaults,
          Map.get(files, key) == :absent,
          do: {key, Path.join(dir, "missing_#{key}")}

    %{opts: opts ++ absent}
  end

  test "reports every field from its source", %{opts: opts} do
    assert Diagnostics.memory(opts) == %{
             mem_total_bytes: 970_644 * 1024,
             mem_available_bytes: 801_920 * 1024,
             swap: %{total: 485_320 * 1024, free: 480_000 * 1024},
             pressure: %{
               some: %{avg10: 0.0, avg60: 1.5, avg300: 0.2, total: 2383},
               full: %{avg10: 0.0, avg60: 0.1, avg300: 0.0, total: 250}
             },
             thp: "madvise",
             lru_gen: "0x0007",
             swaps: ["/dev/zram0", "/data/swapfile"]
           }
  end

  @tag files: %{thp_enabled: "[always] madvise never\n"}
  test "thp reports whichever option is bracketed", %{opts: opts} do
    assert %{thp: "always"} = Diagnostics.memory(opts)
  end

  @tag files: %{thp_enabled: :absent}
  test "an absent THP file is :unavailable, the expected value on stock Nerves", %{opts: opts} do
    assert %{thp: :unavailable} = Diagnostics.memory(opts)
  end

  @tag files: %{thp_enabled: "always madvise never\n"}
  test "a THP file with nothing bracketed is :unavailable", %{opts: opts} do
    assert %{thp: :unavailable} = Diagnostics.memory(opts)
  end

  @tag files: %{lru_gen_enabled: :absent}
  test "an absent lru_gen file is :unavailable", %{opts: opts} do
    assert %{lru_gen: :unavailable} = Diagnostics.memory(opts)
  end

  @tag files: %{lru_gen_enabled: "\n"}
  test "an empty lru_gen file is :unavailable", %{opts: opts} do
    assert %{lru_gen: :unavailable} = Diagnostics.memory(opts)
  end

  @tag files: %{pressure: :absent}
  test "absent PSI is :unavailable, not a raise", %{opts: opts} do
    assert %{pressure: :unavailable, mem_total_bytes: total} = Diagnostics.memory(opts)
    assert total == 970_644 * 1024
  end

  @tag files: %{pressure: "some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n"}
  test "unparsable PSI is :unavailable", %{opts: opts} do
    assert %{pressure: :unavailable} = Diagnostics.memory(opts)
  end

  @tag files: %{meminfo: :absent}
  test "an absent meminfo makes every meminfo field :unavailable", %{opts: opts} do
    assert %{
             mem_total_bytes: :unavailable,
             mem_available_bytes: :unavailable,
             swap: :unavailable
           } = Diagnostics.memory(opts)
  end

  @tag files: %{meminfo: "MemTotal: 2048 kB\n"}
  test "meminfo fields are independent of each other", %{opts: opts} do
    assert %{
             mem_total_bytes: 2_097_152,
             mem_available_bytes: :unavailable,
             swap: :unavailable
           } = Diagnostics.memory(opts)
  end

  @tag files: %{swaps: "Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n"}
  test "a board with no swap active reports an empty list, not :unavailable", %{opts: opts} do
    assert %{swaps: []} = Diagnostics.memory(opts)
  end

  @tag files: %{swaps: :absent}
  test "an absent /proc/swaps is :unavailable", %{opts: opts} do
    assert %{swaps: :unavailable} = Diagnostics.memory(opts)
  end

  test "reads the real /proc and /sys on this host" do
    # The seams above prove the parsing; this proves the default paths are
    # the ones a board actually has. Fields absent on this kernel are
    # :unavailable, which is exactly what the function promises.
    result = Diagnostics.memory()

    assert is_integer(result.mem_total_bytes) and result.mem_total_bytes > 0
    assert result.mem_available_bytes == :unavailable or is_integer(result.mem_available_bytes)
    assert result.swaps == :unavailable or is_list(result.swaps)
  end
end
