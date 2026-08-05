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
end
