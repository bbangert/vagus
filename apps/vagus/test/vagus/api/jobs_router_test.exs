defmodule Vagus.API.JobsRouterTest do
  @moduledoc """
  The `/jobs` REST surface (audit B1/B2): `GET /jobs/info` backed by the
  real registry, `GET|DELETE /jobs/{uuid}`, and `POST /jobs/options|reset`.

  `async: false` — the router resolves its registry through the process-global
  `:jobs_server` app env, which this file points at an isolated instance so
  the global one stays empty for the read-only router tests.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}
  alias Vagus.Jobs

  @opts Router.init([])

  setup do
    name = :"jobs_router_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Jobs, name: name})

    prev = Application.get_env(:vagus, :jobs_server)
    Application.put_env(:vagus, :jobs_server, name)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:vagus, :jobs_server, prev),
        else: Application.delete_env(:vagus, :jobs_server)
    end)

    %{jobs: name}
  end

  defp call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{Token.get()}")
    |> Router.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /jobs/info" do
    test "reflects live registry state as a tree, not the static empty list", %{jobs: jobs} do
      parent = Jobs.create("home_assistant_core_update", nil, server: jobs)
      _child = Jobs.create("child", nil, server: jobs, parent_id: parent)
      :ok = Jobs.set_ignore_conditions(["healthy"], jobs)

      conn = call(:get, "/jobs/info")
      assert conn.status == 200

      data = json(conn)["data"]
      assert data["ignore_conditions"] == ["healthy"]
      assert [%{"uuid" => ^parent, "child_jobs" => [%{"name" => "child"}]}] = data["jobs"]
    end
  end

  describe "GET /jobs/{uuid}" do
    test "returns the REST tree shape: no parent_id, child_jobs injected", %{jobs: jobs} do
      parent = Jobs.create("addon_manager_update", "core_x", server: jobs)
      child = Jobs.create("child", nil, server: jobs, parent_id: parent)
      :ok = Jobs.update(parent, [stage: "pull_image", progress: 20], jobs)

      conn = call(:get, "/jobs/#{parent}")
      assert conn.status == 200

      data = json(conn)["data"]
      assert data["uuid"] == parent
      assert data["name"] == "addon_manager_update"
      assert data["reference"] == "core_x"
      assert data["stage"] == "pull_image"
      assert data["progress"] == 20
      assert data["done"] == false
      refute Map.has_key?(data, "parent_id")
      assert [%{"uuid" => ^child}] = data["child_jobs"]
    end

    test "an unknown uuid is a 404, no longer a dead route (B1)" do
      conn = call(:get, "/jobs/00112233445566778899aabbccddeeff")

      assert conn.status == 404
      assert json(conn)["message"] == "Job does not exist"
    end
  end

  describe "DELETE /jobs/{uuid}" do
    test "refuses a running job, deletes a done one, 404s an unknown one", %{jobs: jobs} do
      uuid = Jobs.create("supervisor_update", nil, server: jobs)

      conn = call(:delete, "/jobs/#{uuid}")
      assert conn.status == 400
      assert json(conn)["message"] =~ "is not done"

      :ok = Jobs.finish(uuid, [], jobs)
      assert call(:delete, "/jobs/#{uuid}").status == 200
      assert call(:get, "/jobs/#{uuid}").status == 404
      assert call(:delete, "/jobs/#{uuid}").status == 404
    end
  end

  describe "POST /jobs/options and /jobs/reset" do
    test "options stores ignore_conditions; reset restores []", %{jobs: jobs} do
      conn = call(:post, "/jobs/options", %{"ignore_conditions" => ["healthy"]})
      assert conn.status == 200
      assert Jobs.info(jobs).ignore_conditions == ["healthy"]

      # Absent key = "change nothing", matching upstream's optional schema.
      assert call(:post, "/jobs/options", %{}).status == 200
      assert Jobs.info(jobs).ignore_conditions == ["healthy"]

      assert call(:post, "/jobs/reset").status == 200
      assert Jobs.info(jobs).ignore_conditions == []
    end

    test "a malformed ignore_conditions is a 400" do
      conn = call(:post, "/jobs/options", %{"ignore_conditions" => "healthy"})
      assert conn.status == 400

      conn = call(:post, "/jobs/options", %{"ignore_conditions" => [1, 2]})
      assert conn.status == 400
    end
  end
end
