defmodule Vagus.API.OSUpdateRouterTest.StubUpdater do
  @moduledoc false
  # Router seam target (`config :vagus, :os_updater_mod`) for
  # `Vagus.API.OSUpdateRouterTest` — swapped in for the real
  # `Vagus.OS.Updater`/`NervesGithubUpdater.Updater` so a test can force the
  # install poller's terminal branch on its very first `state/0` call. The
  # poller (`Vagus.API.Router.watch_os_install/3`) checks `:error`/`:idle`
  # BEFORE its `Process.sleep(2_000)`-then-recurse branch, so a fixed
  # terminal snapshot here never needs a second call or a real sleep.
  def state,
    do: Application.get_env(:vagus, :stub_os_updater_state, %{phase: :idle, last_error: nil})
end

defmodule Vagus.API.OSUpdateRouterTest do
  @moduledoc """
  `POST /os/update` (build-order #4): backend dispatch, the install
  poller's terminal states, the `os_manager_update` job wrapping
  (sync/background), version validation, and the HostStub honesty case
  (plan 4.3). Also extends `GET /os/info`'s backend-passthrough coverage
  (`Vagus.API.RouterBackendTest`) with the `version_latest`/
  `update_available` fields the update feature added.

  `async: false` + Mox global mode, same rationale/discipline as
  `Vagus.API.RouterBackendTest` (the doc there explains why: this module
  also calls `Mox.expect/3`, so it must never run concurrently with the
  async suite's default `stub_with/2` delegation). Also mutates
  `Application` env (`:jobs_server`, `:os_updater_mod`, `:os_backend`),
  restored in `on_exit`, same pattern as
  `Vagus.API.CoreLifecycleRouterTest`.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  import Mox

  alias Vagus.API.OSUpdateRouterTest.StubUpdater
  alias Vagus.API.{Router, Token}
  alias Vagus.Backend.OS.HostStub
  alias Vagus.Backend.OSMock
  alias Vagus.Jobs

  setup :set_mox_global
  setup :verify_on_exit!

  @opts Router.init([])

  setup do
    name = :"os_update_jobs_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({Jobs, name: name})

    prev_jobs = Application.get_env(:vagus, :jobs_server)
    prev_updater = Application.get_env(:vagus, :os_updater_mod)
    prev_backend = Application.get_env(:vagus, :os_backend)

    Application.put_env(:vagus, :jobs_server, name)

    on_exit(fn ->
      if prev_jobs,
        do: Application.put_env(:vagus, :jobs_server, prev_jobs),
        else: Application.delete_env(:vagus, :jobs_server)

      if prev_updater,
        do: Application.put_env(:vagus, :os_updater_mod, prev_updater),
        else: Application.delete_env(:vagus, :os_updater_mod)

      if prev_backend,
        do: Application.put_env(:vagus, :os_backend, prev_backend),
        else: Application.delete_env(:vagus, :os_backend)

      Application.delete_env(:vagus, :stub_os_updater_state)
    end)

    %{jobs: name}
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

  # Forces the install poller's terminal branch on its first `state/0` call
  # (see `StubUpdater`'s moduledoc) — used only by tests that need the
  # poller to observe something other than the default idle-reads-as-success
  # snapshot.
  defp stub_updater_state(state) do
    Application.put_env(:vagus, :os_updater_mod, StubUpdater)
    Application.put_env(:vagus, :stub_os_updater_state, state)
  end

  # The single root job a sync `/os/update` call creates, REST-shaped
  # (`Vagus.Jobs.info/1`) — avoids needing the job's uuid out-of-band since,
  # unlike `Vagus.API.CoreLifecycleRouterTest`'s stub lifecycle, the OSMock
  # `update/1` callback never receives the job id to echo back.
  defp only_job(jobs) do
    assert %{jobs: [job]} = Jobs.info(jobs)
    job
  end

  # Bounded poll for background-task completion, same idiom as
  # `Vagus.API.CoreLifecycleRouterTest.eventually/2`.
  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end

  ## -- happy path (sync) -------------------------------------------------------

  describe "POST /os/update happy path (sync)" do
    test "backend update -> :ok, updater idle (default, no server running) -> 200 ok envelope, job done with no errors",
         %{jobs: jobs} do
      expect(OSMock, :update, fn nil -> :ok end)

      conn = post_("/os/update")

      assert conn.status == 200
      assert json_body(conn) == %{"result" => "ok", "data" => %{}}

      job = only_job(jobs)
      assert job["name"] == "os_manager_update"
      assert job["done"] == true
      assert job["errors"] == []
    end

    test "a requested version matching the feed's latest is threaded to the backend", %{
      jobs: jobs
    } do
      expect(OSMock, :update, fn "0.4.0" -> :ok end)

      conn = post_("/os/update", %{"version" => "0.4.0"})

      assert conn.status == 200
      assert json_body(conn) == %{"result" => "ok", "data" => %{}}
      assert only_job(jobs)["done"] == true
    end
  end

  ## -- version validation (rejected before the backend is touched) ------------

  describe "POST /os/update version validation (rejected before the backend is touched)" do
    test "a non-string version -> 400, backend never called, no job created", %{jobs: jobs} do
      deny(OSMock, :update, 1)

      conn = post_("/os/update", %{"version" => 123})

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "string"
      assert Jobs.info(jobs).jobs == []
    end

    test "an empty body -> update(nil) is still called (absent version is valid)" do
      expect(OSMock, :update, fn nil -> :ok end)

      conn = post_("/os/update", %{})

      assert conn.status == 200
    end
  end

  ## -- background: true ---------------------------------------------------------

  describe "POST /os/update background: true" do
    test "returns {job_id} immediately and the job completes", %{jobs: jobs} do
      expect(OSMock, :update, fn nil -> :ok end)

      conn = post_("/os/update", %{"background" => true})

      assert conn.status == 200
      job_id = json_body(conn)["data"]["job_id"]
      assert job_id =~ ~r/\A[0-9a-f]{32}\z/

      assert eventually(fn -> match?({:ok, %{"done" => true}}, Jobs.get(job_id, jobs)) end)
      assert {:ok, %{"name" => "os_manager_update", "errors" => []}} = Jobs.get(job_id, jobs)
    end
  end

  ## -- install failure via the poller -------------------------------------------

  describe "POST /os/update install failure via the poller" do
    test "backend accepts, updater reports :error -> sync 400 \"install failed\", job done with an error",
         %{jobs: jobs} do
      expect(OSMock, :update, fn nil -> :ok end)
      stub_updater_state(%{phase: :error, last_error: :flash_write_failed})

      conn = post_("/os/update")

      assert conn.status == 400
      assert json_body(conn)["message"] =~ "install failed"

      job = only_job(jobs)
      assert job["done"] == true
      assert [error] = job["errors"]
      assert error["type"] == "HassOSUpdateError"
      assert error["message"] =~ "install failed"
    end
  end

  ## -- backend error mapping -----------------------------------------------------

  describe "POST /os/update backend error mapping" do
    @backend_errors [
      {:busy, 409, "already in progress"},
      {:no_release_cached, 409, "check for updates first"},
      {{:version_mismatch, "0.4.0"}, 400, "only the latest version (0.4.0)"},
      {{:insufficient_space, 200_000_000, 1_000_000}, 400, "not enough free disk space"},
      {:not_supported, 400, "not supported on this backend"}
    ]

    for {reason, status, substr} <- @backend_errors do
      test "#{inspect(reason)} -> #{status}, job done with a HassOSUpdateError entry", %{
        jobs: jobs
      } do
        expect(OSMock, :update, fn nil -> {:error, unquote(Macro.escape(reason))} end)

        conn = post_("/os/update")

        assert conn.status == unquote(status)
        assert json_body(conn)["message"] =~ unquote(substr)

        job = only_job(jobs)
        assert job["done"] == true
        assert [error] = job["errors"]
        assert error["type"] == "HassOSUpdateError"
        assert error["message"] =~ unquote(substr)
      end
    end
  end

  ## -- GET /os/info passthrough (version_latest/update_available) ---------------

  describe "GET /os/info calls the configured OS backend (version_latest/update_available)" do
    test "the wire response carries version/version_latest/update_available from the backend" do
      expect(OSMock, :info, fn ->
        %{
          version: "0.3.1",
          version_latest: "0.4.0",
          update_available: true,
          board: "test-board",
          boot: "A",
          data_disk: nil,
          boot_slots: %{}
        }
      end)

      conn = conn(:get, "/os/info") |> authed() |> call()

      assert conn.status == 200
      data = json_body(conn)["data"]
      assert data["version"] == "0.3.1"
      assert data["version_latest"] == "0.4.0"
      assert data["update_available"] == true
    end
  end

  ## -- HostStub honesty (plan 4.3) -----------------------------------------------

  describe "HostStub honesty (plan 4.3): os/update is not supported on the host backend" do
    test "POST /os/update against Vagus.Backend.OS.HostStub -> clean 400, not a crash", %{
      jobs: jobs
    } do
      Application.put_env(:vagus, :os_backend, HostStub)

      conn = post_("/os/update")

      assert conn.status == 400
      assert json_body(conn)["message"] == "os/update is not supported on this backend"

      job = only_job(jobs)
      assert job["done"] == true
      assert [error] = job["errors"]
      assert error["type"] == "HassOSUpdateError"
    end

    test "Vagus.Backend.OS.HostStub.update/1 is honestly :not_supported (unit-level)" do
      assert HostStub.update("x") == {:error, :not_supported}
    end

    test "Vagus.Backend.OS.HostStub.version_latest/0 returns the same KV version info/0 reports (unit-level)" do
      assert HostStub.version_latest() == HostStub.info().version_latest
    end
  end
end
