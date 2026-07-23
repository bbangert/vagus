defmodule Vagus.API.CoreLifecycleRouterTest.StubLifecycle do
  @moduledoc false
  # Router seam target (`config :vagus, :core_lifecycle`) for
  # `Vagus.API.CoreLifecycleRouterTest` — swapped in for the real
  # `Vagus.Core.Lifecycle`. Lifecycle's own hermetic tests
  # (`test/vagus/core/lifecycle_test.exs`, against the fake Docker socket)
  # already cover the real Engine-API behavior; this stub only needs to
  # prove the router calls the right op with the right args and maps
  # whatever comes back correctly.
  #
  # `respond/2` sends `{:core_lifecycle_call, op, opts}` to `self()` — since
  # `Plug.Test`/`Router.call/2` never spawns a separate process, `self()`
  # here IS the test process, so a test can `assert_received`/`refute_received`
  # without any mocking library. The reply itself comes from
  # `config :vagus, :stub_core_lifecycle_response` (a `%{op => reply}` map),
  # set per test via `stub_response/2` below.

  def start(opts \\ []), do: respond(:start, opts)
  def stop(opts \\ []), do: respond(:stop, opts)
  def restart(opts \\ []), do: respond(:restart, opts)
  def rebuild(opts \\ []), do: respond(:rebuild, opts)
  def update(version \\ nil, opts \\ []), do: respond(:update, [{:version, version} | opts])

  defp respond(op, opts) do
    send(self(), {:core_lifecycle_call, op, opts})

    :vagus
    |> Application.get_env(:stub_core_lifecycle_response, %{})
    |> Map.get(op, default_reply(op))
  end

  defp default_reply(:update), do: {:ok, "unset"}
  defp default_reply(_op), do: :ok
end

defmodule Vagus.API.CoreLifecycleRouterTest.StubHealth do
  @moduledoc false
  # Router seam target (`config :vagus, :core_health`) — same
  # self-messaging-stub shape as `StubLifecycle` above.
  def check(opts \\ []) do
    send(self(), {:core_health_call, opts})
    Application.get_env(:vagus, :stub_core_health_response, :healthy)
  end
end

defmodule Vagus.API.CoreLifecycleRouterTest do
  @moduledoc """
  CL-P3-T3: `POST /core/{start,stop,restart,rebuild,check,update}` +
  `/homeassistant/*` aliases (CL-P3-T1), and `GET /core/info`'s real
  `Vagus.Core.Versions`-backed fields (CL-P3-T2).

  `async: false` — every test mutates process-global `Application` env
  (`:core_lifecycle`, `:core_health`, `:core_versions_server`, the stub
  response maps), restored in `on_exit`.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.API.CoreLifecycleRouterTest.{StubHealth, StubLifecycle}
  alias Vagus.API.{Router, Token}
  alias Vagus.Core.Versions

  @opts Router.init([])

  @lifecycle_ops [
    start: "/core/start",
    stop: "/core/stop",
    restart: "/core/restart",
    rebuild: "/core/rebuild"
  ]

  setup do
    prev_lifecycle = Application.get_env(:vagus, :core_lifecycle)
    prev_health = Application.get_env(:vagus, :core_health)

    Application.put_env(:vagus, :core_lifecycle, StubLifecycle)
    Application.put_env(:vagus, :core_health, StubHealth)
    Application.put_env(:vagus, :stub_core_lifecycle_response, %{})
    Application.put_env(:vagus, :stub_core_health_response, :healthy)

    on_exit(fn ->
      if prev_lifecycle,
        do: Application.put_env(:vagus, :core_lifecycle, prev_lifecycle),
        else: Application.delete_env(:vagus, :core_lifecycle)

      if prev_health,
        do: Application.put_env(:vagus, :core_health, prev_health),
        else: Application.delete_env(:vagus, :core_health)

      Application.delete_env(:vagus, :stub_core_lifecycle_response)
      Application.delete_env(:vagus, :stub_core_health_response)
    end)

    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp req_json(conn), do: put_req_header(conn, "content-type", "application/json")
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp post_(path, body \\ nil) do
    conn = conn(:post, path, body && Jason.encode!(body))
    conn = if body, do: req_json(conn), else: conn
    conn |> authed() |> call()
  end

  defp stub_response(op, reply) do
    current = Application.get_env(:vagus, :stub_core_lifecycle_response, %{})
    Application.put_env(:vagus, :stub_core_lifecycle_response, Map.put(current, op, reply))
  end

  ## -- happy paths -----------------------------------------------------------

  describe "happy path" do
    for {op, path} <- @lifecycle_ops do
      test "POST #{path} -> ok envelope, calls Lifecycle.#{op}/1" do
        conn = post_(unquote(path))

        assert conn.status == 200
        assert json_body(conn) == %{"result" => "ok", "data" => %{}}
        assert_received {:core_lifecycle_call, unquote(op), _opts}
      end
    end

    test "POST /core/check (healthy) -> ok envelope" do
      conn = post_("/core/check")

      assert conn.status == 200
      assert json_body(conn) == %{"result" => "ok", "data" => %{}}
      assert_received {:core_health_call, _opts}
    end

    test "POST /core/update with no body -> update(nil), ok envelope with the returned version" do
      stub_response(:update, {:ok, "2026.7.3"})

      conn = post_("/core/update")

      assert conn.status == 200
      assert json_body(conn)["data"] == %{"version" => "2026.7.3"}
      assert_received {:core_lifecycle_call, :update, opts}
      assert Keyword.get(opts, :version) == nil
    end

    test "POST /core/update with a valid version -> update(version)" do
      stub_response(:update, {:ok, "2026.8.0"})

      conn = post_("/core/update", %{"version" => "2026.8.0"})

      assert conn.status == 200
      assert json_body(conn)["data"] == %{"version" => "2026.8.0"}
      assert_received {:core_lifecycle_call, :update, opts}
      assert Keyword.get(opts, :version) == "2026.8.0"
    end
  end

  ## -- /homeassistant/* aliases -----------------------------------------------

  describe "/homeassistant/* aliases" do
    for {op, core_path} <- @lifecycle_ops do
      alias_path = String.replace(core_path, "/core/", "/homeassistant/")

      test "POST #{alias_path} hits the same handler as #{core_path}" do
        conn = post_(unquote(alias_path))

        assert conn.status == 200
        assert_received {:core_lifecycle_call, unquote(op), _opts}
      end
    end

    test "POST /homeassistant/check hits StubHealth" do
      conn = post_("/homeassistant/check")
      assert conn.status == 200
      assert_received {:core_health_call, _opts}
    end

    test "POST /homeassistant/update hits StubLifecycle.update/2" do
      stub_response(:update, {:ok, "2026.7.4"})
      conn = post_("/homeassistant/update")

      assert conn.status == 200
      assert json_body(conn)["data"] == %{"version" => "2026.7.4"}
    end
  end

  ## -- POST /core/update version validation -----------------------------------

  describe "POST /core/update version validation (rejected before Lifecycle is touched)" do
    test "a non-string version -> 400" do
      conn = post_("/core/update", %{"version" => 123})

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "string"
      refute_received {:core_lifecycle_call, :update, _opts}
    end

    test "a path-traversal-shaped version -> 400" do
      conn = post_("/core/update", %{"version" => "../evil"})

      assert conn.status == 400
      refute_received {:core_lifecycle_call, :update, _opts}
    end

    test "a version containing whitespace -> 400" do
      conn = post_("/core/update", %{"version" => "a b"})

      assert conn.status == 400
      refute_received {:core_lifecycle_call, :update, _opts}
    end

    test "a version over the max length -> 400" do
      conn = post_("/core/update", %{"version" => String.duplicate("a", 129)})

      assert conn.status == 400
      refute_received {:core_lifecycle_call, :update, _opts}
    end

    test "an empty body -> update(nil) is still called (absent version is valid)" do
      stub_response(:update, {:ok, "2026.7.3"})
      conn = post_("/core/update", %{})

      assert conn.status == 200
      assert_received {:core_lifecycle_call, :update, opts}
      assert Keyword.get(opts, :version) == nil
    end
  end

  ## -- busy -> 409 -------------------------------------------------------------

  describe "busy -> 409 on every lifecycle route" do
    for {op, path} <- @lifecycle_ops do
      test "POST #{path} -> 409 when Lifecycle is busy" do
        stub_response(unquote(op), {:error, :busy})
        conn = post_(unquote(path))

        assert conn.status == 409
        assert json_body(conn)["message"] =~ "already in progress"
      end
    end

    test "POST /core/update -> 409 when Lifecycle is busy" do
      stub_response(:update, {:error, :busy})
      conn = post_("/core/update")

      assert conn.status == 409
      assert json_body(conn)["message"] =~ "already in progress"
    end
  end

  ## -- error mapping -----------------------------------------------------------

  describe "error mapping (non-busy lifecycle errors -> 400)" do
    test ":no_version -> 400" do
      stub_response(:rebuild, {:error, :no_version})
      conn = post_("/core/rebuild")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "No Core version"
    end

    test ":version_installed -> 400" do
      stub_response(:update, {:error, :version_installed})
      conn = post_("/core/update", %{"version" => "2026.7.2"})

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "already installed"
    end

    test "{:pull, reason} -> 400" do
      stub_response(:update, {:error, {:pull, :timeout}})
      conn = post_("/core/update")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "pull"
    end

    test "plain :health_timeout -> 400" do
      stub_response(:restart, {:error, :health_timeout})
      conn = post_("/core/restart")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "healthy"
    end

    test "{:health_timeout, :rolled_back} -> 400" do
      stub_response(:update, {:error, {:health_timeout, :rolled_back}})
      conn = post_("/core/update")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "rolled back"
    end

    test "{:health_timeout, :no_rollback_version} -> 400" do
      stub_response(:update, {:error, {:health_timeout, :no_rollback_version}})
      conn = post_("/core/update")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "no previous version"
    end

    test "{:rollback_failed, reason} -> 400" do
      stub_response(:update, {:error, {:rollback_failed, :boom}})
      conn = post_("/core/update")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "rollback also failed"
    end

    test "an unrecognized error term -> 400 with an inspected fallback message" do
      stub_response(:start, {:error, :something_weird})
      conn = post_("/core/start")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "something_weird"
    end

    test "POST /core/check unhealthy -> 400 error envelope" do
      Application.put_env(:vagus, :stub_core_health_response, :unhealthy)
      conn = post_("/core/check")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "probe failed"
    end
  end

  ## -- GET /core/info ----------------------------------------------------------

  describe "GET /core/info" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "vagus-core-lifecycle-rt-#{System.unique_integer([:positive])}.json"
        )

      name = :"core_versions_rt_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: name,
        start:
          {Versions, :start_link, [[name: name, path: path, fetch: fn -> {:error, :offline} end]]}
      })

      prev_server = Application.get_env(:vagus, :core_versions_server)
      Application.put_env(:vagus, :core_versions_server, name)

      on_exit(fn ->
        if prev_server,
          do: Application.put_env(:vagus, :core_versions_server, prev_server),
          else: Application.delete_env(:vagus, :core_versions_server)

        File.rm(path)
      end)

      %{versions: name}
    end

    test "reflects installed/latest/update_available from Vagus.Core.Versions", %{
      versions: versions
    } do
      :ok = Versions.set_installed("2026.7.0", versions)

      conn = conn(:get, "/core/info") |> authed() |> call()

      assert conn.status == 200
      data = json_body(conn)["data"]
      assert data["version"] == "2026.7.0"
      # no fetch stub configured to succeed -> latest stays nil, so
      # update_available is honestly false rather than erroring.
      assert data["version_latest"] == nil
      assert data["update_available"] == false
    end

    test "nothing installed yet -> version is nil (HomeAssistantInfo allows it)", %{
      versions: versions
    } do
      assert Versions.installed(versions) == nil

      conn = conn(:get, "/core/info") |> authed() |> call()

      assert conn.status == 200
      data = json_body(conn)["data"]
      assert data["version"] == nil
      assert data["update_available"] == false
    end

    test "an unauthenticated request -> 401" do
      conn = conn(:get, "/core/info") |> call()
      assert conn.status == 401
    end

    test "every other StaticData.core_info/0 field survives untouched", %{versions: versions} do
      :ok = Versions.set_installed("2026.7.0", versions)
      conn = conn(:get, "/core/info") |> authed() |> call()
      data = json_body(conn)["data"]

      assert data["image"] == "ghcr.io/home-assistant/home-assistant"
      assert data["port"] == 8123
      assert data["watchdog"] == true
    end
  end
end
