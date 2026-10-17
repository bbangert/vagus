defmodule Vagus.Runtime.Logs do
  @moduledoc """
  Shapes engine container log text into the `text/plain` bodies the
  Supervisor log routes serve (`docs/contract-2026.7-m4-addendum.md` §A5):
  one message per line, `\\n`-terminated, UTF-8. The engine has already
  stripped any framing.
  """

  @ansi_sgr ~r/\e\[[0-9;]*m/

  # Caps a carried partial line so an adversarial `--follow` stream (one
  # endless line) can't balloon memory on a 1GB device.
  @max_pending 1_048_576

  @doc "Removes ANSI SGR (color) escape sequences."
  @spec strip_ansi(binary()) :: binary()
  def strip_ansi(text) when is_binary(text), do: Regex.replace(@ansi_sgr, text, "")

  @doc "The cap on the router's verbose partial-line buffer."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @doc """
  Formats one `timestamps: true` log line into the §A5 verbose shape
  `YYYY-MM-DD HH:MM:SS.mmm <host> <identifier>: <message>` — best-effort
  (container logs carry no journald identifier or pid: the container/service
  name stands in as the identifier and the pid is omitted, documented as an
  honest approximation). A line without a parseable leading RFC3339 stamp
  passes through with just the `host identifier:` prefix.
  """
  @spec verbose_line(String.t(), String.t(), String.t()) :: String.t()
  def verbose_line(line, host, ident) do
    with [ts, msg] <- String.split(line, " ", parts: 2),
         {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
      {us, _precision} = dt.microsecond
      ms = us |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")
      stamp = Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      "#{stamp}.#{ms} #{host} #{ident}: #{msg}"
    else
      _ -> "#{host} #{ident}: #{line}"
    end
  end
end
