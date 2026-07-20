defmodule Vagus.Core.Events do
  @moduledoc """
  Pure builders for the `data` map of a `supervisor/event` WS push
  (`Vagus.Core.EventPusher.push/1` wraps whatever these return in the
  `%{"id" => n, "type" => "supervisor/event", "data" => ...}` envelope).

  No process, no state — just shapes, transcribed exactly from
  `docs/contract-2026.7.md` §4 and §7. Nothing here is called by any other
  code yet (no producers exist in this phase); idle-green requires zero
  events actually emitted.
  """

  @valid_update_keys ~w(info supervisor network core os)

  @job_keys ~w(name reference uuid progress stage done parent_id errors created extra)

  @doc """
  The `update_key` values Supervisor 2026.07.3 actually emits (contract
  §4's "`update_key` values actually emitted" table). Not the same as the
  broader `WSEvent` enum — e.g. there is no `"addon"` update_key.
  """
  @spec valid_update_keys() :: [String.t()]
  def valid_update_keys, do: @valid_update_keys

  @doc """
  Builds the `data` map for a `supervisor_update` event:

      %{"event" => "supervisor_update", "update_key" => update_key, "data" => data}

  `update_key` must be one of `valid_update_keys/0`
  (`info`/`supervisor`/`network`/`core`/`os`) — raises `ArgumentError`
  otherwise, since an unrecognized key here means the doc's emission table
  has drifted from what's actually being sent.
  """
  @spec supervisor_update(String.t(), map()) :: map()
  def supervisor_update(update_key, data) when is_binary(update_key) and is_map(data) do
    if update_key not in @valid_update_keys do
      raise ArgumentError,
            "invalid update_key #{inspect(update_key)}, expected one of #{inspect(@valid_update_keys)}"
    end

    %{"event" => "supervisor_update", "update_key" => update_key, "data" => data}
  end

  @doc """
  Builds the `data` map for a `job` WS event — the flat
  `SupervisorJob.as_dict()` shape (contract §7), unioned with
  `"event" => "job"` (the wire's only hard requirement,
  `SCHEMA_WEBSOCKET_EVENT`, §4).

  This is the WS-event shape, NOT the `/jobs/info` REST tree shape: it
  KEEPS `parent_id` and OMITS `child_jobs` entirely (Core injects
  `child_jobs: []` itself before parsing a single flat job event, §7) —
  the opposite of the REST list, which drops `parent_id` and injects a
  real `child_jobs` tree.

  `job_map` must supply exactly the ten `SupervisorJob.as_dict()` keys
  (`name`, `reference`, `uuid`, `progress`, `stage`, `done`, `parent_id`,
  `errors`, `created`, `extra`), string-keyed. Each entry in `errors`
  should carry the full 5-key wire shape (`type`, `message`, `stage`,
  `error_key`, `extra_fields`) — aiohasupervisor's own `JobError` model
  only reads 3 of those, but the wire (and this emulator, mirroring it)
  sends all 5 (§7's "field mismatch to flag" note).
  """
  @spec job(map()) :: map()
  def job(job_map) when is_map(job_map) do
    present = job_map |> Map.keys() |> MapSet.new()
    expected = MapSet.new(@job_keys)

    missing = MapSet.difference(expected, present)
    extra = MapSet.difference(present, expected)

    if MapSet.size(missing) > 0 or MapSet.size(extra) > 0 do
      raise ArgumentError,
            "Vagus.Core.Events.job/1 expects exactly #{inspect(@job_keys)}: " <>
              "missing=#{inspect(MapSet.to_list(missing))} extra=#{inspect(MapSet.to_list(extra))}"
    end

    Map.put(job_map, "event", "job")
  end
end
