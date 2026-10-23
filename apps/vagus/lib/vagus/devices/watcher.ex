defmodule Vagus.Devices.Watcher do
  @moduledoc """
  Plug and unplug of USB devices as `Vagus.Devices` sees them, sent to
  subscribers as `{:device, :added, device}` and `{:device, :removed, id}`.

  The source is `NervesUEvent`'s `PropertyTable`, which mirrors every kernel
  uevent under `/sys/devices`. One plug is a burst there — the device, each
  interface, then each node its drivers create once `modprobe` has loaded
  them — so a device is announced once, after `:settle_ms` (default 1 s) with
  no further event under its path, from a fresh sysfs read. Announcing on the
  device's own uevent would report it before its tty exists, which is the
  one thing a caller wants from it. A node created after the settle shows up
  in `Vagus.Devices.list/1` but is not announced again.

  Removal is announced on the device's own uevent (its interfaces and nodes
  go first) by id alone: its sysfs is already gone. Only devices this process
  announced or saw at start are announced as removed, so a hub or a device
  unplugged before it settled produces nothing.

  ## Losing the table

  The table's subscriptions live in its registry's partition, which links
  every subscriber. That partition can restart on its own (the table's
  supervisor keeps running) or with the whole table; either way the
  subscription is gone. Both the partition's exit and the table's `:DOWN`
  re-subscribe with `Vagus.Resubscribe`, and the inventory is re-read then,
  announcing whatever changed while nobody was listening. Re-subscribing
  twice would register twice and deliver every uevent twice, so a retry
  that finds a live subscription does nothing.

  ## Subscribers

  Subscribers are held in this process only: they do not survive its
  restart. A subscriber that must keep hearing monitors the watcher and
  subscribes again (`Vagus.Resubscribe` against the registered name does
  that, `{Vagus.Devices.Watcher, node}` included). Devices that settle while
  the watcher is away are part of its successor's starting inventory and
  are never announced `:added`.

  The starting inventory is read in `init/1` rather than a `handle_continue`:
  it has to sit between the subscribe and the first uevent handled, and it is
  a few dozen sysfs reads.

  `:ignore` when the table is not running: on host and in tests, and on a
  system built without nerves_uevent.
  """

  use GenServer

  alias Vagus.{Devices, Resubscribe}

  @settle_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the calling process. Works across nodes:
  `subscribe({Vagus.Devices.Watcher, node})`. A subscriber that exits is
  dropped.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, NervesUEvent)

    if Process.whereis(table) do
      state = %{
        table: table,
        devices_opts: Keyword.take(opts, [:sysfs_root, :dev_root]),
        settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
        # Test seam: lets a test decide when a settle fires.
        send_after: Keyword.get(opts, :send_after, &Process.send_after/3),
        table_ref: nil,
        known: %{},
        pending: %{},
        subscribers: %{}
      }

      # The table's registry links every subscriber, so its restart would
      # take this process down with it — and the restart here would find no
      # table yet and `:ignore` for good.
      Process.flag(:trap_exit, true)

      # Subscribe before reading, so a plug between the two is a uevent we
      # get rather than a device we never hear about.
      ref = Resubscribe.start(table, &subscribe_table/1, :resubscribe, true)
      {:ok, %{state | table_ref: ref, known: inventory(state)}}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    subs =
      if Map.has_key?(state.subscribers, pid),
        do: state.subscribers,
        else: Map.put(state.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {ref, subs} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subs}}
  end

  @impl GenServer
  def handle_info(%PropertyTable.Event{table: table} = event, %{table: table} = state),
    do: {:noreply, uevent(event, state)}

  def handle_info({:settled, path, token}, state) do
    case Map.get(state.pending, path) do
      {_timer, ^token} ->
        {:noreply, settle(path, %{state | pending: Map.delete(state.pending, path)})}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{table_ref: ref} = state) do
    {:noreply, %{state | table_ref: Resubscribe.down(state.table, :resubscribe)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  # The registry partition is this process's only link (parent exits never
  # reach handle_info), and the subscription died with it. A nil table_ref
  # means a retry is already armed.
  def handle_info({:EXIT, _partition, _reason}, %{table_ref: nil} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, _partition, _reason}, state) do
    Process.demonitor(state.table_ref, [:flush])
    {:noreply, %{state | table_ref: Resubscribe.down(state.table, :resubscribe)}}
  end

  def handle_info(:resubscribe, %{table_ref: ref} = state) when ref != nil,
    do: {:noreply, state}

  def handle_info(:resubscribe, state) do
    case Resubscribe.retry(state.table, &subscribe_table/1, :resubscribe) do
      nil -> {:noreply, state}
      ref -> {:noreply, resync(%{state | table_ref: ref})}
    end
  end

  # The table's name is registered before its registry starts and while it
  # restarts, and a missing registry raises; it is the table being away, so
  # it goes the way of a dead name (an exit Resubscribe retries).
  defp subscribe_table(table) do
    PropertyTable.subscribe(table, ["devices"])
  rescue
    ArgumentError -> exit(:no_registry)
  end

  # A device's own uevent starts (or ends) its story; every other uevent
  # only matters as a sign that a pending device's drivers are still
  # creating things beneath it.
  defp uevent(%{property: path} = event, state) do
    name = List.last(path)

    cond do
      usb_device?(event.value) and is_nil(event.previous_value) and Devices.usb_id(name) ->
        arm(path, state)

      is_nil(event.value) and usb_device?(event.previous_value) ->
        removed(path, Devices.usb_id(name), state)

      true ->
        rearm_ancestor(path, state)
    end
  end

  defp usb_device?(%{"subsystem" => "usb", "devtype" => "usb_device"}), do: true
  defp usb_device?(_value), do: false

  defp arm(path, state) do
    {timer, _token} = Map.get(state.pending, path, {nil, nil})
    if timer, do: Process.cancel_timer(timer)
    token = make_ref()
    timer = state.send_after.(self(), {:settled, path, token}, state.settle_ms)
    %{state | pending: Map.put(state.pending, path, {timer, token})}
  end

  # Every pending ancestor, not just one: a hub plugged with a device behind
  # it has both pending, and the device's tty must hold back the device.
  defp rearm_ancestor(path, state) do
    for key <- Map.keys(state.pending), :lists.prefix(key, path), reduce: state do
      state -> arm(key, state)
    end
  end

  defp removed(path, id, state) do
    {pending, state} = pop_in(state.pending[path])
    if pending, do: pending |> elem(0) |> Process.cancel_timer()

    case Map.pop(state.known, id) do
      {nil, _known} ->
        state

      {_device, known} ->
        broadcast(state, {:device, :removed, id})
        %{state | known: known}
    end
  end

  # A device already known as this same plug (a table restart replays every
  # device's uevent) is not news.
  defp settle(path, state) do
    id = path |> List.last() |> Devices.usb_id()

    case Enum.find(Devices.list(state.devices_opts), &(&1.id == id)) do
      nil ->
        state

      device ->
        if not same_plug?(Map.get(state.known, id), device),
          do: broadcast(state, {:device, :added, device})

        %{state | known: Map.put(state.known, id, device)}
    end
  end

  defp same_plug?(nil, _device), do: false

  defp same_plug?(known, device),
    do:
      Map.take(known, [:sysfs, :busnum, :devnum]) == Map.take(device, [:sysfs, :busnum, :devnum])

  defp resync(state) do
    now = inventory(state)

    for {id, _device} <- state.known,
        not Map.has_key?(now, id),
        do: broadcast(state, {:device, :removed, id})

    for {id, device} <- now,
        not Map.has_key?(state.known, id),
        do: broadcast(state, {:device, :added, device})

    %{state | known: now}
  end

  defp inventory(state) do
    for %{kind: :usb} = device <- Devices.list(state.devices_opts),
        into: %{},
        do: {device.id, device}
  end

  defp broadcast(state, message) do
    for pid <- Map.keys(state.subscribers), do: send(pid, message)
    :ok
  end
end
