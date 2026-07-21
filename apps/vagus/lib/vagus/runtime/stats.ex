defmodule Vagus.Runtime.Stats do
  @moduledoc """
  Reduces a raw Engine-API `/stats` sample into the Supervisor stats shape
  (`aiohasupervisor` `ContainerStats` / the M2 `CoreStats` model) — mirroring
  `supervisor/docker/stats.py`.

  Pure: `compute/1` takes the decoded stats map and returns
  `%{cpu_percent, memory_usage, memory_limit, memory_percent, network_rx,
  network_tx, blk_read, blk_write}`. Missing/partial samples degrade to zeros
  rather than raising (a just-started container may not have `precpu_stats`).
  """

  @zero %{
    cpu_percent: 0.0,
    memory_usage: 0,
    memory_limit: 0,
    memory_percent: 0.0,
    network_rx: 0,
    network_tx: 0,
    blk_read: 0,
    blk_write: 0
  }

  @doc "The all-zero stats map (for a stopped/absent container)."
  @spec zero() :: map()
  def zero, do: @zero

  @doc "Computes the Supervisor stats shape from a raw Engine-API stats sample."
  @spec compute(map()) :: map()
  def compute(raw) when is_map(raw) do
    mem_usage = memory_usage(raw)
    mem_limit = get_in(raw, ["memory_stats", "limit"]) || 0

    %{
      cpu_percent: cpu_percent(raw),
      memory_usage: mem_usage,
      memory_limit: mem_limit,
      memory_percent: percent(mem_usage, mem_limit),
      network_rx: network(raw, "rx_bytes"),
      network_tx: network(raw, "tx_bytes"),
      blk_read: blk(raw, "Read"),
      blk_write: blk(raw, "Write")
    }
  end

  def compute(_), do: @zero

  ## Internals

  # cpu% = (cpu_delta / system_delta) * online_cpus * 100 (docker's own formula).
  defp cpu_percent(raw) do
    cpu = raw["cpu_stats"] || %{}
    precpu = raw["precpu_stats"] || %{}

    cpu_delta = total_usage(cpu) - total_usage(precpu)
    system_delta = (cpu["system_cpu_usage"] || 0) - (precpu["system_cpu_usage"] || 0)
    online = cpu["online_cpus"] || length(get_in(cpu, ["cpu_usage", "percpu_usage"]) || [])
    online = if online == 0, do: 1, else: online

    if cpu_delta > 0 and system_delta > 0 do
      Float.round(cpu_delta / system_delta * online * 100.0, 2)
    else
      0.0
    end
  end

  defp total_usage(cpu_stats), do: get_in(cpu_stats, ["cpu_usage", "total_usage"]) || 0

  # usage minus reclaimable page cache, like the Supervisor.
  defp memory_usage(raw) do
    usage = get_in(raw, ["memory_stats", "usage"]) || 0
    cache = get_in(raw, ["memory_stats", "stats", "cache"]) || 0
    max(usage - cache, 0)
  end

  defp network(raw, key) do
    case raw["networks"] do
      m when is_map(m) -> Enum.reduce(m, 0, fn {_iface, s}, acc -> acc + (s[key] || 0) end)
      _ -> 0
    end
  end

  defp blk(raw, op) do
    (get_in(raw, ["blkio_stats", "io_service_bytes_recursive"]) || [])
    |> Enum.filter(&(&1["op"] == op or &1["op"] == String.downcase(op)))
    |> Enum.reduce(0, fn e, acc -> acc + (e["value"] || 0) end)
  end

  defp percent(_usage, 0), do: 0.0
  defp percent(usage, limit), do: Float.round(usage / limit * 100.0, 2)
end
