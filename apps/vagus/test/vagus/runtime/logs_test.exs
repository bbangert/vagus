defmodule Vagus.Runtime.LogsTest do
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Logs

  describe "verbose_line/3" do
    test "reformats an RFC3339Nano stamp into the §A5 verbose shape" do
      line = "2026-07-23T01:02:03.123456789Z Starting server"

      assert Logs.verbose_line(line, "nerves-06e6", "homeassistant") ==
               "2026-07-23 01:02:03.123 nerves-06e6 homeassistant: Starting server"
    end

    test "second-precision stamps get .000" do
      assert Logs.verbose_line("2026-07-23T01:02:03Z hi", "h", "i") ==
               "2026-07-23 01:02:03.000 h i: hi"
    end

    test "a line without a parseable stamp keeps the prefix only" do
      assert Logs.verbose_line("no stamp here", "h", "svc") == "h svc: no stamp here"
      assert Logs.verbose_line("single-token", "h", "svc") == "h svc: single-token"
    end
  end

  test "strip_ansi removes ANSI SGR sequences and nothing else" do
    assert Logs.strip_ansi("\e[32mgreen\e[0m plain\n") == "green plain\n"
    assert Logs.strip_ansi("plain\n") == "plain\n"
  end
end
