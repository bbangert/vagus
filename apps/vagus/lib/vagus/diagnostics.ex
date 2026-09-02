defmodule Vagus.Diagnostics do
  @moduledoc """
  Small diagnostic helpers for gate procedures run over SSH.

  This exists because of issue #2, a false alarm: an operator searched the
  `RingLogger` buffer for a process's log lines using a hand-rolled filter
  written against a `{level, {_, msg, _, _}}` tuple shape. `RingLogger.get/2`
  (this project's `ring_logger` version) actually returns a list of MAPS —
  `%{level:, module:, message:, timestamp:, metadata:}` — so the tuple filter
  fell through its `_ -> false` clause for every entry and silently returned
  `[]`, which looked exactly like "this process's logs never reach
  RingLogger". `RingLogger.grep/2` can't be used to catch this kind of bug
  over an SSH exec eval either — it only prints matches to the console and
  returns `:ok`, never the matched data.

  `ring_grep/2` is a correct, data-returning replacement for both: it matches
  against the real map shape and hands back the matching strings.
  """

  @meminfo_path "/proc/meminfo"
  @pressure_path "/proc/pressure/memory"
  @thp_path "/sys/kernel/mm/transparent_hugepage/enabled"
  @lru_gen_path "/sys/kernel/mm/lru_gen/enabled"
  @swaps_path "/proc/swaps"

  @doc """
  Returns messages from the `RingLogger` buffer whose text matches `pattern`.

  `pattern` is checked against each entry's `:message` (converted from
  chardata to a string first) via `=~`, so a `String.t()` matches as a
  substring and a `Regex.t()` matches as a regex.

  `opts`:

    * `:limit` - number of entries to read from the buffer, passed through
      to `RingLogger.get(0, limit)`. Defaults to `0`, which per
      `RingLogger.get/2` means "read to the end" (i.e. everything).

  Entries that aren't in the expected map shape are skipped rather than
  raised on. If `RingLogger` isn't running/loaded, or `RingLogger.get/2`
  raises for any other reason, this returns `[]` — good enough for a
  diagnostic helper, where "no data" beats crashing the caller's shell.
  """
  @spec ring_grep(String.t() | Regex.t(), keyword()) :: [String.t()]
  def ring_grep(pattern, opts \\ []) do
    limit = Keyword.get(opts, :limit, 0)

    for %{level: level, message: message} <- RingLogger.get(0, limit),
        msg_string = IO.chardata_to_string(message),
        msg_string =~ pattern do
      "[#{level}] #{msg_string}"
    end
  rescue
    _ -> []
  end

  @doc """
  Everything about the board's memory state in one map, for
  `ssh <board> 'Vagus.Diagnostics.memory()'` during a gate run.

  Any field whose source can't be read or parsed is `:unavailable` rather
  than an error or a raise — a partial answer over SSH is worth more than a
  stack trace, and two of these fields are legitimately absent today:

    * `:thp` — stock Nerves kernels (the rpi targets, x86_64) are built
      without transparent huge pages, so the sysfs file simply does not
      exist there.
    * `:pressure` — no board's kernel has `CONFIG_PSI` yet; it starts
      reporting with the memory-tuning system release.

  `opts` are path seams for tests (`:meminfo`, `:pressure`, `:thp_enabled`,
  `:lru_gen_enabled`, `:swaps`).
  """
  @spec memory(keyword()) :: %{
          mem_total_bytes: non_neg_integer() | :unavailable,
          mem_available_bytes: non_neg_integer() | :unavailable,
          swap: %{total: non_neg_integer(), free: non_neg_integer()} | :unavailable,
          pressure: Vagus.Platform.Pressure.t() | :unavailable,
          thp: String.t() | :unavailable,
          lru_gen: String.t() | :unavailable,
          swaps: [String.t()] | :unavailable
        }
  def memory(opts \\ []) do
    meminfo = Keyword.get(opts, :meminfo, @meminfo_path)

    %{
      mem_total_bytes: available(Vagus.Platform.Memory.total_bytes(meminfo)),
      mem_available_bytes: available(Vagus.Platform.Memory.available_bytes(meminfo)),
      swap: available(Vagus.Platform.Memory.swap_bytes(meminfo)),
      pressure:
        available(Vagus.Platform.Pressure.memory(Keyword.get(opts, :pressure, @pressure_path))),
      thp: selection(Keyword.get(opts, :thp_enabled, @thp_path)),
      lru_gen: trimmed(Keyword.get(opts, :lru_gen_enabled, @lru_gen_path)),
      swaps: swaps(Keyword.get(opts, :swaps, @swaps_path))
    }
  end

  defp available({:ok, value}), do: value
  defp available(:error), do: :unavailable

  # sysfs "choice" files print every option with the active one bracketed
  # (`always [madvise] never`), and only the choice is interesting here.
  defp selection(path) do
    with {:ok, contents} <- read(path) do
      contents
      |> String.split()
      |> Enum.find_value(:unavailable, fn token ->
        case Regex.run(~r/^\[(.+)\]$/, token) do
          [_token, choice] -> choice
          nil -> nil
        end
      end)
    end
  end

  # `lru_gen/enabled` is a bitmask (`0x0007`) whose meaning is version
  # dependent, so it is reported verbatim rather than decoded here.
  defp trimmed(path) do
    case read(path) do
      {:ok, contents} -> blank_to_unavailable(String.trim(contents))
      :unavailable -> :unavailable
    end
  end

  defp blank_to_unavailable(""), do: :unavailable
  defp blank_to_unavailable(trimmed), do: trimmed

  # Entries are absolute paths, so filtering on the leading slash drops the
  # `Filename Type Size Used Priority` header without depending on it being
  # exactly one line (same read as `Vagus.Host.Swap`'s active-swap check).
  defp swaps(path) do
    with {:ok, contents} <- read(path) do
      contents
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "/"))
      |> Enum.map(&(&1 |> String.split() |> hd()))
    end
  end

  # paths are module attributes or test seams, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, _reason} -> :unavailable
    end
  end
end
