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

  # Caps the carried partial-frame remainder so an adversarial/corrupt
  # `--follow` stream (a huge frame size, or unbounded unframed garbage that
  # looks like a header prefix) can't balloon memory on a 1GB device —
  # mirrors Vagus.Runtime.Events' pending-line cap.
  @max_pending 1_048_576

  @doc "The partial-buffer cap shared by demux_stream/2 and the router's verbose line buffer."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @doc """
  Incremental sibling of `demux/1` for a live `--follow` stream, where a
  frame routinely straddles chunk boundaries (so `demux/1`, which needs the
  complete buffer, cannot be called per-chunk).

  Consumes `pending <> data`: peels every complete 8-byte-framed record into
  the returned payload iodata and carries the straddling remainder (a
  partial header or a header whose payload hasn't fully arrived) as the new
  `pending`. Unframed/TTY data — anything that can no longer be a frame
  header — passes straight through as payload. Returns
  `{:error, :pending_overflow, salvaged}` when the carried remainder
  exceeds #{@max_pending} bytes — `salvaged` carries any complete frames
  peeled in the same call, so the caller can flush them before closing
  the stream.
  """
  @spec demux_stream(binary(), binary()) ::
          {iodata(), binary()} | {:error, :pending_overflow, iodata()}
  def demux_stream(pending, data) when is_binary(pending) and is_binary(data) do
    case do_demux_stream(pending <> data, []) do
      {payloads, rest} when byte_size(rest) > @max_pending ->
        {:error, :pending_overflow, payloads}

      ok ->
        ok
    end
  end

  defp do_demux_stream(<<stream, 0, 0, 0, size::32, rest::binary>> = buffer, acc)
       when stream in 0..2 do
    if byte_size(rest) >= size do
      payload = binary_part(rest, 0, size)
      tail = binary_part(rest, size, byte_size(rest) - size)
      do_demux_stream(tail, [payload | acc])
    else
      # Complete header, incomplete payload — hold the whole frame.
      {Enum.reverse(acc), buffer}
    end
  end

  defp do_demux_stream(buffer, acc) do
    cond do
      buffer == <<>> ->
        {Enum.reverse(acc), <<>>}

      # Fewer than 8 bytes that could still grow into a frame header — hold.
      header_prefix?(buffer) ->
        {Enum.reverse(acc), buffer}

      # Provably not a frame at this position: TTY/unframed passthrough
      # (same keep-the-data stance as demux/1's truncated-tail clause).
      true ->
        {Enum.reverse([buffer | acc]), <<>>}
    end
  end

  # True iff `buffer` (necessarily < 8 bytes) is a prefix of a possible
  # frame header: <<stream in 0..2, 0, 0, 0, size::32>>.
  defp header_prefix?(<<stream, rest::binary>>) when stream in 0..2 and byte_size(rest) < 7 do
    rest
    |> :binary.bin_to_list()
    |> Enum.take(3)
    |> Enum.all?(&(&1 == 0))
  end

  defp header_prefix?(_buffer), do: false

  @doc """
  Formats one docker `timestamps=true` log line into the §A5 verbose shape
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
