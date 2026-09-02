defmodule Vagus.Host.CmdTest do
  use ExUnit.Case, async: true

  alias Vagus.Host.Cmd

  test "nonexistent binary -> fake exit 127 naming the binary, no raise" do
    bin = "vagus-test-no-such-binary-#{System.unique_integer([:positive])}"

    assert {msg, 127} = Cmd.run(bin, ["--version"])
    assert msg =~ bin
  end

  test "real binary -> its own exit status" do
    assert {_output, 0} = Cmd.run("echo", ["vagus"])
  end
end
