defmodule Vagus.Runtime.Engine.Podman.LogFollow do
  @moduledoc """
  One live log follow under podman: a poll of the container's k8s-file log,
  with no `podman logs -f` process to linger after its reader.

  The last `tail` lines go first, then whatever is appended, one chunk in
  flight at a time: nothing more is read until the owner acks. Each
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
  @read_bytes 65_536

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %{
      owner: owner,
      owner_ref: Process.monitor(owner),
      name: Keyword.fetch!(opts, :name),
      engine_opts: Keyword.get(opts, :engine_opts, []),
      tail: Keyword.get(opts, :tail, 100),
      timestamps: Keyword.get(opts, :timestamps, false),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      fd: nil,
      offset: 0,
      conmon: nil,
      # A record not yet ended by its newline, and whether the text sent so
      # far ends mid-line (after a `P` fragment).
      pending: "",
      mid_line?: false,
      awaiting_ack?: false
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    with {:ok, %{path: path, conmon_pid: conmon}} <-
           Podman.log_target(state.name, state.engine_opts),
         {:ok, fd} <- open(path) do
      state = %{state | fd: fd, conmon: conmon}
      {text, state} = read_all(state, [])
      state = schedule(state)

      case last_lines(text, state.tail) do
        "" -> {:noreply, state}
        backfill -> {:noreply, deliver(backfill, state)}
      end
    else
      _absent -> eof(state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:log_ack, state), do: {:noreply, %{state | awaiting_ack?: false}}

  def handle_info(:tick, %{awaiting_ack?: true} = state), do: {:noreply, schedule(state)}

  # Liveness is checked before the read, so the read after conmon's exit
  # still drains what it wrote last.
  def handle_info(:tick, state) do
    gone? = not alive?(state.conmon)

    case read(state) do
      {"", state} when gone? -> eof(state)
      {"", state} -> {:noreply, schedule(state)}
      {text, state} -> {:noreply, text |> deliver(state) |> schedule()}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The path comes from podman's inspect of a Vagus container.
  # sobelow_skip ["Traversal.FileModule"]
  defp open(path) when is_binary(path) and path != "", do: File.open(path, [:read, :binary, :raw])
  defp open(_no_path), do: {:error, :no_log}

  defp alive?(pid) when is_integer(pid) and pid > 0, do: File.exists?("/proc/#{pid}")
  defp alive?(_none), do: false

  defp read_all(state, acc) do
    case read(state) do
      {"", state} -> {IO.iodata_to_binary(Enum.reverse(acc)), state}
      {text, state} -> read_all(state, [text | acc])
    end
  end

  defp read(state) do
    case :file.pread(state.fd, state.offset, @read_bytes) do
      {:ok, data} ->
        {records, pending} = split(state.pending <> data)
        {text, mid_line?} = render(records, state.timestamps, state.mid_line?)

        {text,
         %{state | offset: state.offset + byte_size(data), pending: pending, mid_line?: mid_line?}}

      _eof ->
        {"", state}
    end
  end

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
    cond do
      String.ends_with?(ts, "+00:00") ->
        String.replace_suffix(ts, "+00:00", "Z")

      match?({:ok, _, _}, DateTime.from_iso8601(ts)) ->
        {:ok, dt, _} = DateTime.from_iso8601(ts)
        DateTime.to_iso8601(dt)

      true ->
        ts
    end
  end

  defp last_lines(_text, tail) when is_integer(tail) and tail <= 0, do: ""

  defp last_lines(text, tail) when is_integer(tail) do
    text |> String.split(~r/(?<=\n)/, trim: true) |> Enum.take(-tail) |> Enum.join()
  end

  defp last_lines(text, _all), do: text

  defp deliver(text, state) do
    send(state.owner, {:log_chunk, text})
    %{state | awaiting_ack?: true}
  end

  defp schedule(state) do
    Process.send_after(self(), :tick, state.poll_ms)
    state
  end

  defp eof(state) do
    send(state.owner, :log_eof)
    {:stop, :normal, state}
  end
end
