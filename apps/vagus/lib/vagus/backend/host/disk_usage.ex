defmodule Vagus.Backend.Host.DiskUsage do
  @moduledoc """
  Shared `df -k` reading/parsing for `HostInfo.disk_free/disk_total/
  disk_used`, used by both `Vagus.Backend.Host.HostStub` (against the dev
  machine's current-working-directory filesystem — there's no `/data`
  mount on a dev box) and `Vagus.Backend.Host.Nerves` (against the real
  `/data` mountpoint).

  Units: contract §14 only says `float` with no unit named; this project
  follows the Phase 2 static defaults already pinned in
  `Vagus.API.StaticData.host_info/0` (`10.0`/`32.0`/`22.0`), which read as
  **GB** (gibibytes, matching `df`'s KB-block accounting) — kept here for
  continuity rather than switching units mid-project.
  """

  @kb_per_gb 1_048_576

  @doc """
  Runs `df -k path` and returns `{free_gb, total_gb, used_gb}` as floats.
  Falls back to `{0.0, 0.0, 0.0}` on any failure (missing path, no `df`
  binary, unparseable output) — required non-null wire fields, so a
  failure must not surface as `nil`.
  """
  @spec usage_gb(String.t()) :: {float(), float(), float()}
  def usage_gb(path) do
    case System.cmd("df", ["-k", path], stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      _error -> {0.0, 0.0, 0.0}
    end
  rescue
    ErlangError -> {0.0, 0.0, 0.0}
  end

  @doc """
  Runs `df -k path` and returns `{total_bytes, free_bytes}` as integers —
  the byte-accurate variant `GET /host/disks/default/usage` needs (the
  GB floats above stay as-is for `/host/info` continuity). `{0, 0}` on
  any failure, same rationale as `usage_gb/1`.
  """
  @spec usage_bytes(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def usage_bytes(path) do
    case System.cmd("df", ["-k", path], stderr_to_stdout: true) do
      {output, 0} -> parse_bytes(output)
      _error -> {0, 0}
    end
  rescue
    ErlangError -> {0, 0}
  end

  @doc "Pure parser for `df -k`'s output returning `{total_bytes, free_bytes}`."
  @spec parse_bytes(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def parse_bytes(output) do
    with [_header, data_line | _rest] <- String.split(output, "\n", trim: true),
         [_filesystem, total_kb, _used_kb, free_kb | _rest] <-
           String.split(data_line, ~r/\s+/, trim: true),
         {total, _} <- Integer.parse(total_kb),
         {free, _} <- Integer.parse(free_kb) do
      {total * 1024, free * 1024}
    else
      _other -> {0, 0}
    end
  end

  @doc "Pure parser for `df -k`'s output (the two-line, whitespace-columns form)."
  @spec parse(String.t()) :: {float(), float(), float()}
  def parse(output) do
    case String.split(output, "\n", trim: true) do
      [_header, data_line | _rest] -> parse_data_line(data_line)
      _other -> {0.0, 0.0, 0.0}
    end
  end

  defp parse_data_line(data_line) do
    case String.split(data_line, ~r/\s+/, trim: true) do
      [_filesystem, total_kb, used_kb, free_kb | _rest] ->
        {kb_to_gb(free_kb), kb_to_gb(total_kb), kb_to_gb(used_kb)}

      _other ->
        {0.0, 0.0, 0.0}
    end
  end

  defp kb_to_gb(kb_string) do
    case Integer.parse(kb_string) do
      {kb, _rest} -> kb / @kb_per_gb
      :error -> 0.0
    end
  end
end
