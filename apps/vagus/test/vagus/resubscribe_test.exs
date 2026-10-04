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

  # Drives the Resubscribe calls the way a subscribing GenServer does, and
  # tells the test about every retry tick it handles.
  defp subscriber(name, expected?) do
    test = self()

    pid =
      spawn(fn ->
        ref = Resubscribe.start(name, &Server.subscribe/1, :retry, expected?)
        send(test, {:initial_ref, ref})
        loop(name, ref, test)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp loop(name, ref, test) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        loop(name, Resubscribe.down(name, :retry), test)

      :retry ->
        ref = Resubscribe.retry(name, &Server.subscribe/1, :retry)
        send(test, {:retry_tick, ref})
        loop(name, ref, test)
    end
  end

  defp unique_name, do: :"resubscribe_#{System.unique_integer([:positive])}"

  defp start_server(name) do
    {:ok, pid} = Server.start(name, self())
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "keeps retrying while a named server is down, then resubscribes to its replacement" do
    name = unique_name()
    first = start_server(name)
    sub = subscriber(name, false)

    assert_receive {:subscribed, ^first, ^sub}
    assert_receive {:initial_ref, ref} when is_reference(ref)

    mon = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^mon, :process, ^first, :killed}

    # Two observed ticks with the server still absent: the retry re-arms
    # itself rather than giving up after one miss.
    assert_receive {:retry_tick, nil}, 3_000
    assert_receive {:retry_tick, nil}, 3_000

    second = start_server(name)
    assert_receive {:subscribed, ^second, ^sub}, 3_000
  end

  test "an expected server that isn't up yet at start is retried until it is" do
    name = unique_name()
    sub = subscriber(name, true)

    assert_receive {:initial_ref, nil}
    assert_receive {:retry_tick, nil}, 3_000

    server = start_server(name)
    assert_receive {:subscribed, ^server, ^sub}, 3_000
  end

  test "an unexpected server that isn't running is not subscribed to and not retried" do
    _sub = subscriber(unique_name(), false)

    assert_receive {:initial_ref, nil}
    refute_receive {:retry_tick, _}, 1_200
  end

  test "a dead pid is never retried" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert Resubscribe.start(pid, fn _ -> flunk("subscribed to a dead pid") end, :retry, true) ==
             nil

    assert Resubscribe.down(pid, :retry) == nil
    refute_receive :retry, 1_200
  end
end
