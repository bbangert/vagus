defmodule Vagus.Addon.Backend.Native.Logs do
  @moduledoc """
  A bounded, in-memory log buffer for a native app, which has no container
  whose logs `GET /addons/<slug>/logs` could read.

  It attaches a `:telemetry` handler to the app's own events (`:events`),
  turns each into a line with `:format` (`nil` drops the event), and keeps
  the most recent `@max` lines for `tail/2` and the live half of
  `/logs/follow` (`subscribe/1`, `{:native_log, line}`). The handler runs in
  the emitting process and only `cast`s here, so it never blocks it.

  A child of its app's subtree, so it lives and dies with the app.
  """

  use GenServer

  @max 200

  @type format :: (:telemetry.event_name(), map(), map() -> String.t() | nil)

  @doc """
  Starts the buffer. `:name` (default `#{inspect(__MODULE__)}`) is the
  process and handler key; `:events` and `:format` are what it records.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The most recent `n` log lines, oldest first."
  @spec tail(GenServer.server(), pos_integer()) :: [String.t()]
  def tail(server, n \\ 100), do: GenServer.call(server, {:tail, n})

  @doc """
  Sends the caller `{:native_log, line}` per appended line; `tail/2` is the
  backfill. A dead subscriber is pruned on its `:DOWN`.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  # Telemetry callback (remote capture — runs in the emitting process).
  @doc false
  def handle_event(event, measurements, metadata, {server, format}) do
    case format.(event, measurements, metadata) do
      nil -> :ok
      line -> GenServer.cast(server, {:append, stamp(line)})
    end
  end

  @impl GenServer
  def init(opts) do
    # So a supervisor shutdown (the app being stopped) runs terminate/2
    # and detaches the telemetry handler, instead of leaving it attached to
    # a dead process until the next start happens to replace it.
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    handler_id = {__MODULE__, name}
    format = Keyword.get(opts, :format, fn _event, _measurements, _metadata -> nil end)
    # Detach first so a restart (where terminate/2 may not have run) can re-attach.
    _ = :telemetry.detach(handler_id)

    :ok =
      :telemetry.attach_many(
        handler_id,
        Keyword.get(opts, :events, []),
        &__MODULE__.handle_event/4,
        {self(), format}
      )

    {:ok, %{lines: [], handler_id: handler_id, subscribers: %{}}}
  end

  @impl GenServer
  # DELIBERATE asymmetry with the engine's follow path (which ack-gates its
  # reads): this fan-out has no backpressure, so a slow /logs/follow client
  # blocked in chunk/2 queues {:native_log, _} in the request process's
  # mailbox. Bounded in practice by the app's own event rate (a few
  # lines/sec at worst) and by dead-client teardown (chunk error / idle
  # window) — an ack protocol here would buy nothing measurable for the
  # complexity.
  def handle_cast({:append, line}, state) do
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, {:native_log, line}) end)
    {:noreply, %{state | lines: Enum.take([line | state.lines], @max)}}
  end

  @impl GenServer
  def handle_call({:tail, n}, _from, state) do
    {:reply, state.lines |> Enum.take(n) |> Enum.reverse(), state}
  end

  def handle_call({:subscribe, pid}, _from, %{subscribers: subs} = state) do
    subs =
      if Map.has_key?(subs, pid) do
        subs
      else
        Map.put(subs, pid, Process.monitor(pid))
      end

    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, %{subscribers: subs} = state) do
    case Map.pop(subs, pid) do
      {nil, ^subs} ->
        {:reply, :ok, state}

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: rest}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{subscribers: subs} = state) do
    case Map.fetch(subs, pid) do
      {:ok, ^ref} -> {:noreply, %{state | subscribers: Map.delete(subs, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = :telemetry.detach(state.handler_id)
    :ok
  end

  defp stamp(body),
    do: "[#{Time.utc_now() |> Time.truncate(:second) |> Time.to_string()}] #{body}"
end
