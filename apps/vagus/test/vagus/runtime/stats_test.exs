defmodule Vagus.Runtime.StatsTest do
  @moduledoc "P5-T2: reducing a raw engine /stats sample to the Supervisor shape."
  use ExUnit.Case, async: true

  alias Vagus.Runtime.Stats

  @sample %{
    "cpu_stats" => %{
      "cpu_usage" => %{"total_usage" => 2_000_000_000},
      "system_cpu_usage" => 20_000_000_000,
      "online_cpus" => 4
    },
    "precpu_stats" => %{
      "cpu_usage" => %{"total_usage" => 1_000_000_000},
      "system_cpu_usage" => 10_000_000_000
    },
    "memory_stats" => %{
      "usage" => 100_000_000,
      "limit" => 500_000_000,
      "stats" => %{"cache" => 20_000_000}
    },
    "networks" => %{
      "eth0" => %{"rx_bytes" => 1000, "tx_bytes" => 2000},
      "eth1" => %{"rx_bytes" => 500, "tx_bytes" => 100}
    },
    "blkio_stats" => %{
      "io_service_bytes_recursive" => [
        %{"op" => "Read", "value" => 4096},
        %{"op" => "Write", "value" => 8192},
        %{"op" => "Read", "value" => 1024}
      ]
    }
  }

  test "computes cpu%, memory (usage-cache), memory%, net and blk totals" do
    s = Stats.compute(@sample)

    # cpu_delta=1e9, system_delta=1e10, online=4 → 0.1*4*100 = 40.0
    assert s.cpu_percent == 40.0
    assert s.memory_usage == 80_000_000
    assert s.memory_limit == 500_000_000
    assert s.memory_percent == 16.0
    assert s.network_rx == 1500
    assert s.network_tx == 2100
    assert s.blk_read == 5120
    assert s.blk_write == 8192
  end

  test "a just-started sample with no precpu_stats yields 0 cpu, not a crash" do
    s = Stats.compute(%{"memory_stats" => %{"usage" => 10, "limit" => 100}})
    assert s.cpu_percent == 0.0
    assert s.memory_usage == 10
    assert s.memory_percent == 10.0
  end

  test "non-map / empty input degrades to zeros" do
    assert Stats.compute(nil) == Stats.zero()
    assert Stats.compute(%{}).cpu_percent == 0.0
    assert Stats.compute(%{}).memory_limit == 0
  end

  test "zero limit doesn't divide by zero" do
    assert Stats.compute(%{"memory_stats" => %{"usage" => 5, "limit" => 0}}).memory_percent == 0.0
  end
end
