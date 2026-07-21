defmodule Vagus.Runtime.LogsTest do
  @moduledoc "P5-T1: demux + format of the engine container log stream."
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Logs

  defp frame(stream, payload), do: <<stream, 0, 0, 0, byte_size(payload)::32>> <> payload

  test "demux strips the 8-byte frame headers and concatenates payloads" do
    stream = frame(1, "hello\n") <> frame(2, "an error\n") <> frame(1, "bye\n")
    assert Logs.demux(stream) == "hello\nan error\nbye\n"
  end

  test "an unframed (TTY / already-plain) body is returned unchanged" do
    assert Logs.demux("just plain text\nno frames\n") == "just plain text\nno frames\n"
  end

  test "a truncated trailing frame keeps the fully-parsed prefix" do
    good = frame(1, "line one\n")
    truncated = <<1, 0, 0, 0, 99::32, "short">>
    assert Logs.demux(good <> truncated) == "line one\n"
  end

  test "format with no_colors strips ANSI SGR sequences" do
    body = frame(1, "\e[32mgreen\e[0m plain\n")
    assert Logs.format(body, no_colors: true) == "green plain\n"
    assert Logs.format(body, no_colors: false) == "\e[32mgreen\e[0m plain\n"
  end
end
