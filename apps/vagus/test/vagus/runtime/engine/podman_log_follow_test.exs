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

  test "a record longer than one read block is not mistaken for the end", %{log: log} do
    long = String.duplicate("y", 100_000)
    File.write!(log, records(["2026-10-15T18:14:21.0+00:00 stdout F " <> long]))
    {:ok, pid} = Engine.follow_logs("x", self(), engine(log, nil))
    assert collect(pid, []) == long <> "\n"
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
