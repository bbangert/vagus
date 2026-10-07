defmodule Vagus.Resource.Lanes do
  @moduledoc """
  Counting semaphores, one per action class, shared by every controller's
  runtime: a board with 1 GB cannot run every image pull at once, and the
  engine should not be asked for more than a few things at a time.

  A slot is held by the process that runs the action, for the time the
  action runs. The wait is in that process, a step's task, so the runtime
  never waits here and a resource that is only deciding or waiting holds
  nothing. A holder that dies gives its slot back, as does a waiter that dies
  its place in line.

  Fairness: within a class the next slot goes to the lowest `:priority`
  waiting, and among equals to the one that asked first. Nothing ages, so a
  steady stream of lower priorities would starve a higher one; the waiters
  are at most one per resource.

  A slot is held for as long as its action takes: one that never returns
  keeps it, so what bounds an action is the timeout of the call it makes.

  This process owns the counts and the lines, and nothing durable. With it
  gone `run/3` exits; its supervisor replaces every runtime, and so every
  holder, with it.
  """

  use GenServer

  @type instance :: atom()
  @type class :: atom()

  @default_caps %{pull: 1, engine: 4}

  @doc "Options: `:instance`, `:caps` (`%{class => slots}`, merged over `:pull` 1 and `:engine` 4)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name(instance(opts)))
  end

  @spec name(instance()) :: atom()
  def name(instance), do: Module.concat(instance, Lanes)

  @doc """
  Runs `fun` holding a slot of `class`, waiting for one as long as it takes.
  Options: `:instance`, `:priority` (default 0). Raises on a class the lanes
  were not started with.
  """
  @spec run(class(), keyword(), (-> result)) :: result when result: var
  def run(class, opts \\ [], fun) when is_function(fun, 0) do
    case acquire(class, opts) do
      :ok ->
        try do
          fun.()
        after
          release(class, opts)
        end

      {:error, {:unknown_class, _class}} ->
        raise ArgumentError, "no lane for action class #{inspect(class)}"
    end
  end

  @doc "Returns once the caller holds a slot. It holds it until `release/2` or its death."
  @spec acquire(class(), keyword()) :: :ok | {:error, {:unknown_class, class()}}
  def acquire(class, opts \\ []) do
    GenServer.call(
      name(instance(opts)),
      {:acquire, class, Keyword.get(opts, :priority, 0)},
      :infinity
    )
  end

  @spec release(class(), keyword()) :: :ok | {:error, :not_held}
  def release(class, opts \\ []), do: GenServer.call(name(instance(opts)), {:release, class})

  @doc "Per class: its slots, the processes holding one, and how many wait."
  @spec info(keyword()) :: %{
          class() => %{cap: pos_integer(), held: [pid()], waiting: non_neg_integer()}
        }
  def info(opts \\ []), do: GenServer.call(name(instance(opts)), :info)

  defp instance(opts), do: Keyword.get(opts, :instance, Vagus.Resource)

  @impl true
  def init(opts) do
    caps = Map.merge(@default_caps, Map.new(Keyword.get(opts, :caps) || %{}))
    {:ok, %{caps: caps, held: %{}, waiting: [], seq: 0}}
  end

  @impl true
  def handle_call({:acquire, class, priority}, {pid, _tag} = from, state)
      when is_map_key(state.caps, class) do
    waiter = {{priority, state.seq}, class, from, Process.monitor(pid)}
    state = %{state | seq: state.seq + 1, waiting: Enum.sort([waiter | state.waiting])}
    {:noreply, grant(state, class)}
  end

  def handle_call({:acquire, class, _priority}, _from, state),
    do: {:reply, {:error, {:unknown_class, class}}, state}

  def handle_call({:release, class}, {pid, _tag}, state) do
    case Enum.find(state.held, &(elem(&1, 1) == {class, pid})) do
      {monitor, _holder} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, grant(%{state | held: Map.delete(state.held, monitor)}, class)}

      nil ->
        {:reply, {:error, :not_held}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info =
      Map.new(state.caps, fn {class, cap} ->
        {class,
         %{
           cap: cap,
           held: for({_monitor, {^class, pid}} <- state.held, do: pid),
           waiting: Enum.count(state.waiting, &(elem(&1, 1) == class))
         }}
      end)

    {:reply, info, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.held, monitor) do
      {{class, _pid}, held} ->
        {:noreply, grant(%{state | held: held}, class)}

      {nil, _held} ->
        {:noreply, %{state | waiting: Enum.reject(state.waiting, &(elem(&1, 3) == monitor))}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp grant(state, class) do
    free? = Enum.count(state.held, &match?({_monitor, {^class, _pid}}, &1)) < state.caps[class]

    case Enum.find(state.waiting, &(elem(&1, 1) == class)) do
      {_order, ^class, {pid, _tag} = from, monitor} = waiter when free? ->
        GenServer.reply(from, :ok)

        grant(
          %{
            state
            | waiting: List.delete(state.waiting, waiter),
              held: Map.put(state.held, monitor, {class, pid})
          },
          class
        )

      _none_or_full ->
        state
    end
  end
end
