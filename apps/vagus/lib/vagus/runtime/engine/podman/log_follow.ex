defmodule Vagus.Runtime.Engine.Podman.LogFollow do
  @moduledoc """
  One live log follow under podman: a poll of the container's k8s-file log,
  with no `podman logs -f` process to linger after its reader.

  The backfill starts `tail` lines before the end, found by scanning back
  from the end a block at a time, so a log of any size costs one block of
  memory. From there the file streams in chunks of at most 64 KiB, one in
  flight at a time: nothing more is read or sent until the owner acks. An
  unfinished record is held up to 1 MiB; past that its text goes out as it
  comes, so a runaway line cannot grow the buffer. Each
  k8s-file record (`<RFC3339> <stream> <F|P> <msg>`) becomes plain text; a
  `P` record is a fragment the next record continues. With `timestamps`,
  each line starts `<RFC3339 UTC> `, the form Docker's follow produced.

  The follow ends, after one last read, when conmon has exited: it holds
  the log open for exactly the container's life and has no other observable
  end that costs nothing to check. A container that is absent or not
  running gets its backfill and then `:log_eof`.
  """

  use GenServer, restart: :temporary

  alias Vagus.Runtime.Engine.Podman

  @poll_ms 250
  @block_bytes 65_536
  @max_pending 1_048_576

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %{
      owner: owner,
      owner_ref: Process.monitor(owner),
      name: Keyword.fetch!(opts, :name),
      engine_opts: Keyword.get(opts, :engine_opts, []),
      tail: opts |> Keyword.get(:tail, 100) |> max(0),
      timestamps: Keyword.get(opts, :timestamps, false),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      fd: nil,
      offset: 0,
      conmon: nil,
      timer: nil,
      tick: nil,
      # A record not yet ended by its newline; or, once it outgrew
      # @max_pending, the tag of the record whose text is still arriving.
      pending: "",
      continuing: nil,
      # Whether the text so far ends mid-line (after a `P` fragment).
      mid_line?: false,
      # Rendered text not yet sent.
      out: "",
      awaiting_ack?: false
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    with {:ok, %{path: path, conmon_pid: conmon}} <-
           Podman.log_target(state.name, state.engine_opts),
         {:ok, fd} <- open(path),
         {:ok, size} <- :file.position(fd, :eof) do
      state = %{state | fd: fd, conmon: conmon, offset: tail_start(fd, size, state.tail)}
      {:noreply, schedule(state, 0)}
    else
      _absent -> eof(state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:log_ack, state), do: {:noreply, schedule(%{state | awaiting_ack?: false}, 0)}

  # A tick from a timer since cancelled carries an older ref.
  def handle_info({:tick, ref}, %{tick: ref, awaiting_ack?: true} = state),
    do: {:noreply, %{state | timer: nil}}

  def handle_info({:tick, ref}, %{tick: ref, out: out} = state) when out != "",
    do: {:noreply, deliver(%{state | timer: nil})}

  # Liveness is checked before the read, so the read after conmon's exit
  # still drains what it wrote last.
  def handle_info({:tick, ref}, %{tick: ref} = state) do
    gone? = not alive?(state.conmon)
    state = %{state | timer: nil}

    case read(state) do
      {:eof, %{pending: ""} = state} when gone? -> eof(state)
      {:eof, state} when gone? -> {:noreply, deliver(cut_pending(state))}
      {:eof, state} -> {:noreply, schedule(state, state.poll_ms)}
      # Bytes were read but no line finished: read on.
      {:data, %{out: ""} = state} -> {:noreply, schedule(state, 0)}
      {:data, state} -> {:noreply, deliver(state)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The path comes from podman's inspect of a Vagus container.
  # sobelow_skip ["Traversal.FileModule"]
  defp open(path) when is_binary(path) and path != "", do: File.open(path, [:read, :binary, :raw])
  defp open(_no_path), do: {:error, :no_log}

  # A zombie has exited too. `pid` is an integer from podman's inspect.
  # sobelow_skip ["Traversal.FileModule"]
  defp alive?(pid) when is_integer(pid) and pid > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        state = stat |> String.split(") ", parts: 2) |> List.last()
        not String.starts_with?(state, "Z")

      {:error, _} ->
        false
    end
  end

  defp alive?(_none), do: false

  # Just after the (tail + 1)th line end back from the end, counting only
  # `F` records: a `P` record does not end a line. The scan holds one block
  # and a header at a time, never a record's body, however long it is.
  defp tail_start(_fd, size, 0), do: size

  defp tail_start(fd, size, tail), do: scan_back(fd, size, nil, tail + 1)

  # `next_end` is the newline ending the record that starts after the next
  # newline found: nil until the last newline, after which is only a record
  # still being written.
  defp scan_back(fd, 0, next_end, left), do: first_record(fd, next_end, left)

  defp scan_back(fd, pos, next_end, left) do
    from = max(pos - @block_bytes, 0)
    {:ok, block} = :file.pread(fd, from, pos - from)

    newlines =
      block |> :binary.matches("\n") |> Enum.map(fn {at, 1} -> from + at end) |> Enum.reverse()

    case count_back(fd, newlines, next_end, left) do
      {:found, start} -> start
      {next_end, left} -> scan_back(fd, from, next_end, left)
    end
  end

  defp count_back(_fd, [], next_end, left), do: {next_end, left}

  defp count_back(fd, [newline | rest], nil, left), do: count_back(fd, rest, newline, left)

  defp count_back(fd, [newline | rest], next_end, left) do
    case counted(fd, newline + 1, next_end, left) do
      {:found, _} = found -> found
      left -> count_back(fd, rest, newline, left)
    end
  end

  defp first_record(_fd, nil, _left), do: 0

  defp first_record(fd, next_end, left) do
    case counted(fd, 0, next_end, left) do
      {:found, start} -> start
      _left -> 0
    end
  end

  defp counted(fd, start, line_end, left) do
    cond do
      not line_end?(fd, start) -> left
      left == 1 -> {:found, line_end + 1}
      true -> left - 1
    end
  end

  @header_bytes 128

  defp line_end?(fd, start) do
    case :file.pread(fd, start, @header_bytes) do
      {:ok, head} -> head |> :binary.split("\n") |> hd() |> line_end?()
      _ -> false
    end
  end

  defp line_end?(record), do: match?([_ts, _stream, "F" | _], String.split(record, " ", parts: 4))

  defp read(state) do
    case :file.pread(state.fd, state.offset, @block_bytes) do
      {:ok, data} ->
        state = consume(data, %{state | offset: state.offset + byte_size(data)})
        {:data, state}

      _eof ->
        {:eof, state}
    end
  end

  # The rest of an oversized record: its text up to the newline.
  defp consume(data, %{continuing: tag} = state) when tag != nil do
    case :binary.split(data, "\n") do
      [text] ->
        emit(state, text)

      [text, rest] ->
        state = emit(state, [text, if(tag == "F", do: "\n", else: "")])
        consume(rest, %{state | continuing: nil, mid_line?: tag == "P"})
    end
  end

  defp consume(data, state) do
    {records, pending} = split(state.pending <> data)
    {text, mid_line?} = render(records, state.timestamps, state.mid_line?)
    state = emit(%{state | pending: pending, mid_line?: mid_line?}, text)

    if byte_size(pending) > @max_pending, do: cut_pending(state), else: state
  end

  # Sends the start of an unfinished record now and reads the rest of it
  # as plain text.
  defp cut_pending(%{pending: pending} = state) do
    case String.split(pending, " ", parts: 4) do
      [ts, _stream, tag, msg] when tag in ["F", "P"] ->
        stamp = if state.timestamps and not state.mid_line?, do: [utc(ts), " "], else: []
        emit(%{state | pending: "", continuing: tag, mid_line?: true}, [stamp, msg])

      _no_header ->
        emit(%{state | pending: "", continuing: "F", mid_line?: true}, pending)
    end
  end

  defp emit(state, text), do: %{state | out: IO.iodata_to_binary([state.out, text])}

  defp split(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp render(records, stamps?, mid_line?) do
    {parts, mid_line?} =
      Enum.reduce(records, {[], mid_line?}, fn record, {acc, mid?} ->
        case String.split(record, " ", parts: 4) do
          [ts, _stream, tag, msg] when tag in ["F", "P"] ->
            stamp = if stamps? and not mid?, do: [utc(ts), " "], else: []
            ending = if tag == "F", do: "\n", else: ""
            {[[stamp, msg, ending] | acc], tag == "P"}

          # An empty message is written without its trailing space.
          [ts, _stream, "F"] ->
            {[[if(stamps? and not mid?, do: [utc(ts), " "], else: []), "\n"] | acc], false}

          _not_a_record ->
            {acc, mid?}
        end
      end)

    {parts |> Enum.reverse() |> IO.iodata_to_binary(), mid_line?}
  end

  # conmon writes its local offset; the router's verbose path reads UTC.
  defp utc(ts) do
    with false <- String.ends_with?(ts, "+00:00"),
         {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
      DateTime.to_iso8601(dt)
    else
      true -> String.replace_suffix(ts, "+00:00", "Z")
      {:error, _} -> ts
    end
  end

  defp deliver(%{out: out} = state) do
    size = min(byte_size(out), @block_bytes)
    <<chunk::binary-size(^size), rest::binary>> = out
    send(state.owner, {:log_chunk, chunk})
    %{state | out: rest, awaiting_ack?: true}
  end

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    tick = make_ref()
    %{state | tick: tick, timer: Process.send_after(self(), {:tick, tick}, ms)}
  end

  defp eof(state) do
    send(state.owner, :log_eof)
    {:stop, :normal, state}
  end
end
