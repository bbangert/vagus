defmodule Vagus.Discovery.Push do
  @moduledoc """
  Pushes a discovery add/remove to Core
  (`POST|DELETE api/hassio_push/discovery/{uuid}`) so Core live-reconfigures a
  config flow immediately, instead of only picking the change up on its next
  boot-time `GET /discovery` pull (§A3.2).

  Core acts on pushes in arrival order, so every push is one entry in this
  process's FIFO and they are delivered one at a time: a DELETE queued after a
  POST for the same uuid never overtakes it. `notify/2` returns once the push
  is queued and `Vagus.App.Server` calls it before it replies, so whatever its
  caller does next queues behind, even from another process. Delivery runs in
  a task, so a slow Core holds up the queue but never `notify/2`.

  A push identical to the last one pending for its uuid adds nothing Core does
  not already get, so it is dropped. Past `max_pending` (one app re-posting
  faster than Core answers) the oldest pending POSTs are shed, with one
  warning until the queue next empties: Core's boot-time pull still has them.
  A DELETE is never shed, since nothing else tells Core a flow is gone.

  Until the Core handshake has happened, `Vagus.Core.Client.request/3` returns
  `{:error, :no_refresh_token}`; that is the expected case when a publisher
  registers before Core is up (the native broker boots ahead of Core), and
  Core's boot-time pull then covers it, so it is logged only at debug. Other
  errors are logged as warnings.
  """

  use GenServer

  require Logger

  @type message :: %{
          required(:uuid) => String.t(),
          required(:addon) => String.t(),
          required(:service) => String.t(),
          optional(any()) => any()
        }

  @max_pending 1_000
  @enqueue_timeout 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Queues the push. `:discovery_push` names a function the queue calls instead
  of Core, the seam tests use to see each push in order.
  """
  @spec notify(:post | :delete, message()) :: :ok | {:error, :unavailable}
  def notify(method, %{uuid: uuid, addon: _, service: _} = message) do
    # The config can hold a password and Core is never sent it.
    message = Map.take(message, [:uuid, :addon, :service])
    GenServer.call(__MODULE__, {:push, method, message}, @enqueue_timeout)
  catch
    # The caller is an app process mid-reply; a missing queue costs only the push.
    :exit, reason ->
      Logger.warning(
        "Vagus.Discovery.Push: discovery #{method} for #{uuid} not queued: #{inspect(reason)}"
      )

      {:error, :unavailable}
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       queue: :queue.new(),
       len: 0,
       # uuid => {method of its last pending push, pending count}
       pending: %{},
       max_pending: Keyword.get(opts, :max_pending, @max_pending),
       shedding: false,
       in_flight: nil
     }}
  end

  @impl GenServer
  def handle_call({:push, method, message}, _from, state) do
    {:reply, :ok, next(enqueue(state, method, message))}
  end

  @impl GenServer
  def handle_info({ref, _result}, %{in_flight: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, next(%{state | in_flight: nil})}
  end

  # A crashed push is lost like a failed one; the rest still go.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{in_flight: ref} = state),
    do: {:noreply, next(%{state | in_flight: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  # Only the uuid's LAST pending push may absorb it: behind a later push of the
  # other method, dropping it would leave Core the wrong final state.
  defp enqueue(state, method, %{uuid: uuid} = message) do
    case state.pending do
      %{^uuid => {^method, _count}} ->
        state

      _pending ->
        case make_room(state, method) do
          {:ok, state} -> append(state, method, message)
          :full -> state
        end
    end
  end

  defp make_room(%{len: len, max_pending: max} = state, _method) when len < max, do: {:ok, state}

  defp make_room(state, method) do
    state = warn_shedding(state)

    case Enum.split_while(:queue.to_list(state.queue), &(elem(&1, 0) != :post)) do
      {before, [{:post, %{uuid: uuid}} | rest]} ->
        entries = before ++ rest
        state = %{state | queue: :queue.from_list(entries), len: state.len - 1}
        {:ok, reindex(state, uuid, entries)}

      # Only DELETEs pending: a DELETE goes in over the cap, a POST is the one shed.
      {_deletes, []} ->
        if method == :delete, do: {:ok, state}, else: :full
    end
  end

  defp warn_shedding(%{shedding: true} = state), do: state

  defp warn_shedding(state) do
    Logger.warning(
      "Vagus.Discovery.Push: #{state.len} discovery pushes pending; " <>
        "shedding the oldest POSTs until the queue drains"
    )

    %{state | shedding: true}
  end

  defp reindex(state, uuid, entries) do
    case for({method, %{uuid: ^uuid}} <- entries, do: method) do
      [] -> %{state | pending: Map.delete(state.pending, uuid)}
      methods -> put_in(state.pending[uuid], {List.last(methods), length(methods)})
    end
  end

  defp append(state, method, %{uuid: uuid} = message) do
    count =
      case state.pending do
        %{^uuid => {_method, count}} -> count
        _pending -> 0
      end

    %{
      state
      | queue: :queue.in({method, message}, state.queue),
        len: state.len + 1,
        pending: Map.put(state.pending, uuid, {method, count + 1})
    }
  end

  defp next(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {method, message}}, queue} ->
        task = Task.Supervisor.async_nolink(Vagus.TaskSupervisor, fn -> run(method, message) end)
        %{dequeued(state, queue, message.uuid) | in_flight: task.ref}

      {:empty, _queue} ->
        state
    end
  end

  defp next(state), do: state

  defp dequeued(state, queue, uuid) do
    pending =
      case state.pending do
        %{^uuid => {_method, 1}} -> Map.delete(state.pending, uuid)
        %{^uuid => {method, count}} -> Map.put(state.pending, uuid, {method, count - 1})
      end

    len = state.len - 1
    %{state | queue: queue, len: len, pending: pending, shedding: state.shedding and len > 0}
  end

  defp run(method, message) do
    case Application.get_env(:vagus, :discovery_push) do
      nil -> deliver(method, message, &Vagus.Core.Client.request/3)
      seam -> seam.(method, message)
    end
  end

  @doc """
  One push, logged per outcome. Public only so tests can drive every branch
  with their own `request_fun`.

  An exception or an exit (a `GenServer.call` to an unstarted
  `Vagus.Core.Client` exits `:noproc`) is logged like any other failure
  instead of leaving only a task crash report.
  """
  @spec deliver(:post | :delete, message(), (atom(), String.t(), keyword() -> term())) :: :ok
  def deliver(method, %{uuid: uuid, addon: addon, service: service}, request_fun) do
    body = Jason.encode!(%{"addon" => addon, "service" => service, "uuid" => uuid})

    case request_fun.(method, "/api/hassio_push/discovery/#{uuid}",
           headers: [{"content-type", "application/json"}],
           body: body
         ) do
      {:ok, _response} ->
        :ok

      {:error, :no_refresh_token} ->
        Logger.debug("Vagus.Discovery.Push: discovery #{method} not pushed — Core not connected")

      {:error, reason} ->
        Logger.warning(
          "Vagus.Discovery.Push: discovery #{method} push for #{uuid} failed: #{inspect(reason)}"
        )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "Vagus.Discovery.Push: discovery #{method} push for #{uuid} crashed: " <>
          Exception.message(e)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "Vagus.Discovery.Push: discovery #{method} push for #{uuid} exited: #{inspect(reason)}"
      )

      :ok
  end
end
