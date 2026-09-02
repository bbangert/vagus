defmodule Vagus.Platform.Memory do
  @moduledoc """
  Memory figures as reported by the kernel (`/proc/meminfo`).

  `total_bytes/1` exists so `Vagus.Addon.Store.AssetMode` can pick a
  store-asset retention strategy at boot: a board with less than 1 GiB keeps
  repository assets on disk instead of in memory. `Vagus.Host.Swap` sizes
  zram and the swapfile from the same figure, and
  `Vagus.Host.MemoryMonitor` samples `available_bytes/1` and `swap_bytes/1`
  for the soak data behind the swappiness and zram-size choices.

  Read-per-call and uncached, mirroring `Vagus.Backend.OS.Nerves`'s
  `/proc/mounts` read — the boot-time callers ask once and the monitor asks
  once a minute, so there is nothing to cache.

  Never raises: an unreadable, truncated or otherwise unexpected
  `/proc/meminfo` (a non-Linux dev host, a container with procfs masked)
  returns `:error` and the caller decides what that means.

  `MemTotal` is the kernel's post-reservation figure, not the marketing
  capacity of the board — a "1 GB" Raspberry Pi 3 reports roughly
  0.93–0.95 GiB once the kernel and `gpu_mem` have taken their cut. Callers
  comparing against a power-of-two threshold should expect that gap rather
  than treat it as a parse bug.
  """

  @meminfo_path "/proc/meminfo"

  @doc """
  Total RAM in bytes, or `:error` when `/proc/meminfo` can't be read or
  carries no usable `MemTotal:` line.

  `path` is for tests (fixture meminfo files); production always uses
  `#{@meminfo_path}`.
  """
  @spec total_bytes(Path.t()) :: {:ok, pos_integer()} | :error
  def total_bytes(path \\ @meminfo_path) do
    with {:ok, contents} <- read_meminfo(path) do
      find_field(contents, "MemTotal", 1)
    end
  end

  @doc """
  Allocatable RAM in bytes (`MemAvailable`), or `:error`.

  This is the kernel's own estimate of what a new allocation could get
  without swapping, which is the number worth watching — unlike `MemFree`,
  it counts the page cache and reclaimable slab that a healthy system is
  supposed to be filling.
  """
  @spec available_bytes(Path.t()) :: {:ok, non_neg_integer()} | :error
  def available_bytes(path \\ @meminfo_path) do
    with {:ok, contents} <- read_meminfo(path) do
      find_field(contents, "MemAvailable", 0)
    end
  end

  @doc """
  Swap size and unused swap in bytes, or `:error` when either line is
  missing or unparsable.
  """
  @spec swap_bytes(Path.t()) ::
          {:ok, %{total: non_neg_integer(), free: non_neg_integer()}} | :error
  def swap_bytes(path \\ @meminfo_path) do
    with {:ok, contents} <- read_meminfo(path),
         {:ok, total} <- find_field(contents, "SwapTotal", 0),
         {:ok, free} <- find_field(contents, "SwapFree", 0) do
      {:ok, %{total: total, free: free}}
    else
      _unreadable -> :error
    end
  end

  # `MemTotal:` is conventionally the first line, but nothing guarantees any
  # field's position, so scan. A line that matches the key but not the value
  # shape falls through to the remaining lines and ultimately to `:error`
  # rather than aborting the scan.
  defp find_field(contents, key, min) do
    contents
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        [^key, value] -> parse_value(value, min)
        _other -> nil
      end
    end)
  end

  # The kernel always emits kB here; the unit-less form is accepted only
  # because the field is documented as "value [unit]" and costs nothing to
  # tolerate. Anything else (MB, a missing number, a negative) is a shape we
  # don't understand, and guessing at it is worse than reporting `:error`.
  defp parse_value(value, min) do
    case value |> String.trim() |> String.split(" ", trim: true) do
      [number, "kB"] -> to_bytes(number, 1024, min)
      [number] -> to_bytes(number, 1, min)
      _other -> nil
    end
  end

  # `min` is 1 for `MemTotal`, where a zero can only mean we misread the
  # file, and 0 for the swap and availability fields, where zero is the
  # honest answer on every board that has no swap configured yet.
  defp to_bytes(number, multiplier, min) do
    case Integer.parse(number) do
      {bytes, ""} when bytes >= min -> {:ok, bytes * multiplier}
      _other -> nil
    end
  end

  # path is internal/config-derived (a compile-time constant in production),
  # not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_meminfo(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> :error
    end
  end
end
