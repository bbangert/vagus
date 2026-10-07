defmodule Vagus.Resource.TestInstance do
  @moduledoc """
  A private resource store per test, so store tests run `async: true`
  beside the application's own instance.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised: 1]

  alias Vagus.Resource.{Stamp, Store}

  @doc "Starts the whole subtree and returns the instance name."
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

  @doc """
  Kills the store and returns once the supervisor has replaced it.
  """
  @spec restart_store(atom()) :: pid()
  def restart_store(instance) do
    old = Process.whereis(Store.name(instance))
    ref = Process.monitor(old)
    Process.exit(old, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old, :killed} -> :ok
    after
      1_000 -> raise "store did not die"
    end

    # A call the supervisor answers only after it has handled the exit,
    # which is where it restarts the child.
    children = Supervisor.which_children(Module.concat(instance, Supervisor))
    {Store, new, :worker, _modules} = List.keyfind(children, Store, 0)
    true = is_pid(new) and new != old
    new
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

  defp spec(instance, opts) do
    opts = opts |> Keyword.put(:instance, instance) |> Keyword.put_new(:kinds, kinds())
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

  defp decode_progress(%{"phase" => phase, "started" => %Stamp{} = started}),
    do: %{phase: String.to_existing_atom(phase), started: started}

  defp decode_progress(progress) when progress == %{}, do: %{}
end
