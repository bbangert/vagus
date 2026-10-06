defmodule Vagus.AbsentRetryTest do
  use ExUnit.Case, async: true

  alias Vagus.AbsentRetry

  # Exits with each of `reasons` in turn, then returns `:done`; the attempts
  # made land in the test's mailbox.
  defp failing_with(reasons) do
    test = self()
    {:ok, left} = Agent.start_link(fn -> reasons end)

    fn ->
      send(test, :attempt)

      case Agent.get_and_update(left, &List.pop_at(&1, 0)) do
        nil -> :done
        reason -> exit({reason, {GenServer, :call, [:server, {:register, "tok-secret"}, 5_000]}})
      end
    end
  end

  defp attempts do
    receive do
      :attempt -> 1 + attempts()
    after
      0 -> 0
    end
  end

  test "passes the result through on a first-attempt success" do
    assert {:ok, :done} = AbsentRetry.call(failing_with([]), {5, 0})
    assert attempts() == 1
  end

  test "retries each kind of absent exit until the server answers" do
    absent = [:noproc, :normal, :shutdown, {:shutdown, :restarting}, :killed]

    assert {:ok, :done} = AbsentRetry.call(failing_with(absent), {6, 0})
    assert attempts() == 6
  end

  test "gives up on an absent server when the budget is spent, with the last exit's tag" do
    absent = [:noproc, :noproc, :killed, :noproc]

    assert {:error, :killed} = AbsentRetry.call(failing_with(absent), {3, 0})
    assert attempts() == 3
  end

  test "a budget of one attempt is one attempt" do
    assert {:error, :noproc} = AbsentRetry.call(failing_with([:noproc]), {1, 0})
    assert attempts() == 1
  end

  test "retries a crash once, however much budget is left" do
    assert {:error, :server_down} = AbsentRetry.call(failing_with([:boom, :boom, :boom]), {5, 0})
    assert attempts() == 2

    assert {:ok, :done} = AbsentRetry.call(failing_with([:boom]), {5, 0})
    assert attempts() == 2
  end

  test "an absence between two crashes gives the second crash its own retry" do
    reasons = [:boom, :noproc, :boom, :boom, :boom]

    assert {:error, :server_down} = AbsentRetry.call(failing_with(reasons), {9, 0})
    assert attempts() == 4
  end

  test "does not retry a timeout" do
    assert {:error, :timeout} = AbsentRetry.call(failing_with([:timeout]), {5, 0})
    assert attempts() == 1
  end

  test "tags a crash :server_down whatever its reason holds" do
    for reason <- [
          {:badarg, [{:erlang, :hd, [[]], []}]},
          {{:badmatch, "tok-secret"}, []},
          {%RuntimeError{message: "tok-secret"}, []},
          :boom,
          "not even a tuple"
        ] do
      assert AbsentRetry.tag({reason, {GenServer, :call, [:server, :request, 5_000]}}) ==
               :server_down
    end

    assert AbsentRetry.tag(:not_a_call_exit) == :server_down
  end

  test "tags a {:shutdown, _} exit :shutdown, and the other absent exits as themselves" do
    call = {GenServer, :call, [:server, :request, 5_000]}

    assert AbsentRetry.tag({{:shutdown, :restarting}, call}) == :shutdown
    assert AbsentRetry.tag({:timeout, call}) == :timeout

    for tag <- [:noproc, :normal, :shutdown, :killed] do
      assert AbsentRetry.tag({tag, call}) == tag
    end
  end
end
