defmodule Vagus.App.Controller.WorldTest do
  # What the scenarios' own tools can tell apart: a comparison that passes
  # whatever it is given proves nothing about what it compared.
  use ExUnit.Case, async: true

  alias Vagus.Resource.Harness
  alias Vagus.Resource.Harness.Faults
  alias Vagus.Test.AppRows, as: Rows
  alias Vagus.Test.AppWorld

  defp app(status) do
    conditions = %{
      ready: %{type: :ready, status: true, reason: :ready, message: nil, observed_generation: 3},
      dns_ready: %{
        type: :dns_ready,
        status: true,
        reason: :registered,
        message: status.instance.id,
        observed_generation: 3
      }
    }

    Harness.resource(:app, "an_app", %{run: true},
      generation: 3,
      status: Map.put(status, :conditions, conditions)
    )
  end

  defp status(id, over \\ %{}) do
    Map.merge(
      %{
        state: :ready,
        instance: Rows.seen(id: id, ready?: true),
        made_for: %{restart_counter: 0, start_counter: 0, fingerprint: 1},
        expected_exit: nil,
        recreate: nil,
        failure: nil,
        succeeded: nil,
        restarts: %{attempts: 1, last: Rows.ago(9)},
        engine_restarts: %{seen: [], actions: []},
        probe: %{misses: 0, at: Rows.ago(5)},
        pull: nil,
        wave_since: nil,
        waiting_on: [],
        ready_since: Rows.ago(3),
        cleaned: [],
        restart_required: false,
        observed_generation: 3
      },
      over
    )
  end

  describe "normalize/1" do
    test "two runs that differ only in what the engine numbers are the same" do
      one = status("id7-app_an_app")

      other =
        status("id12-app_an_app", %{
          instance:
            Rows.seen(
              id: "id12-app_an_app",
              ready?: true,
              address: "172.30.33.12",
              started_at: "2026-01-01T00:00:00.000000012Z"
            )
        })

      assert AppWorld.normalize([app(one)]) == AppWorld.normalize([app(other)])
      # The gate's message names the instance, under either number.
      assert [%{conditions: %{dns_ready: %{message: "instance-1"}}}] =
               AppWorld.normalize([app(one)])
    end

    for {key, value} <- [
          state: :starting,
          made_for: %{restart_counter: 1, start_counter: 0, fingerprint: 1},
          expected_exit: "c1",
          recreate: "c1",
          failure: %{action: :start, class: :transient, cause: :engine_error, count: 2},
          succeeded: 3,
          restarts: %{attempts: 2, last: nil},
          engine_restarts: %{seen: [1], actions: []},
          probe: %{misses: 1, at: nil},
          pull: %{image: "image:1", generation: 3, failures: 1, seen: nil, after: nil},
          wave_since: 1,
          waiting_on: ["another"],
          ready_since: nil,
          cleaned: [:image],
          restart_required: true,
          observed_generation: 2
        ] do
      test "a difference in #{key} is a difference" do
        base = status("c1")
        changed = Map.put(base, unquote(key), unquote(Macro.escape(value)))
        refute AppWorld.normalize([app(base)]) == AppWorld.normalize([app(changed)])
      end
    end

    test "so is one in a failure's count, a stamp, or what of the instance is recorded" do
      base = status("c1", %{failure: Rows.failure(count: 1)})

      for changed <- [
            %{base | failure: Rows.failure(count: 2)},
            %{base | failure: Rows.failure(at: Rows.ago(1))},
            %{base | probe: %{misses: 0, at: Rows.ago(6)}},
            put_in(base.instance.ready?, false),
            put_in(base.instance.restart_count, 1),
            put_in(base.instance.address, nil)
          ] do
        refute AppWorld.normalize([app(base)]) == AppWorld.normalize([app(changed)])
      end
    end
  end

  describe "a journal compared with another" do
    test "is the same, or the same with one action done twice in a row, and nothing else" do
      reference = [:create, :put_token, :start]
      assert Faults.replay?(reference, reference)
      assert Faults.replay?(reference, [:create, :create, :put_token, :start])
      refute Faults.replay?(reference, [:create, :put_token])
      refute Faults.replay?(reference, [:create, :start, :put_token])
      refute Faults.replay?(reference, [:create, :create, :put_token, :start, :start])
      refute Faults.replay?(reference, [:create, :put_token, :create, :start])
      # What the engine saw of a start with no token is not a start.
      refute Faults.replay?(reference, [:create, :put_token, {:start, :token_unknown}])
    end
  end
end
