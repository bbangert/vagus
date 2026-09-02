defmodule Vagus.Host.CmdTest do
  use ExUnit.Case, async: true

  alias Vagus.Host.Cmd

  test "nonexistent binary -> fake exit 127 naming the binary, no raise" do
    bin = "vagus-test-no-such-binary-#{System.unique_integer([:positive])}"

    assert {msg, 127} = Cmd.run(bin, ["--version"])
    assert msg =~ bin
  end

  # The rescue is written against the exception shape, not against `:enoent`:
  # a present-but-unusable binary raises the same way and must degrade the same.
  @tag :tmp_dir
  test "present but non-executable binary -> fake exit 127 naming :eacces", %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "not-executable")
    File.write!(bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(bin, 0o644)

    assert {msg, 127} = Cmd.run(bin, [])
    assert msg =~ ":eacces"
  end

  test "real binary -> its own exit status" do
    assert {_output, 0} = Cmd.run("echo", ["vagus"])
  end

  test "stderr is merged into the returned output" do
    assert {"err\n", 3} = Cmd.run("sh", ["-c", "echo err 1>&2; exit 3"])
  end
end
