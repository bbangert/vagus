defmodule Vagus.Serial.Capture do
  @moduledoc """
  Continuous capture of target boards' serial consoles to `/data`, so a boot
  log can be read later without a worker holding the tty, and so it outlives
  the worker that asked for it.

  Each capture is one `Vagus.Serial.Capture.Worker` under this
  `DynamicSupervisor`, writing timestamped lines to
  `<root>/<label>.log` (root `/data/vagus/serial`, created on the first
  `start/2`) with one rotation to `<label>.log.1`.

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

  alias Vagus.Serial.Capture.Worker

  @default_root "/data/vagus/serial"

  @type entry :: %{
          label: String.t(),
          node: String.t(),
          baud: pos_integer(),
          file: Path.t(),
          bytes: non_neg_integer(),
          since: DateTime.t(),
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
    # concurrent `start/2`s.
    :ets.new(name, [:named_table, :public, :set])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts capturing `node` (`"ttyUSB0"` or `"/dev/ttyUSB0"`).

  Options: `:baud` (115_200), `:data_bits` (8), `:stop_bits` (1), `:parity`
  (`:none`), `:flow_control` (`:none`), `:name` (file label, default the
  node's basename), `:max_bytes` (8 MiB, per file), `:max_line` (4096),
  `:flush_ms` (500, how long a line without a newline waits before it is
  written as-is), `:root`, `:proc_root`, `:uart_mod`, `:supervisor`.

  `{:error, :busy}` means a capture already owns this node or label;
  `{:error, {:in_use, os_pids}}` means another host process has the node open.
  """
  @spec start(String.t(), keyword()) ::
          {:ok, pid()}
          | {:error, :busy | {:in_use, [pos_integer()]} | :invalid_node | :invalid_label | term()}
  def start(node_or_id, opts \\ []) do
    {sup, opts} = Keyword.pop(opts, :supervisor, __MODULE__)

    with {:ok, node} <- normalize_node(node_or_id),
         {:ok, label} <- validate_label(Keyword.get(opts, :name, Path.basename(node))) do
      opts =
        opts
        |> Keyword.merge(node: node, label: label, table: sup)
        |> Keyword.put_new(:root, root())

      DynamicSupervisor.start_child(sup, {Worker, opts})
    end
  end

  @spec stop(String.t(), GenServer.server()) :: :ok | {:error, :not_found}
  def stop(label_or_node, sup \\ __MODULE__) do
    case owner(sup, label_or_node) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(sup, pid)
    end
  end

  @spec status(GenServer.server()) :: [entry()]
  def status(sup \\ __MODULE__) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
        is_pid(pid),
        entry = Worker.info(pid),
        entry != nil,
        do: entry
  end

  @doc """
  The last `n` lines of `label`'s log, reaching into `.log.1` when the live
  file is shorter. Works after the capture has stopped.
  """
  @spec tail(String.t(), pos_integer(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def tail(label, n, opts \\ []) when is_integer(n) and n > 0 do
    with {:ok, label} <- validate_label(label) do
      base = Path.join(Keyword.get(opts, :root, root()), label <> ".log")
      current = read_lines(base)

      lines =
        if length(current) >= n, do: current, else: read_lines(base <> ".1") ++ current

      if lines == [] and not File.exists?(base),
        do: {:error, :enoent},
        else: {:ok, Enum.take(lines, -n)}
    end
  end

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
    node = if String.starts_with?(id, "/dev/"), do: id, else: "/dev/" <> id

    case validate_label(String.replace_prefix(node, "/dev/", "")) do
      {:ok, _} -> {:ok, node}
      _ -> {:error, :invalid_node}
    end
  end

  defp normalize_node(_), do: {:error, :invalid_node}

  defp owner(sup, key) do
    lookup = fn k ->
      case :ets.lookup(sup, k) do
        [{_, pid}] -> if Process.alive?(pid), do: pid
        [] -> nil
      end
    end

    lookup.({:label, key}) ||
      case normalize_node(key) do
        {:ok, node} -> lookup.({:node, node})
        _ -> nil
      end
  end

  # path is `root` + a label checked by validate_label/1, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_lines(path) do
    case File.read(path) do
      {:ok, data} -> String.split(data, "\n", trim: true)
      {:error, _} -> []
    end
  end
end
