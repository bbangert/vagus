defmodule Vagus.Serial.Capture.Worker do
  @moduledoc """
  Owns one tty for `Vagus.Serial.Capture`: holds the `Circuits.UART` handle
  and the log file, and exits (never reconnects) when the port goes away.
  """

  use GenServer, restart: :temporary

  require Logger

  @default_max_bytes 8 * 1024 * 1024
  @warn_every_ms 60_000

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
    info = Map.take(state, [:label, :node, :baud, :file, :bytes, :since, :dropped])
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
  rescue
    # The table went with the supervisor; so did every claim in it.
    ArgumentError -> true
  end

  # path is `root` (config/opts) + a label checked by
  # Vagus.Serial.Capture.validate_label/1, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp open_file(opts) do
    root = Keyword.fetch!(opts, :root)
    file = Path.join(root, Keyword.fetch!(opts, :label) <> ".log")

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.touch(file),
         :ok <- File.chmod(file, 0o600),
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
         dropped: 0,
         warned_at: nil,
         rotate_failed: false,
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

    case state.uart_mod.start_link() do
      {:ok, uart} ->
        state = %{state | uart: uart}
        with :ok <- open_or_stop(state, uart_opts), do: {:ok, state}

      {:error, _} = error ->
        _ = File.close(state.io)
        error
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
      :ok -> %{state | bytes: state.bytes + size}
      {:error, reason} -> dropped(%{state | dropped: state.dropped + 1}, reason)
    end
  end

  # A failing /data is shared with the durable log, so a warning per dropped
  # line would feed the same disk: one now, then one a minute at most.
  defp dropped(state, reason) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.warned_at) or now - state.warned_at >= @warn_every_ms do
      Logger.warning(
        "serial capture #{state.label}: write failed (#{inspect(reason)}), " <>
          "#{state.dropped} line(s) dropped so far"
      )

      %{state | warned_at: now}
    else
      state
    end
  end

  # Renamed while still open, so a failed rename or reopen leaves the handle
  # writing on: a log that outgrows its cap beats a truncated one. The
  # warning comes once until a rotation succeeds.
  # path is the worker's own validated log file
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_rotate(%{bytes: bytes, max_bytes: max} = state, size)
       when bytes > 0 and bytes + size > max do
    rotated = state.file <> ".1"

    with :ok <- File.rename(state.file, rotated),
         {:ok, io} <- reopen(state.file, rotated) do
      _ = File.close(state.io)
      _ = File.chmod(state.file, 0o600)
      %{state | io: io, bytes: 0, rotate_failed: false}
    else
      {:error, reason} ->
        if not state.rotate_failed,
          do:
            Logger.warning("serial capture #{state.label}: rotation failed (#{inspect(reason)})")

        %{state | rotate_failed: true}
    end
  end

  defp maybe_rotate(state, _size), do: state

  # The handle still writes to the renamed file; renaming it back keeps the
  # name and the handle on one file, so the next rotation can try again.
  # path is the worker's own validated log file
  # sobelow_skip ["Traversal.FileModule"]
  defp reopen(file, rotated) do
    with {:error, _} = error <- File.open(file, [:write, :binary, :raw]) do
      _ = File.rename(rotated, file)
      error
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end
end
