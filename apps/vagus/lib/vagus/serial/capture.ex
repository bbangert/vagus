defmodule Vagus.Serial.Capture do
  @moduledoc """
  Continuous capture of target boards' serial consoles to `/data`, so a boot
  log can be read later without a worker holding the tty, and so it outlives
  the worker that asked for it.

  Each capture is one `Vagus.Serial.Capture.Worker` under this
  `DynamicSupervisor`, writing timestamped lines to
  `<root>/<label>.log` (root `/data/vagus/serial`, created `0700` on the
  first `start/2`, files `0600`: a console log carries whatever the board
  printed, autologin passwords and Wi-Fi keys included) with one rotation to
  `<label>.log.1`.

  The label defaults to the stable id of the USB device that owns the node
  (`usb:1-1.2` is `usb-1-1.2.log`), so a re-plug that renumbers the tty keeps
  appending to the same board's file; a node no USB device owns (`ttyS0`)
  is labelled by its basename.

  Only `/dev/tty*` nodes are captured: opening anything else with a UART's
  open-configure-close can have side effects (a watchdog with no magic close
  reboots the board).

  The claim table lives and dies with this supervisor, so the API needs it
  registered under an atom (`:supervisor`), and answers `{:error, :absent}`
  while it is not running.

  Captures are read-only: there is deliberately no `write/2`. Typing into a
  board's console is an interactive act a worker does by opening the tty
  itself after `stop/1`, not something that should race the log.

  Captures are `restart: :temporary`. When the port goes away (an unplug),
  the worker exits `{:shutdown, {:port_closed, reason}}` and stays gone: a
  re-plugged adapter can enumerate under a different `/dev/ttyUSB*`, and
  re-opening the old node could silently capture a different board into this
  board's log. The orchestrator re-runs `start/2` against whatever node it
  finds.
  """

  use DynamicSupervisor

  alias Vagus.Devices
  alias Vagus.Serial.Capture.Worker

  @default_root "/data/vagus/serial"
  @max_bytes_cap 64 * 1024 * 1024
  @tail_chunk 64 * 1024

  @type entry :: %{
          label: String.t(),
          node: String.t(),
          baud: pos_integer(),
          file: Path.t(),
          bytes: non_neg_integer(),
          since: DateTime.t(),
          dropped: non_neg_integer(),
          state: :capturing
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, name, name: name)
  end

  @impl true
  def init(name) do
    # Owner claims live in a table the supervisor owns, so they outlive any
    # one worker. Child starts run serially inside this supervisor's
    # `start_child/2` call, which makes claim-then-open race-free between two
    # concurrent `start/2`s. No `:max_children`: every worker holds a claimed
    # tty, so there are never more than the board has ttys.
    :ets.new(name, [:named_table, :public, :set])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts capturing `node` (`"ttyUSB0"` or `"/dev/ttyUSB0"`).

  Options: `:baud` (115_200), `:data_bits` (8), `:stop_bits` (1), `:parity`
  (`:none`), `:flow_control` (`:none`), `:name` (file label, default the
  owning device's stable id, else the node's basename), `:max_bytes` (8 MiB
  per file, at most 64 MiB), `:max_line` (4096), `:flush_ms` (500, how long a
  line without a newline waits before it is written as-is), `:root`,
  `:proc_root`, `:sysfs_root`, `:dev_root`, `:uart_mod`, `:supervisor`.

  `{:error, :busy}` means a capture already owns this node or label;
  `{:error, {:in_use, os_pids}}` means another host process has the node open.
  """
  @spec start(String.t(), keyword()) ::
          {:ok, pid()}
          | {:error,
             :busy
             | {:in_use, [pos_integer()]}
             | :invalid_node
             | :invalid_label
             | :absent
             | term()}
  def start(node_or_id, opts \\ []) do
    {sup, opts} = Keyword.pop(opts, :supervisor, __MODULE__)

    with {:ok, node} <- normalize_node(node_or_id),
         {:ok, label} <-
           validate_label(Keyword.get_lazy(opts, :name, fn -> default_label(node, opts) end)),
         :ok <- unclaimed(sup, node, label),
         :ok <- not_in_use(node, Keyword.get(opts, :proc_root, "/proc")) do
      opts =
        opts
        |> Keyword.merge(node: node, label: label, table: sup)
        |> Keyword.put_new(:root, root())
        |> Keyword.replace_lazy(:max_bytes, &min(&1, @max_bytes_cap))

      start_child(sup, opts)
    end
  end

  defp start_child(sup, opts) do
    DynamicSupervisor.start_child(sup, {Worker, opts})
  catch
    :exit, {:noproc, _} -> {:error, :absent}
  end

  @spec stop(String.t(), GenServer.server()) :: :ok | {:error, :not_found | :absent}
  def stop(label_or_node, sup \\ __MODULE__) do
    case owner(sup, label_or_node) do
      :absent -> {:error, :absent}
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(sup, pid)
    end
  catch
    :exit, {:noproc, _} -> {:error, :absent}
  end

  @spec status(GenServer.server()) :: [entry()] | {:error, :absent}
  def status(sup \\ __MODULE__) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
        is_pid(pid),
        entry = Worker.info(pid),
        entry != nil,
        do: entry
  catch
    :exit, {:noproc, _} -> {:error, :absent}
  end

  @doc """
  The last `n` lines of `label`'s log, reaching into `.log.1` when the live
  file is shorter. Works after the capture has stopped. Reads backwards from
  the end, so the cost follows `n`, not the file size.
  """
  @spec tail(String.t(), pos_integer(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def tail(label, n, opts \\ []) when is_integer(n) and n > 0 do
    with {:ok, label} <- validate_label(label) do
      base = Path.join(Keyword.get(opts, :root, root()), label <> ".log")

      # The live file is briefly missing while it rotates; .1 then holds it all.
      case {last_lines(base, n), last_lines(base <> ".1", n)} do
        {{:error, _}, {:error, _}} -> {:error, :enoent}
        {current, rotated} -> {:ok, Enum.take(ok_lines(rotated) ++ ok_lines(current), -n)}
      end
    end
  end

  defp ok_lines({:ok, lines}), do: lines
  defp ok_lines({:error, _}), do: []

  @doc false
  def root, do: Application.get_env(:vagus, __MODULE__, [])[:root] || @default_root

  @doc false
  @spec validate_label(term()) :: {:ok, String.t()} | {:error, :invalid_label}
  def validate_label(label) when is_binary(label) and byte_size(label) in 1..64 do
    # No `/` is possible, so `.`/`..` are the only traversal spellings left.
    if label =~ ~r/\A[A-Za-z0-9_.-]+\z/ and label not in [".", ".."],
      do: {:ok, label},
      else: {:error, :invalid_label}
  end

  def validate_label(_), do: {:error, :invalid_label}

  defp normalize_node(id) when is_binary(id) do
    name = String.replace_prefix(id, "/dev/", "")

    if name =~ ~r/\Atty[A-Za-z0-9_]+\z/,
      do: {:ok, "/dev/" <> name},
      else: {:error, :invalid_node}
  end

  defp normalize_node(_), do: {:error, :invalid_node}

  defp default_label(node, opts) do
    case Devices.find(node, Keyword.take(opts, [:sysfs_root, :dev_root])) do
      {:ok, %{id: id}} -> String.replace(id, ":", "-")
      _ -> Path.basename(node)
    end
  end

  # Checked before the /proc scan, which would otherwise report our own
  # capture's UART port as a foreign holder. The worker's claim stays the
  # authoritative one.
  defp unclaimed(sup, node, label) do
    case {owner(sup, label), owner(sup, node)} do
      {:absent, _} -> {:error, :absent}
      {nil, nil} -> :ok
      _ -> {:error, :busy}
    end
  end

  # Only a /proc fd scan can tell on Nerves (no udev, no lsof), and it is
  # TOCTOU: a process can open the node between this scan and our open.
  # Circuits.UART takes a non-blocking flock on the node, so two flock-aware
  # openers already exclude each other; this is for the openers that do not
  # flock (picocom, screen, a shell redirect), a courtesy against clobbering
  # someone's interactive session, not a lock. It runs here rather than in
  # the worker's init/1, where it would hold up the supervisor's other starts.
  @doc false
  def holders(node, proc_root) do
    entries =
      case File.ls(proc_root) do
        {:ok, entries} -> entries
        {:error, _} -> []
      end

    for pid <- entries,
        pid =~ ~r/\A\d+\z/,
        fd_dir = Path.join([proc_root, pid, "fd"]),
        {:ok, fds} <- [File.ls(fd_dir)],
        Enum.any?(fds, &(File.read_link(Path.join(fd_dir, &1)) == {:ok, node})),
        do: String.to_integer(pid)
  end

  defp not_in_use(node, proc_root) do
    case holders(node, proc_root) do
      [] -> :ok
      pids -> {:error, {:in_use, Enum.sort(pids)}}
    end
  end

  defp owner(sup, key) do
    lookup(sup, {:label, key}) ||
      case normalize_node(key) do
        {:ok, node} -> lookup(sup, {:node, node})
        _ -> nil
      end
  end

  defp lookup(sup, key) do
    case :ets.lookup(sup, key) do
      [{_, pid}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  rescue
    # The table went with its supervisor.
    ArgumentError -> :absent
  end

  # path is `root` + a label checked by validate_label/1, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp last_lines(path, n) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        {:ok, size} = :file.position(io, :eof)
        {:ok, read_back(io, size, n, "", 0)}
      after
        File.close(io)
      end
    end
  end

  # n + 1 newlines in hand means the n lines after the (possibly cut) first
  # one are complete.
  defp read_back(io, pos, n, acc, newlines) when pos > 0 and newlines <= n do
    len = min(@tail_chunk, pos)

    case :file.pread(io, pos - len, len) do
      {:ok, chunk} ->
        count = length(:binary.matches(chunk, "\n"))
        read_back(io, pos - len, n, chunk <> acc, newlines + count)

      _eof_or_error ->
        read_back(io, 0, n, acc, newlines)
    end
  end

  defp read_back(_io, _pos, n, acc, _newlines),
    do: acc |> String.split("\n", trim: true) |> Enum.take(-n)
end
