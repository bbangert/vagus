defmodule Vagus.Resource.LanesTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource.{Lanes, TestInstance}

  setup do
    instance = TestInstance.name()
    start_supervised!({Lanes, instance: instance, caps: %{pair: 2}})
    %{i: [instance: instance]}
  end

  # A process that takes a slot, says so, and keeps it until told to stop.
  defp holder(class, opts) do
    test = self()

    spawn_link(fn ->
      Lanes.run(class, opts, fn ->
        send(test, {:holding, self()})

        receive do
          :done -> :ok
        end
      end)

      send(test, {:released, self()})
    end)
  end

  # Returns once `count` processes are in line, which is when asking again
  # is certain to be behind them.
  defp waiting(i, class, count) do
    lanes = Process.whereis(Lanes.name(i[:instance]))
    :erlang.trace(lanes, true, [:receive])

    result =
      Enum.reduce_while(Stream.cycle([:again]), nil, fn :again, nil ->
        case Lanes.info(i)[class].waiting do
          ^count ->
            {:halt, :ok}

          _fewer ->
            assert_receive {:trace, ^lanes, :receive,
                            {:"$gen_call", _from, {:acquire, ^class, _}}},
                           5_000

            {:cont, nil}
        end
      end)

    :erlang.trace(lanes, false, [:receive])
    result
  end

  test "the defaults are one pull and four engine calls, and a given cap replaces one", %{i: i} do
    assert %{pull: %{cap: 1}, engine: %{cap: 4}, pair: %{cap: 2}} = Lanes.info(i)

    other = TestInstance.name()
    start_supervised!({Lanes, instance: other, caps: %{engine: 2}}, id: other)
    assert %{pull: %{cap: 1}, engine: %{cap: 2}} = Lanes.info(instance: other)
  end

  test "no more holders than the cap, and a release lets the next one in", %{i: i} do
    first = holder(:pair, i)
    second = holder(:pair, i)
    assert_receive {:holding, ^first}, 5_000
    assert_receive {:holding, ^second}, 5_000

    third = holder(:pair, i)
    waiting(i, :pair, 1)
    assert %{pair: %{held: held, waiting: 1}} = Lanes.info(i)
    assert Enum.sort(held) == Enum.sort([first, second])
    refute_received {:holding, ^third}

    send(first, :done)
    assert_receive {:released, ^first}, 5_000
    assert_receive {:holding, ^third}, 5_000
  end

  test "a holder that dies gives its slot back; a waiter that dies leaves the line", %{i: i} do
    Process.flag(:trap_exit, true)
    first = holder(:pull, i)
    assert_receive {:holding, ^first}, 5_000
    quitter = holder(:pull, i)
    waiting(i, :pull, 1)
    patient = holder(:pull, i)
    waiting(i, :pull, 2)

    Process.exit(quitter, :kill)
    assert_receive {:EXIT, ^quitter, :killed}, 5_000
    Process.exit(first, :kill)

    assert_receive {:holding, ^patient}, 5_000
    assert %{pull: %{held: [^patient], waiting: 0}} = Lanes.info(i)
  end

  test "the next slot goes to the lowest priority waiting, then to whoever asked first", %{i: i} do
    first = holder(:pull, i)
    assert_receive {:holding, ^first}, 5_000

    later = holder(:pull, [priority: 5] ++ i)
    waiting(i, :pull, 1)
    sooner_a = holder(:pull, [priority: 1] ++ i)
    waiting(i, :pull, 2)
    sooner_b = holder(:pull, [priority: 1] ++ i)
    waiting(i, :pull, 3)

    for {done, next} <- [{first, sooner_a}, {sooner_a, sooner_b}, {sooner_b, later}] do
      send(done, :done)
      assert_receive {:holding, ^next}, 5_000
    end
  end

  test "a class the lanes were not started with is refused, as is a release of nothing", %{i: i} do
    assert Lanes.acquire(:ghost, i) == {:error, {:unknown_class, :ghost}}
    assert_raise ArgumentError, fn -> Lanes.run(:ghost, i, fn -> :ok end) end
    assert Lanes.release(:pull, i) == {:error, :not_held}
  end

  test "a function that raises still gives its slot back", %{i: i} do
    assert_raise RuntimeError, fn -> Lanes.run(:pull, i, fn -> raise "no" end) end
    assert Lanes.run(:pull, i, fn -> :ran end) == :ran
    assert %{pull: %{held: []}} = Lanes.info(i)
  end
end
