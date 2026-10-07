defmodule Vagus.Resource.StampTest do
  use ExUnit.Case, async: true

  alias Vagus.Resource.{Clock, Stamp, TestClock}

  test "age within one incarnation is the elapsed milliseconds" do
    assert Stamp.age(%Stamp{incarnation: 4, at: 1_000}, %Stamp{incarnation: 4, at: 1_250}) == 250
  end

  test "age across incarnations is zero, whichever way the readings compare" do
    assert Stamp.age(%Stamp{incarnation: 4, at: 1_000}, %Stamp{incarnation: 5, at: 90_000}) == 0
    assert Stamp.age(%Stamp{incarnation: 4, at: 90_000}, %Stamp{incarnation: 5, at: 10}) == 0
  end

  test "a stamp survives JSON, wherever it is nested" do
    stamp = %Stamp{incarnation: 123_456_789_012, at: -576_460_751_000}
    json = Jason.encode!(%{"phase" => "applied", "seen" => [stamp], "started" => stamp})

    assert Stamp.revive(Jason.decode!(json)) ==
             %{"phase" => "applied", "seen" => [stamp], "started" => stamp}
  end

  test "the system clock keeps one incarnation, and setting it up again changes nothing" do
    first = Clock.now()
    :ok = Clock.System.ensure_incarnation()
    second = Clock.now(Clock.System)

    assert is_integer(first.incarnation)
    assert second.incarnation == first.incarnation
    assert Stamp.age(first, second) >= 0
    assert second.at >= first.at
  end

  test "the manual clock moves only when told, and a restart zeroes every earlier age" do
    pid = start_supervised!(TestClock)
    clock = TestClock.clock(pid)

    started = Clock.now(clock)
    assert Stamp.age(started, Clock.now(clock)) == 0

    :ok = TestClock.advance(pid, 1_500)
    assert Stamp.age(started, Clock.now(clock)) == 1_500

    :ok = TestClock.restart(pid)
    :ok = TestClock.advance(pid, 60_000)
    assert Stamp.age(started, Clock.now(clock)) == 0
  end
end
