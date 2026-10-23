defmodule Vagus.Serial.Capture.Worker do
  @moduledoc """
  Owns one tty for `Vagus.Serial.Capture`: holds the `Circuits.UART` handle
  and the log file, and exits (never reconnects) when the port goes away.
  """

  use GenServer, restart: :temporary

  require Logger

  @default_max_bytes 8 * 1024 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def info(pid) do
    GenServer.call(pid, :info, 1_000)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.fetch!(opts, :table)
    node = Keyword.fetch!(opts, :node)
    label = Keyword.fetch!(opts, :label)

    with :ok <- claim(table, [{:node, node}, {:label, label}]),
         :ok <- not_in_use(node, Keyword.get(opts, :proc_root, "/proc")),
         {:ok, state} <- open_file(opts),
         {:ok, state} <- open_uart(state, opts) do
      {:ok, state}
    else
      {:error, reason} ->
        release(table, node, label)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = Map.take(state, [:label, :node, :baud, :file, :bytes, :since])
    {:reply, Map.put(info, :state, :capturing), state}
  end

  @impl true
  def handle_info({:circuits_uart, _node, {:error, reason}}, state) do
    Logger.warning("serial capture #{state.label}: #{state.node} closed (#{inspect(reason)})")
    {:stop, {:shutdown, {:port_closed, reason}}, state}
  end

  def handle_info({:circuits_uart, _node, {:partial, data}}, state),
    do: {:noreply, write_line(state, data)}

  def handle_info({:circuits_uart, _node, data}, state) when is_binary(data),
    do: {:noreply, write_line(state, data)}

  def handle_info({:EXIT, uart, reason}, %{uart: uart} = state),
    do: {:stop, {:shutdown, {:port_closed, reason}}, %{state | uart: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.uart do
      _ = safe(fn -> state.uart_mod.close(state.uart) end)
      _ = safe(fn -> GenServer.stop(state.uart, :normal, 1_000) end)
    end

    _ = File.close(state.io)
    release(state.table, state.node, state.label)
  end

  # A claim held by a dead pid is stale (the holder was killed before its
  # terminate/2 ran); the exact-object delete lets only one claimant win.
  defp claim(table, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      if claim_key(table, key), do: {:cont, :ok}, else: {:halt, {:error, :busy}}
    end)
    |> tap(fn
      :ok -> :ok
      _ -> Enum.each(keys, &:ets.delete_object(table, {&1, self()}))
    end)
  end

  defp claim_key(table, key) do
    :ets.insert_new(table, {key, self()}) or
      case :ets.lookup(table, key) do
        [{^key, pid}] when pid != self() ->
          not Process.alive?(pid) and :ets.delete_object(table, {key, pid}) and
            :ets.insert_new(table, {key, self()})

        _ ->
          false
      end
  end

  defp release(table, node, label) do
    :ets.delete_object(table, {{:node, node}, self()})
    :ets.delete_object(table, {{:label, label}, self()})
  end

  # Only a /proc fd scan can tell on Nerves (no udev, no lsof), and it is
  # TOCTOU: a process can open the node between this scan and our open.
  # Linux ttys have no mandatory exclusive open, so this is a courtesy check
  # against clobbering someone's interactive session, not a lock.
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

  # path is `root` (config/opts) + a label checked by
  # Vagus.Serial.Capture.validate_label/1, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp open_file(opts) do
    root = Keyword.fetch!(opts, :root)
    file = Path.join(root, Keyword.fetch!(opts, :label) <> ".log")

    with :ok <- File.mkdir_p(root),
         {:ok, io} <- File.open(file, [:append, :binary, :raw]) do
      bytes =
        case File.stat(file) do
          {:ok, %{size: size}} -> size
          _ -> 0
        end

      {:ok,
       %{
         table: Keyword.fetch!(opts, :table),
         node: Keyword.fetch!(opts, :node),
         label: Keyword.fetch!(opts, :label),
         baud: Keyword.get(opts, :baud, 115_200),
         file: file,
         io: io,
         bytes: bytes,
         max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
         since: DateTime.utc_now(),
         uart_mod: Keyword.get(opts, :uart_mod, Circuits.UART),
         uart: nil
       }}
    end
  end

  defp open_uart(state, opts) do
    uart_opts = [
      active: true,
      id: :name,
      speed: state.baud,
      data_bits: Keyword.get(opts, :data_bits, 8),
      stop_bits: Keyword.get(opts, :stop_bits, 1),
      parity: Keyword.get(opts, :parity, :none),
      flow_control: Keyword.get(opts, :flow_control, :none),
      framing:
        {Circuits.UART.Framing.Line,
         separator: "\n", max_length: Keyword.get(opts, :max_line, 4096)},
      rx_framing_timeout: Keyword.get(opts, :flush_ms, 500)
    ]

    with {:ok, uart} <- state.uart_mod.start_link(),
         state = %{state | uart: uart},
         :ok <- open_or_stop(state, uart_opts) do
      {:ok, state}
    end
  end

  defp open_or_stop(state, uart_opts) do
    case state.uart_mod.open(state.uart, state.node, uart_opts) do
      :ok ->
        :ok

      {:error, _} = error ->
        _ = safe(fn -> GenServer.stop(state.uart, :normal, 1_000) end)
        _ = File.close(state.io)
        error
    end
  end

  defp write_line(state, data) do
    ts = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    line = [ts, " ", String.trim_trailing(data, "\r"), "\n"]
    size = IO.iodata_length(line)
    state = maybe_rotate(state, size)

    case :file.write(state.io, line) do
      :ok ->
        %{state | bytes: state.bytes + size}

      {:error, reason} ->
        Logger.warning("serial capture #{state.label}: write failed (#{inspect(reason)})")
        state
    end
  end

  # path is the worker's own validated log file
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_rotate(%{bytes: bytes, max_bytes: max} = state, size)
       when bytes > 0 and bytes + size > max do
    _ = File.close(state.io)
    _ = File.rename(state.file, state.file <> ".1")
    {:ok, io} = File.open(state.file, [:write, :binary, :raw])
    %{state | io: io, bytes: 0}
  end

  defp maybe_rotate(state, _size), do: state

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end
end
