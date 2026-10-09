defmodule Vagus.Discovery.Push do
  @moduledoc """
  Pushes a discovery add/remove to Core
  (`POST|DELETE api/hassio_push/discovery/{uuid}`) so Core live-reconfigures a
  config flow immediately, instead of only picking the change up on its next
  boot-time `GET /discovery` pull (§A3.2).

  Core acts on pushes in arrival order, so every push is one entry in this
  process's FIFO and they are delivered one at a time: a DELETE queued after a
  POST for the same uuid never overtakes it. `Vagus.App.Server` queues before
  it replies, so whatever its caller does next queues behind. Delivery runs in
  a task, so a slow Core holds up the queue but never `notify/2`.

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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Queues the push. `:discovery_push` names a function the queue calls instead
  of Core, the seam tests use to see each push in order.
  """
  @spec notify(:post | :delete, message()) :: :ok
  def notify(method, %{uuid: _, addon: _, service: _} = message) do
    # The config can hold a password and Core is never sent it.
    GenServer.cast(__MODULE__, {:push, method, Map.take(message, [:uuid, :addon, :service])})
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{queue: :queue.new(), in_flight: nil}}

  @impl GenServer
  def handle_cast({:push, method, message}, state) do
    {:noreply, next(%{state | queue: :queue.in({method, message}, state.queue)})}
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

  defp next(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {method, message}}, queue} ->
        task = Task.Supervisor.async_nolink(Vagus.TaskSupervisor, fn -> run(method, message) end)
        %{state | queue: queue, in_flight: task.ref}

      {:empty, _queue} ->
        state
    end
  end

  defp next(state), do: state

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
