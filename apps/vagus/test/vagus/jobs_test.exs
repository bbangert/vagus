defmodule Vagus.JobsTest do
  @moduledoc """
  The job registry (audit B1-B5), unit level: the ten-key wire shape, the
  WS event stream (every state change, in order, `done` last — the contract
  Core's update entities subscribe to), the REST tree transform, delete
  semantics, and the retention cap.
  """

  use ExUnit.Case, async: true

  alias Vagus.Jobs

  # Stands in for `Vagus.Core.EventPusher`: same cast contract
  # (`{:push, data}`), forwards every push to the test process so ordering
  # can be asserted from the mailbox. `nil` drops them (the eviction test
  # pushes hundreds).
  defmodule StubPusher do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_cast({:push, data}, test_pid) do
      if test_pid, do: send(test_pid, {:pushed, data})
      {:noreply, test_pid}
    end
  end

  defp start_jobs(test_pid) do
    {:ok, pusher} = StubPusher.start_link(test_pid)

    name = :"jobs_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Jobs, name: name, pusher: pusher})
    name
  end

  defp drain_pushes(acc \\ []) do
    receive do
      {:pushed, event} -> drain_pushes([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "WS event stream" do
    test "a job lifecycle emits events on every change, in order, done last" do
      jobs = start_jobs(self())

      uuid = Jobs.create("addon_manager_update", "core_test", server: jobs)
      :ok = Jobs.update(uuid, [stage: "pull_image", progress: 20], jobs)
      :ok = Jobs.update(uuid, [stage: "start", progress: 90], jobs)
      :ok = Jobs.finish(uuid, [], jobs)

      assert [created, pull, start, done] =
               drain_pushes() |> Enum.map(fn %{"event" => "job", "data" => data} -> data end)

      assert %{"uuid" => ^uuid, "done" => false, "progress" => 0} = created
      assert created["stage"] == nil
      assert %{"stage" => "pull_image", "progress" => 20, "done" => false} = pull
      assert %{"stage" => "start", "progress" => 90, "done" => false} = start
      assert %{"done" => true, "progress" => 100, "errors" => []} = done
      assert Enum.all?([created, pull, start, done], &(&1["uuid"] == uuid))
    end

    # The nesting is Core's hard requirement — hassio/jobs.py:160 reads
    # event["data"]; the flat union raised KeyError on-device (phase-3 gate).
    test "the event payload nests the ten-key as_dict under data, no child_jobs" do
      jobs = start_jobs(self())
      Jobs.create("supervisor_update", nil, server: jobs)

      assert_receive {:pushed, event}

      assert Map.keys(event) |> Enum.sort() == ["data", "event"]
      assert event["event"] == "job"

      assert Map.keys(event["data"]) |> Enum.sort() ==
               ~w(created done errors extra name parent_id progress reference stage uuid)
    end

    test "a failed finish carries the 5-key error wire shape and keeps its progress" do
      jobs = start_jobs(self())

      uuid = Jobs.create("addon_manager_update", "core_x", server: jobs)
      :ok = Jobs.update(uuid, [progress: 20], jobs)
      :ok = Jobs.finish(uuid, [errors: [Jobs.error_entry("AddonsError", "pull failed")]], jobs)

      assert [_created, _pull, %{"data" => done}] = drain_pushes()
      assert done["done"] == true
      # Progress is NOT forced to 100 on failure — the bar stops where it was.
      assert done["progress"] == 20

      assert [error] = done["errors"]

      assert error == %{
               "type" => "AddonsError",
               "message" => "pull failed",
               "stage" => nil,
               "error_key" => nil,
               "extra_fields" => nil
             }
    end

    test "changes to a finished, unknown, or nil job are no-ops with no event" do
      jobs = start_jobs(self())

      uuid = Jobs.create("supervisor_update", nil, server: jobs)
      :ok = Jobs.finish(uuid, [], jobs)
      assert [_created, _done] = drain_pushes()

      :ok = Jobs.update(uuid, [progress: 50], jobs)
      :ok = Jobs.finish(uuid, [errors: [Jobs.error_entry("X", "late")]], jobs)
      :ok = Jobs.update("0123456789abcdef0123456789abcdef", [progress: 1], jobs)
      :ok = Jobs.update(nil, [progress: 1], jobs)
      :ok = Jobs.finish(nil, [], jobs)

      assert drain_pushes() == []
      assert {:ok, %{"progress" => 100, "errors" => []}} = Jobs.get(uuid, jobs)
    end
  end

  describe "job fields" do
    test "created is a Python-isoformat UTC timestamp, uuid is 32 lowercase hex" do
      jobs = start_jobs(nil)
      uuid = Jobs.create("supervisor_update", nil, server: jobs)

      assert uuid =~ ~r/\A[0-9a-f]{32}\z/

      assert {:ok, job} = Jobs.get(uuid, jobs)
      assert String.ends_with?(job["created"], "+00:00")
      assert {:ok, _dt, 0} = DateTime.from_iso8601(job["created"])
    end

    test "progress is rounded to one decimal, reference is updatable" do
      jobs = start_jobs(nil)
      uuid = Jobs.create("backup_manager_partial_backup", nil, server: jobs)

      :ok = Jobs.update(uuid, [progress: 33.333], jobs)
      assert {:ok, %{"progress" => 33.3}} = Jobs.get(uuid, jobs)

      :ok = Jobs.update(uuid, [reference: "a1b2c3d4"], jobs)
      assert {:ok, %{"reference" => "a1b2c3d4"}} = Jobs.get(uuid, jobs)
    end

    test "a badly-typed change is dropped, never a registry crash (review W5)" do
      jobs = start_jobs(nil)
      uuid = Jobs.create("supervisor_update", nil, server: jobs)

      :ok = Jobs.update(uuid, [progress: "50", stage: "real", extra: "oops"], jobs)

      # The registry survived, the bad fields were dropped, the good one held.
      assert {:ok, job} = Jobs.get(uuid, jobs)
      assert job["progress"] == 0
      assert job["stage"] == "real"
      assert job["extra"] == nil
    end

    test "error_entry truncates oversized messages BY BYTES (review W3 + Copilot PR #29)" do
      entry = Jobs.error_entry("PullError", String.duplicate("x", 2000))
      assert entry["message"] == String.duplicate("x", 512) <> "…"

      # Multibyte: the bound is bytes, not graphemes — 2000 × 3-byte
      # codepoints must still cut at ≤512 bytes (plus the marker), on a
      # valid UTF-8 boundary (512 ÷ 3 leaves a remainder, so a codepoint
      # straddles the cut and is dropped).
      multibyte = Jobs.error_entry("PullError", String.duplicate("€", 2000))
      assert byte_size(multibyte["message"]) <= 512 + byte_size("…")
      assert String.valid?(multibyte["message"])
      assert String.ends_with?(multibyte["message"], "…")

      short = Jobs.error_entry("PullError", "small")
      assert short["message"] == "small"
    end

    test "update/finish against a dead registry are logged no-ops (review W4)" do
      # The caller may hold the :global.trans update mutex — a registry exit
      # must never unwind through it.
      assert :ok = Jobs.update("0123456789abcdef0123456789abcdef", [progress: 1], :no_such_jobs)
      assert :ok = Jobs.finish("0123456789abcdef0123456789abcdef", [], :no_such_jobs)
    end
  end

  describe "REST tree shape" do
    test "tree/2 drops parent_id and injects child_jobs, oldest-inserted first" do
      jobs = start_jobs(nil)

      parent = Jobs.create("home_assistant_core_update", nil, server: jobs)
      child1 = Jobs.create("child_one", nil, server: jobs, parent_id: parent)
      child2 = Jobs.create("child_two", nil, server: jobs, parent_id: parent)
      grandchild = Jobs.create("grandchild", nil, server: jobs, parent_id: child1)

      assert {:ok, tree} = Jobs.tree(parent, jobs)

      refute Map.has_key?(tree, "parent_id")
      assert [%{"uuid" => ^child1} = c1, %{"uuid" => ^child2} = c2] = tree["child_jobs"]
      assert [%{"uuid" => ^grandchild}] = c1["child_jobs"]
      assert c2["child_jobs"] == []
      refute Map.has_key?(c1, "parent_id")
    end

    test "info/1 lists only root jobs as trees, plus ignore_conditions" do
      jobs = start_jobs(nil)

      root1 = Jobs.create("first", nil, server: jobs)
      _child = Jobs.create("child", nil, server: jobs, parent_id: root1)
      root2 = Jobs.create("second", nil, server: jobs)
      :ok = Jobs.set_ignore_conditions(["healthy"], jobs)

      assert %{ignore_conditions: ["healthy"], jobs: [first, second]} = Jobs.info(jobs)
      assert first["uuid"] == root1
      assert second["uuid"] == root2
      assert [%{"name" => "child"}] = first["child_jobs"]
    end
  end

  describe "delete/2" do
    test "refuses a running job, removes a done job and its subtree" do
      jobs = start_jobs(nil)

      parent = Jobs.create("home_assistant_core_update", nil, server: jobs)
      child = Jobs.create("child", nil, server: jobs, parent_id: parent)

      assert {:error, :not_done} = Jobs.delete(parent, jobs)

      :ok = Jobs.finish(parent, [], jobs)
      assert :ok = Jobs.delete(parent, jobs)

      assert :error = Jobs.get(parent, jobs)
      assert :error = Jobs.get(child, jobs)
      assert {:error, :not_found} = Jobs.delete(parent, jobs)
    end
  end

  describe "options / reset" do
    test "set_ignore_conditions validates, reset restores []" do
      jobs = start_jobs(nil)

      assert {:error, :invalid} = Jobs.set_ignore_conditions("healthy", jobs)
      assert {:error, :invalid} = Jobs.set_ignore_conditions([:healthy], jobs)

      assert :ok = Jobs.set_ignore_conditions(["healthy", "running"], jobs)
      assert %{ignore_conditions: ["healthy", "running"]} = Jobs.info(jobs)

      assert :ok = Jobs.reset(jobs)
      assert %{ignore_conditions: []} = Jobs.info(jobs)
    end
  end

  describe "retention" do
    test "done root trees beyond the cap are evicted oldest-first; live jobs never are" do
      jobs = start_jobs(nil)

      # A running job created FIRST — oldest of all, and must survive.
      live = Jobs.create("still_running", nil, server: jobs)

      done_uuids =
        for i <- 1..201 do
          uuid = Jobs.create("done_#{i}", nil, server: jobs)
          :ok = Jobs.finish(uuid, [], jobs)
          uuid
        end

      # 201 done roots against a cap of 200: exactly the oldest evicted.
      assert :error = Jobs.get(hd(done_uuids), jobs)
      assert {:ok, _} = Jobs.get(Enum.at(done_uuids, 1), jobs)
      assert {:ok, %{"done" => false}} = Jobs.get(live, jobs)
    end
  end
end
