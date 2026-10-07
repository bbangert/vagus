defmodule Vagus.Resource.TestInstance do
  @moduledoc """
  A private resource store per test, so store tests run `async: true`
  beside the application's own instance.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised: 1]

  alias Vagus.Resource.{Stamp, Store}

  @doc """
  Starts the whole subtree and returns the instance name. Options are
  `Vagus.Resource.Supervisor`'s, and `:owned`, as `owned/2` takes it, for a
  store with no controllers that is to take status writes.
  """
  @spec start!(keyword()) :: atom()
  def start!(opts \\ []) do
    instance = Keyword.get_lazy(opts, :instance, &name/0)
    start_supervised!(spec(instance, opts))
    instance
  end

  @spec start(keyword()) :: {:ok, atom()} | {:error, term()}
  def start(opts \\ []) do
    instance = Keyword.get_lazy(opts, :instance, &name/0)
    with {:ok, _pid} <- start_supervised(spec(instance, opts)), do: {:ok, instance}
  end

  @spec name() :: atom()
  def name, do: Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")

  @doc "Kills the store and returns its replacement."
  @spec restart_store(atom()) :: pid()
  def restart_store(instance) do
    old = Process.whereis(Store.name(instance))
    kill_observed(old, Process.whereis(Vagus.Resource.Supervisor.store_supervisor(instance)))
    new = Process.whereis(Store.name(instance))
    true = is_pid(new) and new != old
    new
  end

  @doc """
  Kills `victim` and returns once `observer`, which links to or monitors it,
  has dealt with its death.

  The test's own `DOWN` says nothing about when the observer's copy lands:
  signals to two receivers are not ordered. So the observer's mailbox is
  traced until the `EXIT` or `DOWN` is seen arriving there, and only then
  is it sent a call, which queues behind it.
  """
  @spec kill_observed(pid(), pid()) :: :ok
  def kill_observed(victim, observer) do
    :erlang.trace(observer, true, [:receive])
    Process.exit(victim, :kill)

    receive do
      {:trace, ^observer, :receive, {:DOWN, _ref, :process, ^victim, _reason}} -> :ok
      {:trace, ^observer, :receive, {:EXIT, ^victim, _reason}} -> :ok
    after
      5_000 -> raise "#{inspect(observer)} never heard that #{inspect(victim)} died"
    end

    :erlang.trace(observer, false, [:receive])
    :sys.get_state(observer)

    delivered = :erlang.trace_delivered(observer)

    receive do
      {:trace_delivered, ^observer, ^delivered} -> drop_traces(observer)
    after
      5_000 -> raise "trace of #{inspect(observer)} never drained"
    end
  end

  defp drop_traces(observer) do
    receive do
      {:trace, ^observer, :receive, _message} -> drop_traces(observer)
    after
      0 -> :ok
    end
  end

  @doc """
  `:thing` has atoms in its spec and a stamp in its progress, which JSON
  cannot carry by itself; `:part` is as plain as a kind gets.
  """
  @spec kinds() :: map()
  def kinds do
    %{
      thing: [
        validators: [&validate/1],
        decode_spec: &decode_spec/1,
        decode_progress: &decode_progress/1
      ],
      part: []
    }
  end

  @doc """
  `kinds` with who may write their status, as a list of controllers would
  have declared it: `writers` is `%{kind => [{writer, condition_types}]}`,
  and the first writer of a kind is its owner.
  """
  @spec owned(map(), %{optional(atom()) => [{term(), [atom()]}]}) :: map()
  def owned(kinds, writers) do
    Enum.reduce(writers, Map.new(kinds), fn {kind, [{owner, _types} | _] = declared}, kinds ->
      conditions = for {writer, types} <- declared, type <- types, into: %{}, do: {type, writer}
      fields = kinds |> Map.fetch!(kind) |> Map.new()
      Map.put(kinds, kind, Map.merge(fields, %{owner: owner, conditions: conditions}))
    end)
  end

  defp spec(instance, opts) do
    {writers, opts} = Keyword.pop(opts, :owned, %{})

    opts =
      opts
      |> Keyword.put(:instance, instance)
      |> Keyword.update(:kinds, owned(kinds(), writers), &owned(&1, writers))

    Supervisor.child_spec({Vagus.Resource.Supervisor, opts}, id: instance)
  end

  defp validate(%{bad: true}), do: {:error, :bad}
  defp validate(spec), do: {:ok, Map.put_new(spec, :holds, %{})}

  defp decode_spec(spec) do
    Map.new(spec, fn
      {"mode", mode} -> {:mode, String.to_existing_atom(mode)}
      {key, value} -> {String.to_existing_atom(key), value}
    end)
  end

  defp decode_progress(progress) do
    Map.new(progress, fn
      {"phase", phase} -> {:phase, String.to_existing_atom(phase)}
      {"started", %Stamp{} = started} -> {:started, started}
    end)
  end
end
