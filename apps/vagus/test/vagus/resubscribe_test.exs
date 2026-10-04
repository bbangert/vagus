defmodule Vagus.ResubscribeTest do
  use ExUnit.Case, async: true

  alias Vagus.Resubscribe

  # A stand-in for an in-memory subscriber registry: reports every
  # subscription to the test process.
  defmodule Server do
    use GenServer

    def start(name, test), do: GenServer.start(__MODULE__, test, name: name)
    def subscribe(server), do: GenServer.call(server, :subscribe)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call(:subscribe, {pid, _tag}, test) do
      send(test, {:subscribed, self(), pid})
      {:reply, :ok, test}
    end
  end

  # Drives the Resubscribe calls the way a subscribing GenServer does.
  defp subscriber(name) do
    test = self()

    spawn_link(fn ->
      ref = Resubscribe.subscribe(name, &Server.subscribe/1)
      send(test, {:initial_ref, ref})
      loop(name, ref)
    end)
  end

  defp loop(name, ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        loop(name, Resubscribe.down(name, :retry))

      :retry ->
        loop(name, Resubscribe.retry(name, &Server.subscribe/1, :retry))
    end
  end

  test "resubscribes to a named server's replacement after it restarts" do
    name = :"resubscribe_#{System.unique_integer([:positive])}"
    {:ok, first} = Server.start(name, self())
    sub = subscriber(name)

    assert_receive {:subscribed, ^first, ^sub}
    assert_receive {:initial_ref, ref} when is_reference(ref)

    mon = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^mon, :process, ^first, :killed}
    # Still away on the first retry tick; back before a later one.
    {:ok, second} = Server.start(name, self())

    assert_receive {:subscribed, ^second, ^sub}, 3_000
  end

  test "a server that isn't running is not subscribed to and not retried" do
    name = :"resubscribe_absent_#{System.unique_integer([:positive])}"
    assert Resubscribe.subscribe(name, &Server.subscribe/1) == nil
  end

  test "a dead pid is never retried" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert Resubscribe.subscribe(pid, fn _ -> flunk("subscribed to a dead pid") end) == nil
    assert Resubscribe.down(pid, :retry) == nil
    refute_receive :retry, 1_200
  end
end
