defmodule Vagus.Platform.Pressure do
  @moduledoc """
  Memory pressure stall information (`/proc/pressure/memory`).

  PSI is the only reading that says whether the board is *hurting* for
  memory rather than merely using it: `MemAvailable` and the swap counters
  can look healthy while every task spends its time waiting on reclaim.
  `Vagus.Host.MemoryMonitor` samples this to judge whether the swappiness
  and zram-size choices `Vagus.Host.Swap` makes hold up under a real Home
  Assistant workload.

  No board runs a kernel with `CONFIG_PSI` today, so the file is normally
  absent and `:error` is the expected answer, not a fault. It starts
  returning data with the memory-tuning system release.

  Never raises, for the same reason as `Vagus.Platform.Memory`: an absent,
  truncated or unrecognised file is `:error` and the caller decides what
  that means.
  """

  @path "/proc/pressure/memory"

  @typedoc """
  `avg*` are the percentage of the last 10/60/300 s in which tasks stalled;
  `total` is the absolute stall time in microseconds since boot, which is
  the only field that survives a sampling gap.
  """
  @type stalls :: %{
          avg10: float(),
          avg60: float(),
          avg300: float(),
          total: non_neg_integer()
        }

  @typedoc """
  `some` counts time where at least one task stalled, `full` time where
  every runnable task did — `full` is the one that means throughput is
  already gone, so it warns at a much lower value.
  """
  @type t :: %{some: stalls(), full: stalls()}

  @doc """
  Memory pressure, or `:error` when the file can't be read or doesn't carry
  both a `some` and a `full` line.

  `path` is for tests; production always uses `#{@path}`.
  """
  @spec memory(Path.t()) :: {:ok, t()} | :error
  # path is internal/config-derived (a compile-time constant in production),
  # not request input
  # sobelow_skip ["Traversal.FileModule"]
  def memory(path \\ @path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, _reason} -> :error
    end
  end

  # psi.rst documents both lines for the memory and io resources (cpu is the
  # one that may carry only `some`), so a file with just one of them is
  # truncated rather than a variant worth guessing at.
  defp parse(contents) do
    case contents |> String.split("\n", trim: true) |> Enum.reduce(%{}, &collect/2) do
      %{some: some, full: full} -> {:ok, %{some: some, full: full}}
      _incomplete -> :error
    end
  end

  # Collected by leading keyword rather than by position: nothing in the
  # kernel documents the line order, only the emitted example shows it.
  defp collect(line, acc) do
    case String.split(line) do
      ["some" | fields] -> put_stalls(acc, :some, fields)
      ["full" | fields] -> put_stalls(acc, :full, fields)
      _other -> acc
    end
  end

  defp put_stalls(acc, kind, fields) do
    case stalls(fields) do
      {:ok, stalls} -> Map.put(acc, kind, stalls)
      :error -> acc
    end
  end

  defp stalls(fields) do
    values =
      Map.new(fields, fn field ->
        case String.split(field, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    with {:ok, avg10} <- avg(values, "avg10"),
         {:ok, avg60} <- avg(values, "avg60"),
         {:ok, avg300} <- avg(values, "avg300"),
         {:ok, total} <- total(values) do
      {:ok, %{avg10: avg10, avg60: avg60, avg300: avg300, total: total}}
    end
  end

  # The kernel prints two decimals; `Float.parse/1` also accepts a bare
  # integer, which is still a percentage. Trailing characters are not — a
  # field we only half understand is worse than no reading.
  defp avg(values, key) do
    case Float.parse(Map.get(values, key, "")) do
      {avg, ""} when avg >= 0.0 -> {:ok, avg}
      _other -> :error
    end
  end

  defp total(values) do
    case Integer.parse(Map.get(values, "total", "")) do
      {total, ""} when total >= 0 -> {:ok, total}
      _other -> :error
    end
  end
end
