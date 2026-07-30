defmodule Vagus.Jobs do
  @moduledoc """
  The job registry — `supervisor/jobs/__init__.py`'s `JobManager`, reduced
  to what Core actually consumes (audit B1–B5).

  A job is the ten-key `SupervisorJob.as_dict()` map `Vagus.Core.Events.job/1`
  validates (`name`, `reference`, `uuid`, `progress`, `stage`, `done`,
  `parent_id`, `errors`, `created`, `extra` — `docs/contract-2026.7.md` §7).
  This registry owns the canonical copy of every job, emits a `job` WS event
  through `Vagus.Core.EventPusher` on **every** state change (create, update,
  finish — that is the whole point: Core's update entities subscribe to these
  by job *name*, contract §4), and serves the REST shapes:

    * **WS event** — `%{"event" => "job", "data" => job_map}`, built by
      `Events.job/1`: the flat ten-key dict (keeps `parent_id`, no
      `child_jobs`) rides nested under `"data"` — Core's `hassio/jobs.py`
      reads `event["data"]`, device-proven 2026-07-29.
    * **REST** (`GET /jobs/info`, `GET /jobs/{uuid}`) — `as_dict()` minus
      `parent_id`, plus a recursive `child_jobs` tree in oldest-inserted
      order (§7's `_list_jobs`).

  ## What producers call

  `create/3` → zero or more `update/3` (stage/progress transitions) →
  `finish/3` (`done: true`, and on success `progress: 100`). All three accept
  `nil` for the uuid and no-op on it, so a producer wired for job tracking
  (`Vagus.Addon.Update`, `Vagus.Core.Lifecycle`, the backup routes) can run
  identically with tracking off — job bookkeeping must never be the reason an
  update fails. An unknown uuid is likewise a logged no-op, not an error:
  the job may have been evicted (below) mid-operation.

  ## Retention

  Upstream keeps every job in memory until `DELETE /jobs/{uuid}` and is
  restarted often enough not to care. Vagus runs for months, so done job
  trees beyond `@max_done_roots` are evicted oldest-first (a tree is
  evictable only when every job in it is done). Deliberate, logged
  divergence: Core polls a job's uuid only while the operation runs, and 200
  finished jobs of history is far more than the frontend ever pages.

  ## `/jobs/options` and `/jobs/reset`

  `ignore_conditions` is stored and echoed in `/jobs/info`; `reset` puts it
  back to `[]` (upstream's `reset_data()` resets the persisted options — it
  does **not** clear the job list). Vagus has no job-condition machinery, so
  the list is bookkeeping-only and any string is accepted — validating
  against upstream's `JobCondition` enum would enforce a vocabulary with no
  behaviour behind it.
  """

  use GenServer

  require Logger

  alias Vagus.Core.EventPusher
  alias Vagus.Core.Events

  @max_done_roots 200

  @typedoc "The flat ten-key `SupervisorJob.as_dict()` map, string-keyed."
  @type job :: %{String.t() => term()}

  ## Client API

  @doc """
  Starts the registry.

  Options:

    * `:name` - GenServer name, defaults to `#{inspect(__MODULE__)}`.
    * `:pusher` - the `Vagus.Core.EventPusher` server WS events are pushed
      through, defaults to `Vagus.Core.EventPusher`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Creates a job and returns its uuid. Emits the first `job` WS event.

  `name` should be one of upstream's job names when Core subscribes to it
  (`addon_manager_update`, `home_assistant_core_update`,
  `supervisor_update` — contract §4); `reference` is the add-on slug /
  backup slug / nil.

  Options: `:parent_id`, `:extra`, `:server`.
  """
  @spec create(String.t(), String.t() | nil, keyword()) :: String.t()
  def create(name, reference \\ nil, opts \\ [])
      when is_binary(name) and (is_binary(reference) or is_nil(reference)) do
    GenServer.call(
      server(opts),
      {:create, name, reference, Keyword.get(opts, :parent_id), Keyword.get(opts, :extra)}
    )
  end

  @doc """
  Updates a live job's `progress`/`stage`/`extra`/`reference` and emits a
  `job` WS event (`reference` exists for the backup case, where the created
  backup's slug is only known at the end). `nil` and unknown uuids no-op
  (see the moduledoc); updating a job that is already `done` also no-ops,
  so a straggling stage report from a background task can never un-finish
  a job.
  """
  @spec update(String.t() | nil, keyword(), GenServer.server()) :: :ok
  def update(uuid, changes, server \\ __MODULE__)
  def update(nil, _changes, _server), do: :ok

  # The `catch :exit` below (also in `finish/3`) is the moduledoc promise
  # made literal: `report_stage/3` runs while its caller holds the
  # `:global.trans` update mutex, so a slow or restarting registry must
  # degrade to a logged no-op — never unwind an exit through a mid-flight
  # container update (review W4).
  def update(uuid, changes, server) when is_binary(uuid) do
    GenServer.call(
      server,
      {:update, uuid, Map.new(Keyword.take(changes, [:progress, :stage, :extra, :reference]))}
    )
  catch
    :exit, reason ->
      Logger.warning("Vagus.Jobs: dropping update for #{uuid}: #{inspect(reason)}")
      :ok
  end

  @doc """
  Marks a job done and emits the final `job` WS event (`done: true` — Core
  keys "the operation ended" off exactly this). With `errors: []` progress
  is forced to `100`; with errors it is left where it was. Each error entry
  is the 5-key wire shape — build them with `error_entry/3`.

  `nil`/unknown/already-done uuids no-op, same as `update/3`.
  """
  @spec finish(String.t() | nil, keyword(), GenServer.server()) :: :ok
  def finish(uuid, opts \\ [], server \\ __MODULE__)
  def finish(nil, _opts, _server), do: :ok

  def finish(uuid, opts, server) when is_binary(uuid) do
    GenServer.call(server, {:finish, uuid, Keyword.get(opts, :errors, [])})
  catch
    :exit, reason ->
      Logger.warning("Vagus.Jobs: dropping finish for #{uuid}: #{inspect(reason)}")
      :ok
  end

  @doc """
  The 5-key `SupervisorJobError.as_dict()` wire shape (contract §7 — the
  wire carries all 5 even though aiohasupervisor's model reads 3).
  """
  @spec error_entry(String.t(), String.t(), String.t() | nil) :: map()
  def error_entry(type, message, stage \\ nil) do
    %{
      "type" => type,
      "message" => truncate_message(message),
      "stage" => stage,
      "error_key" => nil,
      "extra_fields" => nil
    }
  end

  # Job errors are readable at `:default` tier via `/jobs/info`, and some
  # failure reasons `inspect` whole HTTP response bodies — bound what goes on
  # the wire; the full detail belongs in the log (review W3).
  # `String.byte_slice/3`, not `String.slice/3`: the guard is in bytes, so
  # the cut must be too — a grapheme slice of a multibyte message can leak
  # several times the stated bound (Copilot, PR #29). `byte_slice` also
  # drops any codepoint it would split, keeping the result valid UTF-8.
  @max_error_message 512
  defp truncate_message(message) when byte_size(message) <= @max_error_message, do: message
  defp truncate_message(message), do: String.byte_slice(message, 0, @max_error_message) <> "…"

  @doc "The flat ten-key job map (WS shape), or `:error`."
  @spec get(String.t(), GenServer.server()) :: {:ok, job()} | :error
  def get(uuid, server \\ __MODULE__) when is_binary(uuid) do
    GenServer.call(server, {:get, uuid})
  end

  @doc """
  The REST shape for `GET /jobs/{uuid}`: `as_dict()` minus `parent_id`,
  plus the recursive `child_jobs` tree. `:error` if unknown.
  """
  @spec tree(String.t(), GenServer.server()) :: {:ok, map()} | :error
  def tree(uuid, server \\ __MODULE__) when is_binary(uuid) do
    GenServer.call(server, {:tree, uuid})
  end

  @doc """
  `GET /jobs/info` attrs: `ignore_conditions` plus every root job as a
  REST-shaped tree, oldest first.
  """
  @spec info(GenServer.server()) :: %{ignore_conditions: [String.t()], jobs: [map()]}
  def info(server \\ __MODULE__) do
    GenServer.call(server, :info)
  end

  @doc """
  `DELETE /jobs/{uuid}` — upstream refuses to delete a running job
  (`"Job is not done"`) and 404s an unknown one. Deleting a parent deletes
  its subtree (children are unreachable through the REST tree otherwise).
  """
  @spec delete(String.t(), GenServer.server()) :: :ok | {:error, :not_done | :not_found}
  def delete(uuid, server \\ __MODULE__) when is_binary(uuid) do
    GenServer.call(server, {:delete, uuid})
  end

  @doc "`POST /jobs/options` — stores `ignore_conditions` (strings only)."
  @spec set_ignore_conditions([String.t()], GenServer.server()) :: :ok | {:error, :invalid}
  def set_ignore_conditions(conditions, server \\ __MODULE__) do
    GenServer.call(server, {:set_ignore_conditions, conditions})
  end

  @doc "`POST /jobs/reset` — resets `ignore_conditions` to `[]`. Jobs stay."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       # uuid => %{job: ten_key_map, seq: n} — `seq` is the global insertion
       # counter that orders `child_jobs` ("oldest-inserted-child order", §7)
       # and root jobs in `/jobs/info`.
       jobs: %{},
       seq: 0,
       ignore_conditions: [],
       pusher: Keyword.get(opts, :pusher, EventPusher)
     }}
  end

  @impl GenServer
  def handle_call({:create, name, reference, parent_id, extra}, _from, state) do
    uuid = new_uuid()

    job = %{
      "name" => name,
      "reference" => reference,
      "uuid" => uuid,
      "progress" => 0,
      "stage" => nil,
      "done" => false,
      "parent_id" => parent_id,
      "errors" => [],
      "created" => created_now(),
      "extra" => normalize_extra(extra)
    }

    state =
      %{state | jobs: Map.put(state.jobs, uuid, %{job: job, seq: state.seq}), seq: state.seq + 1}
      |> push_event(job)

    {:reply, uuid, state}
  end

  def handle_call({:update, uuid, changes}, _from, state) do
    {:reply, :ok, change_live_job(state, uuid, &apply_changes(&1, changes))}
  end

  def handle_call({:finish, uuid, errors}, _from, state) do
    {:reply, :ok, state |> change_live_job(uuid, &finish_job(&1, errors)) |> evict_done()}
  end

  def handle_call({:get, uuid}, _from, state) do
    case Map.fetch(state.jobs, uuid) do
      {:ok, %{job: job}} -> {:reply, {:ok, job}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:tree, uuid}, _from, state) do
    case Map.fetch(state.jobs, uuid) do
      {:ok, %{job: job}} -> {:reply, {:ok, rest_shape(job, state.jobs)}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:info, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.job["parent_id"] == nil))
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(&rest_shape(&1.job, state.jobs))

    {:reply, %{ignore_conditions: state.ignore_conditions, jobs: jobs}, state}
  end

  def handle_call({:delete, uuid}, _from, state) do
    case Map.fetch(state.jobs, uuid) do
      {:ok, %{job: %{"done" => false}}} ->
        {:reply, {:error, :not_done}, state}

      {:ok, %{job: _done}} ->
        {:reply, :ok, %{state | jobs: drop_subtree(state.jobs, uuid)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_ignore_conditions, conditions}, _from, state) do
    if is_list(conditions) and Enum.all?(conditions, &is_binary/1) do
      {:reply, :ok, %{state | ignore_conditions: conditions}}
    else
      {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | ignore_conditions: []}}
  end

  ## Internals

  # The shared no-op discipline for update/finish: unknown uuid (evicted or
  # mistyped) and already-done jobs are logged and skipped — see moduledoc.
  defp change_live_job(state, uuid, fun) do
    case Map.fetch(state.jobs, uuid) do
      {:ok, %{job: %{"done" => false} = job} = entry} ->
        changed = fun.(job)

        %{state | jobs: Map.put(state.jobs, uuid, %{entry | job: changed})}
        |> push_event(changed)

      {:ok, _done} ->
        Logger.warning("Vagus.Jobs: ignoring change to finished job #{uuid}")
        state

      :error ->
        Logger.warning("Vagus.Jobs: ignoring change to unknown job #{uuid}")
        state
    end
  end

  defp apply_changes(job, changes) do
    Enum.reduce(changes, job, fn
      {:progress, progress}, acc when is_number(progress) ->
        Map.put(acc, "progress", round_progress(progress))

      {:stage, stage}, acc when is_binary(stage) or is_nil(stage) ->
        Map.put(acc, "stage", stage)

      {:extra, extra}, acc when is_map(extra) or is_nil(extra) ->
        Map.put(acc, "extra", extra)

      {:reference, reference}, acc when is_binary(reference) or is_nil(reference) ->
        Map.put(acc, "reference", reference)

      # A badly-typed value degrades to a dropped field, never a crash of the
      # one global registry — `Keyword.take/2` filters keys, not value types
      # (review W5).
      {key, value}, acc ->
        Logger.warning("Vagus.Jobs: dropping bad #{key} change: #{inspect(value)}")
        acc
    end)
  end

  defp finish_job(job, []) do
    %{job | "done" => true, "progress" => 100}
  end

  defp finish_job(job, errors) when is_list(errors) do
    %{job | "done" => true, "errors" => job["errors"] ++ errors}
  end

  # Upstream: `round(self.progress, 1)`.
  defp round_progress(progress) when is_integer(progress), do: progress
  defp round_progress(progress) when is_float(progress), do: Float.round(progress, 1)

  # Same degrade-don't-crash rule as `apply_changes/2`'s catch-all, for the
  # one create-time field with no client-side guard.
  defp normalize_extra(extra) when is_map(extra) or is_nil(extra), do: extra

  defp normalize_extra(extra) do
    Logger.warning("Vagus.Jobs: dropping bad extra: #{inspect(extra)}")
    nil
  end

  defp push_event(state, job) do
    job |> Events.job() |> EventPusher.push(state.pusher)
    state
  end

  # `as_dict()` minus `parent_id`, plus the recursive `child_jobs` tree,
  # children oldest-inserted first (§7).
  defp rest_shape(job, jobs) do
    child_jobs =
      jobs
      |> Map.values()
      |> Enum.filter(&(&1.job["parent_id"] == job["uuid"]))
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(&rest_shape(&1.job, jobs))

    job
    |> Map.delete("parent_id")
    |> Map.put("child_jobs", child_jobs)
  end

  defp drop_subtree(jobs, uuid) do
    child_uuids =
      jobs
      |> Map.values()
      |> Enum.filter(&(&1.job["parent_id"] == uuid))
      |> Enum.map(& &1.job["uuid"])

    Enum.reduce(child_uuids, Map.delete(jobs, uuid), &drop_subtree(&2, &1))
  end

  # Evict the oldest fully-done root trees beyond @max_done_roots. Runs on
  # finish (the only call that grows the done count), so the map is bounded
  # by @max_done_roots done trees + however many operations run concurrently.
  defp evict_done(state) do
    done_roots =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.job["parent_id"] == nil and subtree_done?(state.jobs, &1.job["uuid"])))
      |> Enum.sort_by(& &1.seq)

    excess = length(done_roots) - @max_done_roots

    if excess > 0 do
      jobs =
        done_roots
        |> Enum.take(excess)
        |> Enum.reduce(state.jobs, fn %{job: %{"uuid" => uuid}}, acc ->
          Logger.info("Vagus.Jobs: evicting finished job #{uuid} (retention cap)")
          drop_subtree(acc, uuid)
        end)

      %{state | jobs: jobs}
    else
      state
    end
  end

  defp subtree_done?(jobs, uuid) do
    case Map.fetch(jobs, uuid) do
      {:ok, %{job: %{"done" => false}}} ->
        false

      {:ok, %{job: job}} ->
        jobs
        |> Map.values()
        |> Enum.filter(&(&1.job["parent_id"] == job["uuid"]))
        |> Enum.all?(&subtree_done?(jobs, &1.job["uuid"]))

      :error ->
        true
    end
  end

  # uuid4-hex-shaped: 32 lowercase hex chars, like upstream's `uuid4().hex`
  # (and like the fake `new_job_id/0` this registry replaces).
  defp new_uuid, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  # Python `datetime.isoformat()` emits `+00:00`, not `Z` — mirror the wire.
  defp created_now do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace_suffix("Z", "+00:00")
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
end
