defmodule Vagus.Platform.Memory do
  @moduledoc """
  Total physical RAM as reported by the kernel (`/proc/meminfo`).

  Exists so `Vagus.Addon.Store.AssetMode` can pick a store-asset retention
  strategy at boot: a board with less than 1 GiB keeps repository assets on
  disk instead of in memory. Nothing else consumes this yet.

  Read-per-call and uncached, mirroring `Vagus.Backend.OS.Nerves`'s
  `/proc/mounts` read — there is no caching concern because the only caller
  asks exactly once, in `Vagus.Addon.Store.init/1`.

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
  # path is internal/config-derived (a compile-time constant in production),
  # not request input
  # sobelow_skip ["Traversal.FileModule"]
  def total_bytes(path \\ @meminfo_path) do
    case File.read(path) do
      {:ok, contents} -> parse_mem_total(contents)
      {:error, _reason} -> :error
    end
  end

  # `MemTotal:` is conventionally the first line, but nothing guarantees it,
  # so scan. A line that matches the key but not the value shape falls
  # through to the remaining lines and ultimately to `:error` rather than
  # aborting the scan.
  defp parse_mem_total(contents) do
    contents
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        ["MemTotal", value] -> parse_value(value)
        _other -> nil
      end
    end)
  end

  # The kernel always emits kB here; the unit-less form is accepted only
  # because the field is documented as "value [unit]" and costs nothing to
  # tolerate. Anything else (MB, a missing number, a negative) is a shape we
  # don't understand, and guessing at it is worse than reporting `:error`.
  defp parse_value(value) do
    case value |> String.trim() |> String.split(" ", trim: true) do
      [number, "kB"] -> to_bytes(number, 1024)
      [number] -> to_bytes(number, 1)
      _other -> nil
    end
  end

  defp to_bytes(number, multiplier) do
    case Integer.parse(number) do
      {bytes, ""} when bytes > 0 -> {:ok, bytes * multiplier}
      _other -> nil
    end
  end
end
