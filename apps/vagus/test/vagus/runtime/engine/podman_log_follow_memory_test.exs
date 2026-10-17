defmodule Vagus.Runtime.Engine.Podman.LogFollowMemoryTest do
  # async: false, so no other test's allocations land in the measurement.
  use ExUnit.Case, async: false

  alias Vagus.Runtime.Engine
  alias Vagus.Test.FakePodman

  @fixtures Path.expand("../../../fixtures/podman", __DIR__)
  @record_bytes 16 * 1_048_576

  setup do
    log =
      Path.join(System.tmp_dir!(), "podman-follow-mem-#{System.unique_integer([:positive])}.log")

    on_exit(fn -> File.rm(log) end)
    %{log: log}
  end

  defp engine(log) do
    [raw] = @fixtures |> Path.join("inspect_running.json") |> File.read!() |> Jason.decode!()

    raw =
      raw
      |> put_in(["HostConfig", "LogConfig", "Path"], log)
      |> put_in(["State", "Running"], false)

    fake = FakePodman.start([{"container inspect *", [{0, Jason.encode!([raw])}]}])
    [engine: Engine.Podman, host: FakePodman.start_host(fake.bin), podman_bin: fake.bin]
  end

  # Peak growth of the VM's binary memory while `fun` runs.
  defp peak_binary_growth(fun) do
    :erlang.garbage_collect()
    base = :erlang.memory(:binary)
    test = self()

    sampler =
      spawn_link(fn ->
        sample = fn sample, peak ->
          receive do
            :stop -> send(test, {:peak, peak})
          after
            1 -> sample.(sample, max(peak, :erlang.memory(:binary)))
          end
        end

        sample.(sample, base)
      end)

    result = fun.()
    send(sampler, :stop)
    assert_receive {:peak, peak}, 5_000
    {result, peak - base}
  end

  test "a backfill tail through a multi-MiB record scans in bounded memory", %{log: log} do
    big = String.duplicate("q", @record_bytes)

    File.write!(log, [
      "2026-10-15T18:14:21.0+00:00 stdout F before\n",
      "2026-10-15T18:14:21.0+00:00 stdout F ",
      big,
      "\n2026-10-15T18:14:22.0+00:00 stdout F after\n"
    ])

    opts = engine(log)

    {pid, growth} =
      peak_binary_growth(fn ->
        {:ok, pid} = Engine.follow_logs("x", self(), [tail: 2] ++ opts)
        assert_receive {:log_chunk, _first}, 10_000
        pid
      end)

    assert growth < 4 * 1_048_576,
           "the scan and first chunk grew binary memory by #{growth} bytes"

    Engine.ack_logs(pid)
    rest = collect(pid, [])
    assert byte_size(rest) == @record_bytes + byte_size("\nafter\n") - 65_536
    assert String.ends_with?(rest, "q\nafter\n")
  end

  defp collect(pid, acc) do
    receive do
      {:log_chunk, chunk} ->
        Engine.ack_logs(pid)
        collect(pid, [chunk | acc])

      :log_eof ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    after
      10_000 -> flunk("no :log_eof")
    end
  end
end
