defmodule Vagus.Runtime.Engine.Podman.EventSource do
  @moduledoc """
  podman's events file as a `Vagus.Runtime.Events.Source`: no resident
  `podman events` process, just a poll of the file every podman process
  appends to (`events_logger = "file"`).

  `connect/1` starts at the file's end, so history is never replayed; the
  `:ready` it reports makes Events resync instead. Each tick reads from the
  saved offset.

  podman rotates by renaming a new file over the log: a `log-rotation`
  begin marker, the newer half of the old file, an end marker, then new
  events. The half was already read from the old file, and replaying it
  would restart running apps on stale `died` lines, so the old file is
  drained first and the new one is read from after its end marker. A
  replaced file without one is read from its end. Either way `:ready`
  follows, since a second rotation between two ticks can hide lines.

  A line is kept whole up to 1 MiB, the size at which podman rotates the
  whole file; a pending line past that is dropped.

  Every `resync_ms` it reports `:ready` again, so Events re-lists and
  repairs any line this source missed: unlike a socket, the file never
  closes, so no reconnect would ever resync.

  The lines carry the container's labels in `Attributes`, so `managed` is
  the `supervisor_managed` label, as on Docker. A health line is written
  on every check, not only on a change, so a consumer must act on
  transitions.

  Options (the Events process's `:engine_opts`): `:events_log` (default
  `config :vagus, :podman_events_log`, else podman's
  `/run/libpod/events/events.log`), `:events_poll_ms` (default 250, the
  interval of podman's own follower) and `:resync_ms` (default 60 s).
  """

  @behaviour Vagus.Runtime.Events.Source

  require Logger

  alias Vagus.Runtime.Engine.Event

  @default_path "/run/libpod/events/events.log"
  @poll_ms 250
  @resync_ms 60_000
  @max_line_bytes 1_048_576
  @read_bytes 262_144

  @impl true
  def init(opts) do
    %{
      path: opts[:events_log] || Application.get_env(:vagus, :podman_events_log, @default_path),
      poll_ms: Keyword.get(opts, :events_poll_ms, @poll_ms),
      resync_ms: Keyword.get(opts, :resync_ms, @resync_ms),
      resync_timer: nil,
      # Test-only: runs between the open and the descriptor's stat.
      open_hook: opts[:open_hook],
      fd: nil,
      inode: nil,
      offset: 0,
      buffer: "",
      ref: nil,
      timer: nil
    }
  end

  # A missing file is fine: podman creates it with its first event, all of
  # which is then new.
  @impl true
  def connect(src) do
    src = close(src)

    src =
      case open(src) do
        {:ok, fd, %File.Stat{inode: inode, size: size}} ->
          %{src | fd: fd, inode: inode, offset: size}

        :absent ->
          src
      end

    {:ok, [:answered, :ready], %{src | ref: make_ref()} |> arm() |> arm_resync()}
  end

  @impl true
  def handle_info({__MODULE__, :tick, ref}, %{ref: ref} = src) do
    {notices, src} = advance(src)
    {:ok, notices, arm(src)}
  end

  def handle_info({__MODULE__, :resync, ref}, %{ref: ref} = src),
    do: {:ok, [:ready], arm_resync(src)}

  def handle_info(_msg, _src), do: :unknown

  @impl true
  def close(src) do
    if src.timer, do: Process.cancel_timer(src.timer)
    if src.resync_timer, do: Process.cancel_timer(src.resync_timer)
    if src.fd, do: File.close(src.fd)

    %{
      src
      | fd: nil,
        inode: nil,
        offset: 0,
        buffer: "",
        ref: nil,
        timer: nil,
        resync_timer: nil
    }
  end

  defp arm(src),
    do: %{src | timer: Process.send_after(self(), {__MODULE__, :tick, src.ref}, src.poll_ms)}

  defp arm_resync(src) do
    timer = Process.send_after(self(), {__MODULE__, :resync, src.ref}, src.resync_ms)
    %{src | resync_timer: timer}
  end

  # The path is config or a test's temp file, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  # The inode and size come from the opened descriptor: a stat of the path
  # before the open could describe a file a rotation has since replaced.
  defp open(src) do
    case File.open(src.path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        if src.open_hook, do: src.open_hook.()
        fstat(fd)

      {:error, _} ->
        :absent
    end
  end

  defp fstat(fd) do
    case :file.read_file_info(fd, time: :posix) do
      {:ok, info} ->
        {:ok, fd, File.Stat.from_record(info)}

      {:error, _} ->
        File.close(fd)
        :absent
    end
  end

  defp advance(src) do
    case File.stat(src.path) do
      {:ok, %File.Stat{inode: inode, size: size}}
      when inode == src.inode and size >= src.offset ->
        read(src)

      # The file appeared after connect: all of it is new.
      {:ok, _stat} when src.inode == nil ->
        case open(src) do
          {:ok, fd, %File.Stat{inode: inode}} -> read(%{src | fd: fd, inode: inode, offset: 0})
          :absent -> {[], src}
        end

      {:ok, _replaced_or_truncated} ->
        rotated(src)

      {:error, _gone} ->
        {[], src}
    end
  end

  defp rotated(src) do
    {drained, src} = read(src)
    if src.fd, do: File.close(src.fd)
    src = %{src | fd: nil, inode: nil, offset: 0, buffer: ""}

    case open(src) do
      {:ok, fd, %File.Stat{inode: inode, size: size}} ->
        src = %{src | fd: fd, inode: inode, offset: after_rotation(fd, size)}
        {more, src} = read(src)
        {drained ++ [:ready | more], src}

      :absent ->
        {drained ++ [:ready], src}
    end
  end

  # The byte after the first rotation end marker, or the end of the file.
  defp after_rotation(fd, size) do
    with {:ok, data} <- :file.pread(fd, 0, size),
         {:ok, offset} <- end_marker(String.split(data, "\n"), 0) do
      offset
    else
      _ -> size
    end
  end

  defp end_marker([], _offset), do: :none
  defp end_marker([_partial], _offset), do: :none

  defp end_marker([line | rest], offset) do
    next = offset + byte_size(line) + 1

    if rotation_end?(line), do: {:ok, next}, else: end_marker(rest, next)
  end

  defp rotation_end?(line) do
    String.contains?(line, "log-rotation") and
      match?(
        {:ok, %{"Type" => "system", "Attributes" => %{"io.podman.event.rotate" => "end"}}},
        Jason.decode(line)
      )
  end

  defp read(%{fd: nil} = src), do: {[], src}
  defp read(src), do: read(src, [])

  defp read(src, notices) do
    case :file.pread(src.fd, src.offset, @read_bytes) do
      {:ok, data} ->
        {lines, rest} = split_lines(src.buffer <> data)
        events = for line <- lines, event = decode(line), do: event
        src = %{src | offset: src.offset + byte_size(data), buffer: cap(rest)}
        read(src, Enum.reverse(events, notices))

      _eof_or_error ->
        {Enum.reverse(notices), src}
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp cap(buffer) when byte_size(buffer) > @max_line_bytes do
    Logger.warning(
      "Vagus.Runtime.Engine.Podman.EventSource: a line passed #{@max_line_bytes} bytes; dropped"
    )

    ""
  end

  defp cap(buffer), do: buffer

  defp decode(""), do: nil

  # Image, network and volume lines are most of a pull's; skip their decode.
  defp decode(line) do
    if String.contains?(line, ~s("Type":"container")), do: decode_container(line)
  end

  defp decode_container(line) do
    case Jason.decode(line) do
      {:ok, %{"Type" => "container"} = event} ->
        normalize(event)

      {:ok, _other_type} ->
        nil

      {:error, _} ->
        Logger.debug("Vagus.Runtime.Engine.Podman.EventSource: malformed event line skipped")
        nil
    end
  end

  @doc false
  @spec normalize(map()) :: Event.t()
  def normalize(event) do
    {action, health} = action(event["Status"], event["health_status"])

    %Event{
      action: action,
      health: health,
      name: event["Name"],
      id: event["ID"],
      exit_code: if(action == :die, do: event["ContainerExitCode"]),
      time_ns: time_ns(event["Time"]),
      managed: Map.has_key?(event["Attributes"] || %{}, "supervisor_managed")
    }
  end

  defp action("start", _), do: {:start, nil}
  defp action("died", _), do: {:die, nil}
  defp action("create", _), do: {:create, nil}
  defp action("remove", _), do: {:destroy, nil}
  defp action("health_status", "healthy"), do: {:health, :healthy}
  defp action("health_status", "unhealthy"), do: {:health, :unhealthy}
  defp action("health_status", "starting"), do: {:health, :starting}
  defp action(_other, _health), do: {:other, nil}

  # DateTime keeps microseconds; podman writes nanoseconds.
  defp time_ns(time) when is_binary(time) do
    with [_, base, frac, offset] <-
           Regex.run(~r/^(.+T\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$/, time),
         {:ok, dt, _} <- DateTime.from_iso8601(base <> offset) do
      frac = frac |> String.pad_trailing(9, "0") |> binary_part(0, 9) |> String.to_integer()
      DateTime.to_unix(dt, :nanosecond) + frac
    else
      _ -> nil
    end
  end

  defp time_ns(_missing), do: nil
end
