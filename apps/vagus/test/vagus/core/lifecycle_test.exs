defmodule Vagus.Core.LifecycleTest do
  @moduledoc """
  async: false — every test drives the real `:global` lock
  (`{:core_lifecycle, Vagus.Core.Container.name()}`, shared across the
  whole node) and a fake unix-socket daemon; running two of these
  concurrently would race the lock and collide on the shared key the same
  way `Vagus.Core.ContainerTest` avoids running concurrently with
  app-env-mutating tests.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.{Container, Lifecycle, Versions}
  alias Vagus.Test.FakeEngine

  ## Versions helper — a private, uniquely-named instance per test (same
  ## pattern as `versions_test.exs`'s `start_versions/1`), so seeding
  ## `Vagus.Core.Versions.installed/1` for one test can never bleed into
  ## another.

  defp start_versions(installed \\ nil) do
    path =
      Path.join(System.tmp_dir!(), "vagus_test_lifecycle_versions_#{unique()}.json")

    name = :"lifecycle_versions_#{unique()}"

    start_supervised!(%{
      id: name,
      start:
        {Versions, :start_link, [[name: name, path: path, fetch: fn -> {:error, :unused} end]]}
    })

    if installed, do: :ok = Versions.set_installed(installed, name)

    on_exit(fn -> File.rm(path) end)
    name
  end

  defp unique, do: System.unique_integer([:positive])

  # `opts[:homeassistant_path]` override for the safe-mode marker tests
  # below — a real writable dir standing in for the `vagus-core-config`
  # volume's host path, which only exists on target.
  defp tmp_config_dir do
    dir = Path.join(System.tmp_dir!(), "vagus_test_lifecycle_config_#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A path that doesn't exist yet (unlike `tmp_config_dir/0`) — for the
  # "mkdir_p creates a missing parent" tests. Not created here; the op
  # under test is expected to create it.
  defp tmp_uncreated_config_dir do
    dir = Path.join(System.tmp_dir!(), "vagus_test_lifecycle_uncreated_#{unique()}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A regular file standing where a directory needs to go — `File.mkdir_p/1`
  # fails on this (`:enotdir`) the same way it would on a real permissions
  # problem, so this is what now exercises the "abort on write failure"
  # path (a merely-missing parent is no longer a failure — W1).
  defp blocking_file do
    path = Path.join(System.tmp_dir!(), "vagus_test_lifecycle_blocking_#{unique()}")
    File.write!(path, "not a directory")
    on_exit(fn -> File.rm(path) end)
    path
  end

  ## Health gate helper — a zero-arity fn that also counts its own calls via
  ## message-passing back to the test process (no Agent needed for a single
  ## counter the test process itself owns and reads via `assert_receive`).

  defp health_fun(result \\ :healthy) do
    parent = self()

    fn ->
      send(parent, :health_called)
      result
    end
  end

  ## Fixture builders

  defp inspect_body(image, running, env \\ []) do
    %{
      "Id" => "existing-container-id",
      "Config" => %{"Image" => image, "Env" => env},
      "State" => %{"Running" => running}
    }
  end

  defp not_found, do: {404, %{"message" => "No such container: homeassistant"}}

  defp create_ok(id), do: {201, %{"Id" => id}}

  defp pull_ok, do: {200, "{\"status\":\"Pull complete\"}\n"}
  defp pull_error, do: {200, "{\"errorDetail\":{\"message\":\"no such image\"}}\n"}

  defp start_engine(responses) do
    engine = FakeEngine.start(responses)
    on_exit(fn -> FakeEngine.stop(engine) end)
    engine
  end

  ## Deterministic "has a request reached the fake daemon yet" wait, for
  ## tests that need to know a concurrent op is actually in flight (e.g.
  ## holding the lock) before issuing a competing call — a bounded poll on
  ## `FakeEngine.requests/1` instead of a fixed `Process.sleep/1` guess.
  defp wait_until_request_logged(engine, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case FakeEngine.requests(engine) do
      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Vagus.Test.FakeEngine: no request reached the fake daemon within 1s")
        else
          Process.sleep(10)
          wait_until_request_logged(engine, deadline)
        end

      _requests ->
        :ok
    end
  end

  ## adopt/1

  describe "adopt/1" do
    test "adopts an existing container by name and seeds Versions from its image tag" do
      engine = start_engine([{200, inspect_body(Container.image("2026.7.0"), true)}])
      versions = start_versions()

      assert {:adopted, info} =
               Lifecycle.adopt(docker: [socket: engine.socket], versions: versions)

      assert info["Config"]["Image"] == Container.image("2026.7.0")
      assert Versions.installed(versions) == "2026.7.0"

      # Never creates.
      refute Enum.any?(FakeEngine.requests(engine), &(&1.method == :post))
    end

    test "absent container -> :absent, no seed" do
      engine = start_engine([not_found()])
      versions = start_versions()

      assert :absent = Lifecycle.adopt(docker: [socket: engine.socket], versions: versions)
      assert Versions.installed(versions) == nil

      assert [%{method: :get, path: "/containers/homeassistant/json"}] =
               FakeEngine.requests(engine)
    end

    test "does not clobber an already-seeded version" do
      engine = start_engine([{200, inspect_body(Container.image("2026.9.0"), true)}])
      versions = start_versions("2026.1.0")

      assert {:adopted, _info} =
               Lifecycle.adopt(docker: [socket: engine.socket], versions: versions)

      assert Versions.installed(versions) == "2026.1.0"
    end

    test "an unparseable image tag skips seeding rather than erroring" do
      engine = start_engine([{200, inspect_body("homeassistant-no-tag", true)}])
      versions = start_versions()

      assert {:adopted, _info} =
               Lifecycle.adopt(docker: [socket: engine.socket], versions: versions)

      assert Versions.installed(versions) == nil
    end
  end

  ## start/1

  describe "start/1" do
    test "existing container, matching tag, stopped -> plain start (no create/remove) + health gate" do
      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.7.0"), false)},
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.start(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      assert_receive :health_called

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:get, :post]
      assert Enum.at(requests, 1).path == "/containers/homeassistant/start"
      refute Enum.any?(requests, &(&1.method == :delete))
    end

    test "existing container, already running -> :ok immediately, no health gate" do
      engine = start_engine([{200, inspect_body(Container.image("2026.7.0"), true)}])
      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.start(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      refute_receive :health_called, 100
      assert [%{method: :get}] = FakeEngine.requests(engine)
    end

    test "existing container, tag mismatch -> stop+remove+create+start (recreate)" do
      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.6.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("new-container-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.start(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      assert_receive :health_called

      requests = FakeEngine.requests(engine)

      assert Enum.map(requests, & &1.method) == [:get, :post, :delete, :post, :post]
      assert Enum.at(requests, 1).path == "/containers/homeassistant/stop"
      assert Enum.at(requests, 2).path == "/containers/homeassistant"
      assert Enum.at(requests, 3).path == "/containers/create"
      assert Enum.at(requests, 4).path == "/containers/new-container-id/start"
    end

    test "absent container -> create+start" do
      engine =
        start_engine([
          not_found(),
          create_ok("fresh-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.start(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      assert_receive :health_called

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:get, :post, :post]
      assert Enum.at(requests, 1).path == "/containers/create"
      assert Enum.at(requests, 1).query["name"] == "homeassistant"
      assert Enum.at(requests, 2).path == "/containers/fresh-id/start"
    end

    test "no installed/desired version -> {:error, :no_version}, no requests" do
      engine = start_engine([])
      versions = start_versions()

      assert {:error, :no_version} =
               Lifecycle.start(docker: [socket: engine.socket], versions: versions)

      assert FakeEngine.requests(engine) == []
    end

    test "health timeout after a recreate surfaces as {:error, :health_timeout}" do
      engine =
        start_engine([
          not_found(),
          create_ok("fresh-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert {:error, :health_timeout} =
               Lifecycle.start(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun(:timeout)
               )
    end
  end

  ## stop/1

  describe "stop/1" do
    test "uses the S6_SERVICES_GRACETIME-derived timeout and keeps the container" do
      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.7.0"), true, ["S6_SERVICES_GRACETIME=5000"])},
          {204, nil}
        ])

      assert :ok = Lifecycle.stop(docker: [socket: engine.socket])

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:get, :post]
      assert Enum.at(requests, 1).query["t"] == "25"
      refute Enum.any?(requests, &(&1.method == :delete))
    end

    test "falls back to 260s when the gracetime env is absent" do
      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.7.0"), true, [])},
          {204, nil}
        ])

      assert :ok = Lifecycle.stop(docker: [socket: engine.socket])
      assert Enum.at(FakeEngine.requests(engine), 1).query["t"] == "260"
    end

    test "falls back to 260s when the container can't be inspected" do
      engine = start_engine([not_found(), {204, nil}])

      assert :ok = Lifecycle.stop(docker: [socket: engine.socket])
      assert Enum.at(FakeEngine.requests(engine), 1).query["t"] == "260"
    end

    test "an already-stopped container (Docker 304) is :ok" do
      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.7.0"), false, [])},
          {304, nil}
        ])

      assert :ok = Lifecycle.stop(docker: [socket: engine.socket])
    end
  end

  ## restart/1

  describe "restart/1" do
    test "hits the restart endpoint, no create/remove, then the health gate" do
      engine = start_engine([{204, nil}])

      assert :ok = Lifecycle.restart(docker: [socket: engine.socket], health: health_fun())
      assert_receive :health_called

      assert [%{method: :post, path: "/containers/homeassistant/restart"}] =
               FakeEngine.requests(engine)
    end
  end

  ## rebuild/1

  describe "rebuild/1" do
    test "full stop/remove/create/start sequence, create body carries the parity spec" do
      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.6.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("rebuilt-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.rebuild(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      assert_receive :health_called

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:get, :post, :delete, :post, :post]

      create_req = Enum.at(requests, 3)
      assert create_req.path == "/containers/create"
      assert create_req.body["Image"] == Container.image("2026.7.0")
      assert create_req.body["HostConfig"]["Privileged"] == true
      assert create_req.body["HostConfig"]["OomScoreAdj"] == -300
    end

    test "absent container -> still create+start (an explicit op)" do
      engine =
        start_engine([
          not_found(),
          {204, nil},
          create_ok("rebuilt-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.rebuild(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      assert_receive :health_called
      assert Enum.map(FakeEngine.requests(engine), & &1.method) == [:get, :delete, :post, :post]
    end

    test "no installed version -> {:error, :no_version}, no requests" do
      engine = start_engine([])
      versions = start_versions()

      assert {:error, :no_version} =
               Lifecycle.rebuild(docker: [socket: engine.socket], versions: versions)

      assert FakeEngine.requests(engine) == []
    end
  end

  ## safe_mode marker (audit E3) — restart/1 and rebuild/1

  describe "restart/1 safe_mode marker" do
    test "safe_mode: true touches an empty safe-mode file before the restart request" do
      dir = tmp_config_dir()
      engine = start_engine([{204, nil}])

      assert :ok =
               Lifecycle.restart(
                 docker: [socket: engine.socket],
                 health: health_fun(),
                 safe_mode: true,
                 homeassistant_path: dir
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""

      assert [%{method: :post, path: "/containers/homeassistant/restart"}] =
               FakeEngine.requests(engine)
    end

    test "safe_mode: false (the default) never touches the marker" do
      dir = tmp_config_dir()
      engine = start_engine([{204, nil}])

      assert :ok = Lifecycle.restart(docker: [socket: engine.socket], health: health_fun())
      assert_receive :health_called
      refute File.exists?(Path.join(dir, "safe-mode"))
    end

    test "a nonexistent parent dir is created (W1) and the marker lands" do
      dir = tmp_uncreated_config_dir()
      refute File.exists?(dir)
      engine = start_engine([{204, nil}])

      assert :ok =
               Lifecycle.restart(
                 docker: [socket: engine.socket],
                 health: health_fun(),
                 safe_mode: true,
                 homeassistant_path: dir
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
    end

    test "a marker write failure aborts the restart before any Engine-API call reaches the daemon" do
      blocking = blocking_file()
      engine = start_engine([{204, nil}])

      assert {:error, {:safe_mode_marker, _reason}} =
               Lifecycle.restart(
                 docker: [socket: engine.socket],
                 safe_mode: true,
                 homeassistant_path: blocking
               )

      assert FakeEngine.requests(engine) == []
    end
  end

  describe "rebuild/1 safe_mode marker" do
    test "safe_mode: true touches the marker after the version resolves, before stop/remove/create" do
      dir = tmp_config_dir()

      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.6.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("rebuilt-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.rebuild(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun(),
                 safe_mode: true,
                 homeassistant_path: dir
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
    end

    test "no installed version -> {:error, :no_version}, marker never written" do
      dir = tmp_config_dir()
      engine = start_engine([])
      versions = start_versions()

      assert {:error, :no_version} =
               Lifecycle.rebuild(
                 docker: [socket: engine.socket],
                 versions: versions,
                 safe_mode: true,
                 homeassistant_path: dir
               )

      refute File.exists?(Path.join(dir, "safe-mode"))
      assert FakeEngine.requests(engine) == []
    end

    test "a nonexistent parent dir is created (W1) and the marker lands" do
      dir = tmp_uncreated_config_dir()
      refute File.exists?(dir)

      engine =
        start_engine([
          {200, inspect_body(Container.image("2026.6.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("rebuilt-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert :ok =
               Lifecycle.rebuild(
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun(),
                 safe_mode: true,
                 homeassistant_path: dir
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
    end

    test "a marker write failure aborts before stop/remove/create reach the daemon" do
      blocking = blocking_file()
      engine = start_engine([{200, inspect_body(Container.image("2026.6.0"), true)}])
      versions = start_versions("2026.7.0")

      assert {:error, {:safe_mode_marker, _reason}} =
               Lifecycle.rebuild(
                 docker: [socket: engine.socket],
                 versions: versions,
                 safe_mode: true,
                 homeassistant_path: blocking
               )

      assert FakeEngine.requests(engine) == []
    end
  end

  ## update/2

  describe "update/2" do
    test "happy path: pull -> stop/remove/create/start -> health -> set_installed, {:ok, target}" do
      engine =
        start_engine([
          pull_ok(),
          {200, inspect_body(Container.image("2026.7.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("updated-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert {:ok, "2026.8.0"} =
               Lifecycle.update("2026.8.0",
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      assert_receive :health_called
      assert Versions.installed(versions) == "2026.8.0"

      requests = FakeEngine.requests(engine)
      assert Enum.map(requests, & &1.method) == [:post, :get, :post, :delete, :post, :post]
      assert Enum.at(requests, 0).path == "/images/create"
      assert Enum.at(requests, 4).body["Image"] == Container.image("2026.8.0")
    end

    test "pull failure leaves the old Core untouched" do
      engine = start_engine([pull_error()])
      versions = start_versions("2026.7.0")

      assert {:error, {:pull, _reason}} =
               Lifecycle.update("2026.8.0", docker: [socket: engine.socket], versions: versions)

      assert Versions.installed(versions) == "2026.7.0"
      assert [%{method: :post, path: "/images/create"}] = FakeEngine.requests(engine)
    end

    test "health-gate timeout rolls back to the previous version" do
      engine =
        start_engine([
          pull_ok(),
          {200, inspect_body(Container.image("2026.7.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("updated-id"),
          {204, nil},
          # rollback sequence
          {204, nil},
          {204, nil},
          create_ok("rollback-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert {:error, {:health_timeout, :rolled_back}} =
               Lifecycle.update("2026.8.0",
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun(:timeout)
               )

      assert Versions.installed(versions) == "2026.7.0"

      requests = FakeEngine.requests(engine)

      assert Enum.map(requests, & &1.method) == [
               :post,
               :get,
               :post,
               :delete,
               :post,
               :post,
               :post,
               :delete,
               :post,
               :post
             ]

      rollback_create = Enum.at(requests, 8)
      assert rollback_create.path == "/containers/create"
      assert rollback_create.body["Image"] == Container.image("2026.7.0")
    end

    test "health-gate timeout, and the rollback recreate itself fails -> {:error, {:rollback_failed, _}}" do
      engine =
        start_engine([
          pull_ok(),
          {200, inspect_body(Container.image("2026.7.0"), true)},
          {204, nil},
          {204, nil},
          create_ok("updated-id"),
          {204, nil},
          # rollback sequence: stop+remove the failed new container, then
          # the recreate of the previous version fails (e.g. its image was
          # pruned meanwhile).
          {204, nil},
          {204, nil},
          {404, %{"message" => "No such image: home-assistant:2026.7.0"}}
        ])

      versions = start_versions("2026.7.0")

      assert {:error, {:rollback_failed, _reason}} =
               Lifecycle.update("2026.8.0",
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun(:timeout)
               )

      # set_installed already recorded the new (now-broken) version before
      # the health gate ran; the rollback recreate failing means it never
      # gets set back.
      assert Versions.installed(versions) == "2026.8.0"

      requests = FakeEngine.requests(engine)

      assert Enum.map(requests, & &1.method) == [
               :post,
               :get,
               :post,
               :delete,
               :post,
               :post,
               :post,
               :delete,
               :post
             ]

      rollback_create = Enum.at(requests, 8)
      assert rollback_create.path == "/containers/create"
      assert rollback_create.body["Image"] == Container.image("2026.7.0")
    end

    test "new-container create fails after the old one was removed -> rollback recreate succeeds" do
      engine =
        start_engine([
          pull_ok(),
          {200, inspect_body(Container.image("2026.7.0"), true)},
          {204, nil},
          {204, nil},
          # the new container's create fails outright — it was never
          # created, so the rollback recreate below skips straight to
          # create+start of the previous version (nothing to remove).
          {404, %{"message" => "No such image: home-assistant:2026.8.0"}},
          create_ok("rollback-id"),
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert {:error, {:recreate_failed, _reason, :rolled_back}} =
               Lifecycle.update("2026.8.0",
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      refute_receive :health_called, 100
      assert Versions.installed(versions) == "2026.7.0"

      requests = FakeEngine.requests(engine)

      assert Enum.map(requests, & &1.method) == [
               :post,
               :get,
               :post,
               :delete,
               :post,
               :post,
               :post
             ]

      rollback_create = Enum.at(requests, 5)
      assert rollback_create.path == "/containers/create"
      assert rollback_create.body["Image"] == Container.image("2026.7.0")
      assert Enum.at(requests, 6).path == "/containers/rollback-id/start"
    end

    test "same-version update -> {:error, :version_installed}, no requests" do
      engine = start_engine([])
      versions = start_versions("2026.7.0")

      assert {:error, :version_installed} =
               Lifecycle.update("2026.7.0", docker: [socket: engine.socket], versions: versions)

      assert FakeEngine.requests(engine) == []
    end

    test "not-running update swaps image+version with no start and no health gate" do
      engine =
        start_engine([
          pull_ok(),
          {200, inspect_body(Container.image("2026.7.0"), false)},
          {204, nil},
          {204, nil}
        ])

      versions = start_versions("2026.7.0")

      assert {:ok, "2026.8.0"} =
               Lifecycle.update("2026.8.0",
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      refute_receive :health_called, 100
      assert Versions.installed(versions) == "2026.8.0"
      assert Enum.map(FakeEngine.requests(engine), & &1.method) == [:post, :get, :post, :delete]
    end

    test "no container at all -> just records the new version, no health gate" do
      engine = start_engine([pull_ok(), not_found()])
      versions = start_versions("2026.7.0")

      assert {:ok, "2026.8.0"} =
               Lifecycle.update("2026.8.0",
                 docker: [socket: engine.socket],
                 versions: versions,
                 health: health_fun()
               )

      refute_receive :health_called, 100
      assert Versions.installed(versions) == "2026.8.0"
      assert Enum.map(FakeEngine.requests(engine), & &1.method) == [:post, :get]
    end

    test "no target version resolvable -> {:error, :no_version}, no requests" do
      engine = start_engine([])
      versions = start_versions("2026.7.0")

      assert {:error, :no_version} =
               Lifecycle.update(nil, docker: [socket: engine.socket], versions: versions)

      assert FakeEngine.requests(engine) == []
    end
  end

  ## Serialization

  describe "the single non-blocking lock" do
    test "a second op returns {:error, :busy} while another op holds the lock" do
      parent = self()
      # `Lifecycle.adopt/1` holds the lock for its whole locked body,
      # including the blocked Engine-API round trip — a stalling fake
      # response keeps that request (and therefore the lock) in flight long
      # enough to prove the second, concurrent op is rejected rather than
      # queued.
      engine =
        start_engine([{200, inspect_body(Container.image("2026.7.0"), true), [delay: 300]}])

      task =
        Task.async(fn ->
          send(parent, :task_started)
          Lifecycle.adopt(docker: [socket: engine.socket])
        end)

      assert_receive :task_started, 1_000
      # Wait for the task's request to actually reach the fake daemon (and
      # therefore for the lock to actually be held) before firing the
      # competing call — deterministic and immune to scheduler jitter,
      # unlike a fixed sleep racing the same 300ms delay below.
      wait_until_request_logged(engine)

      assert {:error, :busy} = Lifecycle.stop(docker: [socket: engine.socket])

      assert {:adopted, _info} = Task.await(task, 1_000)
    end
  end
end
