defmodule Vagus.Runtime.Logs do
  @moduledoc """
  Turns an Engine-API container log stream into the plain `text/plain` body the
  Supervisor log routes serve (`docs/contract-2026.7-m4-addendum.md` §A5):
  one message per line, `\\n`-terminated, UTF-8.

  A no-TTY container's `/logs` body is Docker's multiplexed stream — 8-byte
  frame headers (`[stream_type, 0,0,0, size:32]`) before each payload;
  `demux/1` strips them and concatenates the payloads. A TTY container (or an
  already-plain body) has no framing, so a body that doesn't parse cleanly as
  frames is returned as-is. `format/2` demuxes and, with `no_colors: true`,
  strips ANSI SGR escapes.
  """

  @ansi_sgr ~r/\e\[[0-9;]*m/

  @doc "Demux + optional ANSI strip. `opts[:no_colors]` removes color escapes."
  @spec format(binary(), keyword()) :: binary()
  def format(body, opts \\ []) when is_binary(body) do
    text = demux(body)
    if Keyword.get(opts, :no_colors, false), do: strip_ansi(text), else: text
  end

  @doc "Strips Docker's 8-byte multiplex frame headers; returns the body unchanged if unframed."
  @spec demux(binary()) :: binary()
  def demux(body) when is_binary(body) do
    case demux(body, []) do
      {:ok, iodata} -> IO.iodata_to_binary(iodata)
      :not_framed -> body
    end
  end

  @doc "Removes ANSI SGR (color) escape sequences."
  @spec strip_ansi(binary()) :: binary()
  def strip_ansi(text) when is_binary(text), do: Regex.replace(@ansi_sgr, text, "")

  ## Internals

  # Parse frames strictly: a valid stream is a sequence of [type,0,0,0,size][payload].
  # Any deviation (bad stream byte, truncated payload) means it isn't framed.
  defp demux(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp demux(<<stream, 0, 0, 0, size::32, rest::binary>>, acc)
       when stream in 0..2 and byte_size(rest) >= size do
    payload = binary_part(rest, 0, size)
    tail = binary_part(rest, size, byte_size(rest) - size)
    demux(tail, [payload | acc])
  end

  defp demux(_other, []), do: :not_framed
  # Partial/garbage after some valid frames: keep what we demuxed rather than
  # discarding it (a truncated tail is better than dropping the whole buffer).
  defp demux(_other, acc), do: {:ok, Enum.reverse(acc)}
end
