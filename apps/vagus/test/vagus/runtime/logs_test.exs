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

  # -- demux_stream/2 (incremental, /logs/follow) ---------------------------

  defp frame(type, payload), do: <<type, 0, 0, 0, byte_size(payload)::32, payload::binary>>

  defp collect({payloads, pending}), do: {IO.iodata_to_binary(payloads), pending}

  describe "demux_stream/2" do
    test "whole frames in one chunk" do
      data = frame(1, "out\n") <> frame(2, "err\n")
      assert Logs.demux_stream("", data) |> collect() == {"out\nerr\n", ""}
    end

    test "split at every header boundary" do
      data = frame(1, "hello\n")

      for split <- 1..7 do
        <<a::binary-size(split), b::binary>> = data
        assert {payloads1, pending} = Logs.demux_stream("", a)
        assert IO.iodata_to_binary(payloads1) == ""
        assert Logs.demux_stream(pending, b) |> collect() == {"hello\n", ""}
      end
    end

    test "split mid-payload carries the partial frame" do
      data = frame(1, "abcdef")
      <<a::binary-size(10), b::binary>> = data

      assert {[], pending} = Logs.demux_stream("", a)
      assert pending == a
      assert Logs.demux_stream(pending, b) |> collect() == {"abcdef", ""}
    end

    test "multiple frames split across three chunks" do
      data = frame(1, "one\n") <> frame(1, "two\n") <> frame(2, "three\n")
      <<a::binary-size(5), b::binary-size(14), c::binary>> = data

      {p1, pend1} = Logs.demux_stream("", a)
      {p2, pend2} = Logs.demux_stream(pend1, b)
      {p3, pend3} = Logs.demux_stream(pend2, c)

      assert IO.iodata_to_binary([p1, p2, p3]) == "one\ntwo\nthree\n"
      assert pend3 == ""
    end

    test "TTY/unframed data passes straight through, even short chunks" do
      assert Logs.demux_stream("", "hello ") |> collect() == {"hello ", ""}
      assert Logs.demux_stream("", "world\n") |> collect() == {"world\n", ""}
    end

    test "garbage after valid frames passes through rather than being dropped" do
      data = frame(1, "good\n") <> "not a frame header at all"
      assert Logs.demux_stream("", data) |> collect() == {"good\nnot a frame header at all", ""}
    end

    test "empty input" do
      assert Logs.demux_stream("", "") == {[], ""}
    end

    test "a frame whose payload exceeds the pending cap overflows" do
      # Header declares 2MB; feed >1MB of it so the carried remainder
      # busts the cap.
      header = <<1, 0, 0, 0, 2_000_000::32>>
      {[], pending} = Logs.demux_stream("", header)
      big = :binary.copy(<<0>>, 1_100_000)
      assert Logs.demux_stream(pending, big) == {:error, :pending_overflow, []}
    end

    test "overflow salvages complete frames peeled in the same call" do
      huge = <<1, 0, 0, 0, 2_000_000::32>> <> :binary.copy(<<0>>, 1_100_000)
      data = frame(1, "ok\n") <> huge

      assert {:error, :pending_overflow, salvaged} = Logs.demux_stream("", data)
      assert IO.iodata_to_binary(salvaged) == "ok\n"
    end
  end

  describe "verbose_line/3" do
    test "reformats a docker RFC3339Nano stamp into the §A5 verbose shape" do
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

  test "format with no_colors strips ANSI SGR sequences" do
    body = frame(1, "\e[32mgreen\e[0m plain\n")
    assert Logs.format(body, no_colors: true) == "green plain\n"
    assert Logs.format(body, no_colors: false) == "\e[32mgreen\e[0m plain\n"
  end
end
