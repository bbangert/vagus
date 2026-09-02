defmodule Vagus.Host.MemoryMonitor do
  @moduledoc """
  Samples memory pressure, swap use and `MemAvailable` into the log every
  five minutes.

  `Vagus.Host.Swap` had to pick a swappiness and a zram size from the
  kernel's own documentation and appliance convention, with no measurement
  of a Vagus board under a real Home Assistant workload to check them
  against. This is that measurement. RingLogger is the only place a board
  keeps any history at all, so the log line *is* the data set: it is written
  in one compact, greppable form
  (`Vagus.Diagnostics.ring_grep("Vagus.Host.MemoryMonitor")`).

  Sampling every minute and logging every fifth keeps the buffer usable —
  RingLogger holds a fixed number of entries, so a per-minute line would
  push a few hours of everything else out of a board's only crash record.
  Pressure crossing a threshold is logged when it happens rather than on the
  five-minute boundary, but at most once per ten minutes: a board that is
  genuinely thrashing would otherwise fill the buffer with the evidence of
  its own thrashing.

  Readers that fail are simply left out of the sample. PSI is absent on
  every board's kernel today, so that is the normal case and gets one debug
  line for the life of the process, not a warning a minute.

  Gated by `config :vagus, :memory_monitor` read at `start_link/1` time
  (`:ignore` otherwise), like `Vagus.Host.Swap`. The tick body is wrapped in
  a rescue/catch for the same reason: a bug in an observability process must
  never crash-loop a `:permanent` child and take Home Assistant down with
  it.
  """

  use GenServer

  require Logger

  @interval 60_000
  @log_every 5
  @warn_interval 600_000

  # `full` means every runnable task was stalled — 5 % of a minute spent
  # that way is already visible as latency. `some` counts a single stalled
  # task, which a busy board does routinely, so it needs a looser bound to
  # mean the same thing.
  @full_avg60_threshold 5.0
  @some_avg60_threshold 10.0

  @doc """
  Starts the sampler — `:ignore` (no process) unless
  `config :vagus, :memory_monitor` is truthy.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :memory_monitor, false) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @interval),
      warn_interval: Keyword.get(opts, :warn_interval, @warn_interval),
      pressure: Keyword.get(opts, :pressure, &Vagus.Platform.Pressure.memory/0),
      swap: Keyword.get(opts, :swap, &Vagus.Platform.Memory.swap_bytes/0),
      available: Keyword.get(opts, :available, &Vagus.Platform.Memory.available_bytes/0),
      now: Keyword.get(opts, :now, &monotonic_ms/0),
      ticks: 0,
      last_warn: nil,
      psi_absence_logged?: false
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = safe_sample(%{state | ticks: state.ticks + 1})
    schedule(state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("Vagus.Host.MemoryMonitor: ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  # `interval: :manual` (tests) or nil leaves ticks to the caller.
  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :tick, interval)
  end

  defp schedule(_state), do: :ok

  defp safe_sample(state) do
    sample(state)
  rescue
    exception ->
      Logger.error(
        "Vagus.Host.MemoryMonitor: sample failed (" <>
          Exception.format(:error, exception, __STACKTRACE__) <> ")"
      )

      state
  catch
    kind, reason ->
      Logger.error("Vagus.Host.MemoryMonitor: sample failed (caught #{kind}: #{inspect(reason)})")
      state
  end

  defp sample(state) do
    available = read(state.available)
    swap = read(state.swap)
    pressure = read(state.pressure)

    maybe_log(state, available, swap, pressure)

    state
    |> note_psi_absence(pressure)
    |> maybe_warn(pressure)
  end

  defp read(reader) do
    case reader.() do
      {:ok, value} -> value
      _unavailable -> nil
    end
  end

  defp maybe_log(%{ticks: ticks}, available, swap, pressure)
       when rem(ticks, @log_every) == 0 do
    case sample_line(available, swap, pressure) do
      "" -> :ok
      line -> Logger.info("Vagus.Host.MemoryMonitor: " <> line)
    end
  end

  defp maybe_log(_state, _available, _swap, _pressure), do: :ok

  defp sample_line(available, swap, pressure) do
    [available_part(available), swap_part(swap), psi_part(pressure)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp available_part(nil), do: nil
  defp available_part(bytes), do: "avail #{mib(bytes)} MiB"

  defp swap_part(nil), do: nil

  defp swap_part(%{total: total, free: free}),
    do: "swap #{mib(total - free)}/#{mib(total)} MiB"

  defp psi_part(nil), do: nil
  defp psi_part(%{some: some, full: full}), do: "psi some #{avgs(some)} full #{avgs(full)}"

  defp avgs(%{avg10: avg10, avg60: avg60, avg300: avg300}),
    do: "#{fixed(avg10)}/#{fixed(avg60)}/#{fixed(avg300)}"

  defp fixed(avg), do: :erlang.float_to_binary(avg, decimals: 2)

  defp mib(bytes), do: div(bytes, 1024 * 1024)

  defp note_psi_absence(%{psi_absence_logged?: false} = state, nil) do
    Logger.debug(
      "Vagus.Host.MemoryMonitor: no memory PSI — kernel without CONFIG_PSI, samples omit it"
    )

    %{state | psi_absence_logged?: true}
  end

  defp note_psi_absence(state, _pressure), do: state

  defp maybe_warn(state, nil), do: state

  defp maybe_warn(state, pressure) do
    if over_threshold?(pressure) and warn_due?(state) do
      Logger.warning("Vagus.Host.MemoryMonitor: memory pressure — " <> psi_part(pressure))
      %{state | last_warn: state.now.()}
    else
      state
    end
  end

  defp over_threshold?(%{some: %{avg60: some}, full: %{avg60: full}}),
    do: full >= @full_avg60_threshold or some >= @some_avg60_threshold

  defp warn_due?(%{last_warn: nil}), do: true
  defp warn_due?(state), do: state.now.() - state.last_warn >= state.warn_interval

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
