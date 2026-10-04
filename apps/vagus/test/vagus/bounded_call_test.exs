defmodule Vagus.BoundedCallTest do
  use ExUnit.Case, async: true

  alias Vagus.BoundedCall

  test "returns the function's value" do
    assert BoundedCall.run(fn -> {:ok, 42} end, 1_000) == {:ok, 42}
  end

  test "a raise comes back as an exit reason instead of killing the caller" do
    assert {:error, {:exit, {%RuntimeError{message: "boom"}, stacktrace}}} =
             BoundedCall.run(fn -> raise "boom" end, 1_000)

    assert is_list(stacktrace)
  end

  test "an exit and a throw come back the same way" do
    assert BoundedCall.run(fn -> exit(:gone) end, 1_000) == {:error, {:exit, :gone}}

    assert {:error, {:exit, {{:nocatch, :thrown}, _}}} =
             BoundedCall.run(fn -> throw(:thrown) end, 1_000)
  end

  test "a call over the deadline times out and its task is killed" do
    test = self()

    assert BoundedCall.run(
             fn ->
               send(test, {:task, self()})
               Process.sleep(:infinity)
             end,
             50
           ) == {:error, :attempt_timeout}

    assert_receive {:task, pid}
    refute Process.alive?(pid)
  end
end
