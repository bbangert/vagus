defmodule Vagus.Core.EventsTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.Events

  describe "supervisor_update/2" do
    test "builds the exact wire shape (contract §4)" do
      data = Events.supervisor_update("info", %{"state" => "running"})

      assert data == %{
               "event" => "supervisor_update",
               "update_key" => "info",
               "data" => %{"state" => "running"}
             }
    end

    for key <- ~w(info supervisor network core os) do
      test "accepts the valid update_key #{key}" do
        assert %{"update_key" => unquote(key)} = Events.supervisor_update(unquote(key), %{})
      end
    end

    test "valid_update_keys/0 matches the contract §4 emission table" do
      assert Events.valid_update_keys() == ~w(info supervisor network core os)
    end

    test "raises on an unrecognized update_key" do
      assert_raise ArgumentError, fn -> Events.supervisor_update("addon", %{}) end
    end
  end

  describe "job/1" do
    # The job dict rides NESTED under "data" — Core's hassio/jobs.py:160
    # reads event["data"] and a flat union raises KeyError in its
    # dispatcher. Device-proven 2026-07-29 (the phase-3 gate caught the
    # flat shape erroring on every event).
    test "nests the flat as_dict under data: keeps parent_id, omits child_jobs" do
      error = %{
        "type" => "SomeError",
        "message" => "boom",
        "stage" => "install",
        "error_key" => "some_key",
        "extra_fields" => %{"detail" => "x"}
      }

      job_map = %{
        "name" => "addon_manager_update",
        "reference" => "core_ssh",
        "uuid" => "11111111-1111-1111-1111-111111111111",
        "progress" => 42.5,
        "stage" => "download",
        "done" => false,
        "parent_id" => nil,
        "errors" => [error],
        "created" => "2026-07-20T00:00:00+00:00",
        "extra" => nil
      }

      event = Events.job(job_map)

      assert Map.keys(event) |> Enum.sort() == ["data", "event"]
      assert event["event"] == "job"

      data = event["data"]

      assert MapSet.new(Map.keys(data)) ==
               MapSet.new(
                 ~w(name reference uuid progress stage done parent_id errors created extra)
               )

      refute Map.has_key?(data, "child_jobs")
      refute Map.has_key?(data, "event")
      assert data["parent_id"] == nil
      assert data["errors"] == [error]
    end

    test "errors entries keep all 5 wire keys (type, message, stage, error_key, extra_fields)" do
      error = %{
        "type" => "JobException",
        "message" => "failed",
        "stage" => nil,
        "error_key" => nil,
        "extra_fields" => nil
      }

      job_map = base_job(errors: [error])
      assert [^error] = Events.job(job_map)["data"]["errors"]
    end

    test "raises when a required key is missing" do
      job_map = base_job() |> Map.delete("uuid")
      assert_raise ArgumentError, fn -> Events.job(job_map) end
    end

    test "raises when an extra/unknown key is present" do
      job_map = Map.put(base_job(), "child_jobs", [])
      assert_raise ArgumentError, fn -> Events.job(job_map) end
    end

    defp base_job(overrides \\ []) do
      %{
        "name" => "supervisor_update",
        "reference" => nil,
        "uuid" => "00000000-0000-0000-0000-000000000000",
        "progress" => 0.0,
        "stage" => nil,
        "done" => false,
        "parent_id" => nil,
        "errors" => [],
        "created" => "2026-07-20T00:00:00+00:00",
        "extra" => nil
      }
      |> Map.merge(Map.new(overrides, fn {k, v} -> {Atom.to_string(k), v} end))
    end
  end
end
