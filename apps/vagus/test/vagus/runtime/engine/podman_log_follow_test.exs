defmodule Vagus.Runtime.Engine.Podman.LogFollowTest do
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Engine
  alias Vagus.Runtime.Logs.Follow
  alias Vagus.Test.FakePodman

  @fixtures Path.expand("../../../fixtures/podman", __DIR__)

  setup do
    log = Path.join(System.tmp_dir!(), "podman-follow-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(log) end)
    %{log: log}
  end

  defp conmon do
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["600"])
    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true) end)
    pid
  end

  defp kill(pid), do: System.cmd("kill", ["-9", "#{pid}"])

  defp engine(log, conmon_pid) do
    [raw] = @fixtures |> Path.join("inspect_running.json") |> File.read!() |> Jason.decode!()

    raw =
      raw
      |> put_in(["HostConfig", "LogConfig", "Path"], log)
      |> put_in(["State", "Running"], conmon_pid != nil)
      |> put_in(["State", "ConmonPid"], conmon_pid || 0)

    fake = FakePodman.start([{"container inspect *", [{0, Jason.encode!([raw])}]}])
    host = FakePodman.start_host(fake.bin)
    [engine: Engine.Podman, host: host, podman_bin: fake.bin, poll_ms: 20]
  end

  defp records(lines), do: Enum.map_join(lines, &(&1 <> "\n"))

  defp next_chunk(pid) do
    assert_receive {:log_chunk, chunk}, 10_000
    Follow.ack(pid)
    chunk
  end

  test "P fragments join into one line; stamps open each line, in UTC", %{log: log} do
    File.write!(
      log,
      records([
        "2026-10-15T18:14:21.278087093+00:00 stdout P partial-",
        "2026-10-15T18:14:21.278087094+00:00 stdout F rest",
        "2026-10-15T20:14:21.278145854+02:00 stderr F two",
        "2026-10-15T18:14:21.300000000+00:00 stdout F"
      ])
    )

    {:ok, pid} = Engine.follow_logs("x", self(), engine(log, nil))
    assert next_chunk(pid) == "partial-rest\ntwo\n\n"
    assert_receive :log_eof, 10_000

    {:ok, pid} = Engine.follow_logs("x", self(), [timestamps: true] ++ engine(log, nil))

    assert next_chunk(pid) ==
             "2026-10-15T18:14:21.278087093Z partial-rest\n" <>
               "2026-10-15T18:14:21.278145Z two\n" <>
               "2026-10-15T18:14:21.300000000Z \n"
  end

  test "the backfill is the last `tail` lines", %{log: log} do
    File.write!(log, records(for n <- 1..5, do: "2026-10-15T18:14:21.0+00:00 stdout F l#{n}"))
    {:ok, pid} = Engine.follow_logs("x", self(), [tail: 2] ++ engine(log, nil))
    assert next_chunk(pid) == "l4\nl5\n"
    assert_receive :log_eof, 10_000
  end

  test "lines appended later arrive, one chunk per ack; conmon's exit ends it", %{log: log} do
    File.write!(log, records(["2026-10-15T18:14:21.0+00:00 stdout F one"]))
    conmon = conmon()
    {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))
    assert_receive {:log_chunk, "one\n"}, 10_000

    File.write!(log, records(["2026-10-15T18:14:22.0+00:00 stdout P tw"]), [:append])
    # A tick while the chunk is un-acked reads nothing.
    send(pid, {:tick, :sys.get_state(pid).tick})
    _ = :sys.get_state(pid)
    refute_received {:log_chunk, _}
    Follow.ack(pid)
    assert next_chunk(pid) == "tw"

    File.write!(log, records(["2026-10-15T18:14:22.0+00:00 stdout F o"]), [:append])
    kill(conmon)
    assert next_chunk(pid) == "o\n"
    assert_receive :log_eof, 10_000
  end

  test "the backfill is found by scanning back across blocks, not by reading the log", %{log: log} do
    filler = String.duplicate("x", 1_000)

    File.write!(
      log,
      records(for n <- 1..3_000, do: "2026-10-15T18:14:21.0+00:00 stdout F #{n} #{filler}")
    )

    {:ok, pid} = Engine.follow_logs("x", self(), [tail: 70] ++ engine(log, nil))

    lines = collect(pid, []) |> String.split("\n", trim: true)
    assert length(lines) == 70
    assert hd(lines) == "2931 " <> filler
    assert List.last(lines) == "3000 " <> filler
  end

  describe "an unfinished last line counts toward tail" do
    test "one P fragment", %{log: log} do
      File.write!(
        log,
        records([
          "2026-10-15T18:14:21.0+00:00 stdout F one",
          "2026-10-15T18:14:21.0+00:00 stdout F two",
          "2026-10-15T18:14:21.0+00:00 stdout P three"
        ])
      )

      {:ok, pid} = Engine.follow_logs("x", self(), [tail: 2] ++ engine(log, nil))
      assert collect(pid, []) == "two\nthree"
    end

    test "several P fragments of one line", %{log: log} do
      File.write!(
        log,
        records([
          "2026-10-15T18:14:21.0+00:00 stdout F one",
          "2026-10-15T18:14:21.0+00:00 stdout F two",
          "2026-10-15T18:14:21.0+00:00 stdout P thr",
          "2026-10-15T18:14:21.0+00:00 stdout P e",
          "2026-10-15T18:14:21.0+00:00 stdout P e"
        ])
      )

      {:ok, pid} = Engine.follow_logs("x", self(), [tail: 1] ++ engine(log, nil))
      assert collect(pid, []) == "three"

      {:ok, pid} = Engine.follow_logs("x", self(), [tail: 2] ++ engine(log, nil))
      assert collect(pid, []) == "two\nthree"
    end
  end

  test "a tail past 10,000 lines is honoured", %{log: log} do
    File.write!(
      log,
      records(for n <- 1..12_000, do: "2026-10-15T18:14:21.0+00:00 stdout F l#{n}")
    )

    {:ok, pid} = Engine.follow_logs("x", self(), [tail: 10_001] ++ engine(log, nil))
    lines = collect(pid, []) |> String.split("\n", trim: true)
    assert length(lines) == 10_001
    assert hd(lines) == "l2000"
  end

  test "a long record goes out in chunks of at most 64 KiB, each only after an ack",
       %{log: log} do
    long = String.duplicate("y", 100_000)
    File.write!(log, records(["2026-10-15T18:14:21.0+00:00 stdout F " <> long]))
    {:ok, pid} = Engine.follow_logs("x", self(), engine(log, nil))

    chunks = gated_chunks(pid, [])
    assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
    assert length(chunks) == 2
    assert IO.iodata_to_binary(chunks) == long <> "\n"
  end

  test "an unfinished record past 1 MiB goes out as it comes", %{log: log} do
    conmon = conmon()
    head = "2026-10-15T18:14:21.0+00:00 stdout F "
    body = String.duplicate("z", 1_200_000)
    File.write!(log, "")
    {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))

    File.write!(log, head <> body, [:append])
    assert receive_bytes(pid, byte_size(body), []) == body

    File.write!(log, "\n", [:append])
    assert next_chunk(pid) == "\n"
    assert :sys.get_state(pid).pending == ""
  end

  # Each chunk: while it is un-acked, a tick sends nothing more.
  defp gated_chunks(pid, acc) do
    receive do
      {:log_chunk, chunk} ->
        send(pid, {:tick, :sys.get_state(pid).tick})
        _ = :sys.get_state(pid)
        refute_received {:log_chunk, _}
        Follow.ack(pid)
        gated_chunks(pid, [chunk | acc])

      :log_eof ->
        Enum.reverse(acc)
    after
      10_000 -> flunk("no :log_eof")
    end
  end

  defp receive_bytes(_pid, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp receive_bytes(pid, left, acc) do
    assert_receive {:log_chunk, chunk}, 10_000
    assert byte_size(chunk) <= 65_536
    Follow.ack(pid)
    receive_bytes(pid, left - byte_size(chunk), [chunk | acc])
  end

  defp collect(pid, acc) do
    receive do
      {:log_chunk, chunk} ->
        Follow.ack(pid)
        collect(pid, [chunk | acc])

      :log_eof ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    after
      10_000 -> flunk("no :log_eof")
    end
  end

  # As conmon rotates: an empty `.tmp` renamed over the log, then records.
  defp rotate(log, lines) do
    tmp = log <> ".tmp"
    File.write!(tmp, "")
    File.rename!(tmp, log)
    File.write!(log, records(lines), [:append])
  end

  defp await_queued(pid, n) do
    Enum.find(1..1_000, fn _ ->
      length(:sys.get_state(pid).queued) == n or (Process.sleep(5) && false)
    end) || flunk("#{n} rotated file(s) never queued")
  end

  defp stamp(line), do: "2026-10-15T18:14:21.0+00:00 stdout F " <> line

  describe "rotations" do
    test "two while a chunk waits for its ack: every generation is read", %{log: log} do
      File.write!(log, records([stamp("one")]))
      conmon = conmon()
      {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))
      assert_receive {:log_chunk, "one\n"}, 10_000

      # B is unlinked by C's rename before the reader could reach it.
      File.write!(log, records([stamp("two")]), [:append])
      rotate(log, [stamp("three")])
      await_queued(pid, 1)
      rotate(log, [stamp("four")])
      await_queued(pid, 2)

      Follow.ack(pid)
      assert next_chunk(pid) == "two\n"
      assert next_chunk(pid) == "three\n"
      assert next_chunk(pid) == "four\n"
    end

    # The append and the rename both land between two ticks: the old file's
    # tail is read before the switch.
    test "a rotation right after the old file grew keeps its tail", %{log: log} do
      File.write!(log, records([stamp("one")]))
      conmon = conmon()
      {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))
      assert next_chunk(pid) == "one\n"
      _ = :sys.get_state(pid)

      :sys.suspend(pid)
      File.write!(log, records([stamp("tail")]), [:append])
      rotate(log, [stamp("next")])
      :sys.resume(pid)

      assert next_chunk(pid) == "tail\n"
      assert next_chunk(pid) == "next\n"
    end

    test "an unfinished record in a replaced file ends there, not glued on", %{log: log} do
      File.write!(log, records([stamp("one")]) <> stamp("partial"))
      conmon = conmon()
      {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))
      assert next_chunk(pid) == "one\n"

      rotate(log, [stamp("next")])
      assert receive_text(pid, "partial\nnext\n") == "partial\nnext\n"
    end

    # A recreated container writes a new file at the same path; this follow
    # belonged to the one before.
    test "once conmon has exited, a new file at the path is not followed", %{log: log} do
      File.write!(log, records([stamp("old")]))
      conmon = conmon()
      {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))
      assert next_chunk(pid) == "old\n"
      _ = :sys.get_state(pid)

      :sys.suspend(pid)
      kill(conmon)

      Enum.find(1..1_000, fn _ ->
        not File.exists?("/proc/#{conmon}") or (Process.sleep(5) && false)
      end)

      rotate(log, [stamp("someone else's")])
      :sys.resume(pid)

      assert_receive :log_eof, 10_000
      refute_received {:log_chunk, _}
    end
  end

  # Text across however many chunks it takes to make `expected`'s length.
  defp receive_text(pid, expected, acc \\ "") do
    if byte_size(acc) >= byte_size(expected) do
      acc
    else
      receive_text(pid, expected, acc <> next_chunk(pid))
    end
  end

  # conmon 2.2.1 at max-size, as recorded on podman 6.1.4: it flushes the
  # full file, creates `<path>.tmp` empty, renames it over the log (a new
  # inode, no `.1` kept) and writes on there.
  test "follows conmon's cap rotation: the old file to its end, then the new one",
       %{log: log} do
    File.write!(log, records(["2026-10-15T18:14:21.0+00:00 stdout F one"]))
    conmon = conmon()
    {:ok, pid} = Engine.follow_logs("x", self(), engine(log, conmon))
    assert next_chunk(pid) == "one\n"

    File.write!(log, records(["2026-10-15T18:14:22.0+00:00 stdout F two"]), [:append])
    tmp = log <> ".tmp"
    File.write!(tmp, "")
    File.rename!(tmp, log)
    File.write!(log, records(["2026-10-15T18:14:23.0+00:00 stdout F three"]), [:append])

    assert next_chunk(pid) == "two\n"
    assert next_chunk(pid) == "three\n"

    File.write!(log, records(["2026-10-15T18:14:24.0+00:00 stdout F four"]), [:append])
    kill(conmon)
    assert next_chunk(pid) == "four\n"
    assert_receive :log_eof, 10_000
  end

  test "an owner that goes away stops the follow", %{log: log} do
    File.write!(log, "")
    opts = engine(log, conmon())
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, pid} = Engine.follow_logs("x", owner, opts)
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  test "a container without a log file is just :log_eof", %{log: log} do
    {:ok, _pid} = Engine.follow_logs("x", self(), engine(log, nil))
    assert_receive :log_eof, 10_000
    refute_received {:log_chunk, _}
  end
end
