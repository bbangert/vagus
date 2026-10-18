defmodule Vagus.Core.LifecycleTest do
  @moduledoc """
  async: false — every test drives the real `:global` lock
  (`{:core_lifecycle, Vagus.Core.Container.name()}`, shared across the
  whole node); running two of these
  concurrently would race the lock and collide on the shared key the same
  way `Vagus.Core.ContainerTest` avoids running concurrently with
  app-env-mutating tests.
  """
  use ExUnit.Case, async: false

  alias Vagus.Core.{Container, Lifecycle, Versions}
  alias Vagus.Runtime.Engine.Fake

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

  # The A4 `Vagus.Core.HttpConfig.refresh/1` seam — `{:skipped, :no_socket}`
  # is what the real one returns on the TCP fallback the suite runs under.
  defp http_config_fun(result \\ {:skipped, :no_socket}) do
    parent = self()

    fn ->
      send(parent, :http_config_refreshed)
      result
    end
  end

  defp fingerprint_label, do: Container.spec_fingerprint_label()

  defp fingerprint(version),
    do: Container.to_container_spec(version).labels[fingerprint_label()]

  # A Core container with no spec drift unless `attrs` says otherwise.
  defp core(version, state, attrs \\ []) do
    Keyword.merge(
      [
        id: "existing-container-id",
        image: Container.image(version),
        state: state,
        labels: %{fingerprint_label() => fingerprint(version)},
        env: %{}
      ],
      attrs
    )
  end

  # `images` are the Core versions whose image the engine already holds.
  defp engine(core_attrs \\ nil, images \\ []) do
    fake = Fake.start()
    if core_attrs, do: Fake.put_container(fake, Container.name(), core_attrs)
    for version <- images, do: Fake.put_image(fake, Container.image(version))
    {fake, [engine_opts: [engine: Fake, fake: fake]]}
  end

  defp verbs(fake), do: Enum.map(Fake.calls(fake), &elem(&1, 0))

  defp stop_timeouts(fake), do: for({:stop, opts} <- Fake.call_opts(fake), do: opts[:timeout_s])

  defp creates(fake), do: for({:create, [spec]} <- Fake.calls(fake), do: spec)

  # The container a `start` targeted is the one the last create made.
  defp assert_started_created(fake, opts) do
    assert {:start, [id]} = List.last(Fake.calls(fake))
    assert {:ok, %{id: ^id}} = Vagus.Runtime.Engine.inspect(Container.name(), opts[:engine_opts])
  end

  ## adopt/1

  describe "adopt/1" do
    test "adopts an existing container by name and seeds Versions from its image tag" do
      {fake, opts} = engine(core("2026.7.0", :running))
      versions = start_versions()

      assert {:adopted, info} = Lifecycle.adopt(opts ++ [versions: versions])
      assert info.image == Container.image("2026.7.0")
      assert Versions.installed(versions) == "2026.7.0"

      # Never creates.
      assert verbs(fake) == [:inspect]
    end

    test "absent container -> :absent, no seed" do
      {fake, opts} = engine()
      versions = start_versions()

      assert :absent = Lifecycle.adopt(opts ++ [versions: versions])
      assert Versions.installed(versions) == nil
      assert Fake.calls(fake) == [{:inspect, [Container.name()]}]
    end

    test "does not clobber an already-seeded version" do
      {_fake, opts} = engine(core("2026.9.0", :running))
      versions = start_versions("2026.1.0")

      assert {:adopted, _info} = Lifecycle.adopt(opts ++ [versions: versions])
      assert Versions.installed(versions) == "2026.1.0"
    end

    test "an unparseable image tag skips seeding rather than erroring" do
      {_fake, opts} = engine(core("2026.7.0", :running, image: "homeassistant-no-tag"))
      versions = start_versions()

      assert {:adopted, _info} = Lifecycle.adopt(opts ++ [versions: versions])
      assert Versions.installed(versions) == nil
    end
  end

  describe "stops/0 and start/1's :stops_seen" do
    test "a stop counts, and a start that saw an earlier count is refused under the lock" do
      {fake, opts} = engine(core("2026.7.0", :running), ["2026.7.0"])
      opts = opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
      seen = Lifecycle.stops()

      assert :ok = Lifecycle.stop(opts)
      assert Lifecycle.stops() == seen + 1

      assert {:error, :stopped} = Lifecycle.start([stops_seen: seen] ++ opts)
      assert List.last(verbs(fake)) == :stop

      assert :ok = Lifecycle.start([stops_seen: seen + 1] ++ opts)
      assert List.last(verbs(fake)) == :start
    end

    test "a guarded start is refused while a shutdown is in flight; a plain one is not" do
      {fake, opts} = engine(nil, ["2026.7.0"])
      opts = opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
      shutting_down = [shutting_down?: fn -> true end]

      assert {:error, :shutting_down} =
               Lifecycle.start([stops_seen: Lifecycle.stops()] ++ shutting_down ++ opts)

      assert Fake.calls(fake) == []
      assert :ok = Lifecycle.start(shutting_down ++ opts)
      assert :create in verbs(fake)
    end

    test "a Core pull that finishes once a shutdown is in flight creates nothing" do
      {fake, opts} = engine(nil, ["2026.7.0"])
      in_flight = :atomics.new(1, [])
      parent = self()

      opts =
        opts ++
          [
            versions: start_versions("2026.7.0"),
            health: health_fun(),
            shutting_down?: fn -> :atomics.get(in_flight, 1) == 1 end
          ]

      prev = Application.fetch_env(:vagus, :first_boot_provision)
      Application.put_env(:vagus, :first_boot_provision, true)

      on_exit(fn ->
        case prev do
          {:ok, value} -> Application.put_env(:vagus, :first_boot_provision, value)
          :error -> Application.delete_env(:vagus, :first_boot_provision)
        end
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({Vagus.Provisioner,
         steps: [:provision_core],
         installed: fn -> "2026.7.0" end,
         ping: fn -> :ok end,
         image_present: fn _version -> false end,
         connection: fn -> :internet end,
         pull: fn _version ->
           # The shutdown begins mid-pull, before its Core stop has run;
           # that stop, Core absent, would end the recovery on its own.
           :atomics.put(in_flight, 1, 1)
           :ok
         end,
         start: fn seen ->
           result = Lifecycle.start([stops_seen: seen] ++ opts)
           send(parent, {:started, result})
           result
         end,
         name: nil})

        assert_receive {:started, {:error, :shutting_down}}, 2_000
      end)

      refute :create in verbs(fake)
    end

    test "a stop of an absent Core counts, its answer unchanged; one the engine fails does not" do
      {fake, opts} = engine()
      seen = Lifecycle.stops()
      assert {:error, :not_found} = Lifecycle.stop(opts)
      assert Lifecycle.stops() == seen + 1

      Fake.put_container(fake, Container.name(), core("2026.7.0", :running))
      Fake.fail_next(fake, :stop, {:failed, :stop, "boom"})
      assert {:error, {:failed, :stop, "boom"}} = Lifecycle.stop(opts)
      assert Lifecycle.stops() == seen + 1
    end

    test "a user stop while Core is absent cancels the recovery: the pull's start creates nothing" do
      {fake, opts} = engine(nil, ["2026.7.0"])
      opts = opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
      parent = self()

      prev = Application.fetch_env(:vagus, :first_boot_provision)
      Application.put_env(:vagus, :first_boot_provision, true)

      on_exit(fn ->
        case prev do
          {:ok, value} -> Application.put_env(:vagus, :first_boot_provision, value)
          :error -> Application.delete_env(:vagus, :first_boot_provision)
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pid =
            start_supervised!({Vagus.Provisioner,
             steps: [:provision_core],
             installed: fn -> "2026.7.0" end,
             ping: fn -> :ok end,
             image_present: fn _version -> false end,
             connection: fn -> :internet end,
             pull: fn _version ->
               # The user's POST /core/stop, with Core absent, mid-pull.
               send(parent, {:stopped, Lifecycle.stop(opts)})
               :ok
             end,
             start: fn seen ->
               result = Lifecycle.start([stops_seen: seen] ++ opts)
               send(parent, {:started, result})
               result
             end,
             name: nil})

          assert_receive {:stopped, {:error, :not_found}}, 2_000
          # The pull and the start it leads to run in one handler.
          :sys.get_state(pid)
          refute_received {:started, _}
        end)

      assert log =~ "not starting it"
      refute :create in verbs(fake)
    end
  end

  describe "image_present?/2 and pull/2" do
    test "ask about and pull the given version's image, touching no container or version" do
      {fake, opts} = engine(nil, ["2026.7.0"])
      versions = start_versions("2026.7.0")
      opts = opts ++ [versions: versions]

      assert Lifecycle.image_present?("2026.7.0", opts)
      refute Lifecycle.image_present?("2026.10.1", opts)
      assert :ok = Lifecycle.pull("2026.10.1", opts)
      assert Lifecycle.image_present?("2026.10.1", opts)
      assert verbs(fake) == [:image_present?, :image_present?, :pull, :image_present?]
      assert Versions.installed(versions) == "2026.7.0"
    end

    test "a failed pull is {:pull, reason}" do
      {fake, opts} = engine()
      Fake.fail_next(fake, :pull, {:pull_failed, "manifest unknown"})

      assert {:error, {:pull, {:pull_failed, "manifest unknown"}}} =
               Lifecycle.pull("2026.10.1", opts)
    end
  end

  # Boot's Core unit over the real lifecycle: under a transient store the
  # container is gone after every reboot, and the installed version brings it back.
  describe "Vagus.App.CoreUnit.start/1 on an absent container" do
    test "creates and starts it from the installed version" do
      {fake, opts} = engine(nil, ["2026.7.0"])
      versions = start_versions("2026.7.0")
      opts = opts ++ [versions: versions, health: health_fun(), http_config: http_config_fun()]

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Vagus.App.CoreUnit.start(
                   adopt: fn -> Lifecycle.adopt(opts) end,
                   installed: fn -> Versions.installed(versions) end,
                   image_present?: &Lifecycle.image_present?(&1, opts),
                   start: fn -> Lifecycle.start(opts) end,
                   health: fn _opts -> :healthy end
                 )
      end)

      assert verbs(fake) == [:inspect, :image_present?, :inspect, :create, :start]
      assert {:ok, %{state: :running}} = Fake.inspect(Container.name(), opts[:engine_opts])
    end

    test "a stop that lands after boot's reading keeps Core from being created" do
      {fake, opts} = engine(core("2026.7.0", :exited), ["2026.7.0"])
      versions = start_versions("2026.7.0")
      opts = opts ++ [versions: versions, health: health_fun()]
      parent = self()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :stopped} =
                 Vagus.App.CoreUnit.start(
                   adopt: fn -> :absent end,
                   installed: fn -> Versions.installed(versions) end,
                   image_present?: fn _version -> true end,
                   stops: fn ->
                     seen = Lifecycle.stops()
                     # The user's POST /core/stop, between the reading and the start.
                     :ok = Lifecycle.stop(opts)
                     seen
                   end,
                   start: &Lifecycle.start([stops_seen: &1] ++ opts),
                   retry: fn seen -> send(parent, {:handed_off, seen}) end
                 )
      end)

      assert verbs(fake) == [:inspect, :stop]
      refute_received {:handed_off, _seen}
    end

    test "leaves it absent, and creates nothing, when the image is gone too" do
      {fake, opts} = engine()
      versions = start_versions("2026.7.0")
      opts = opts ++ [versions: versions]

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Vagus.App.CoreUnit.start(
                   adopt: fn -> Lifecycle.adopt(opts) end,
                   installed: fn -> Versions.installed(versions) end,
                   image_present?: &Lifecycle.image_present?(&1, opts),
                   start: fn -> Lifecycle.start(opts) end
                 )
      end)

      assert verbs(fake) == [:inspect, :image_present?]
    end
  end

  ## start/1

  describe "start/1" do
    test "existing container, matching tag, stopped -> plain start (no create/remove) + health gate" do
      {fake, opts} = engine(core("2026.7.0", :exited))

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert_receive :health_called
      assert Fake.calls(fake) == [{:inspect, [Container.name()]}, {:start, [Container.name()]}]
    end

    test "existing container, already running -> :ok immediately, no health gate" do
      {fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      refute_receive :health_called, 100
      assert verbs(fake) == [:inspect]
    end

    # Docker's State.Running stays true for a paused Core, the hung-Core case.
    test "a paused or restarting container counts as running -> :ok, no start" do
      for state <- [:paused, :restarting] do
        {fake, opts} = engine(core("2026.7.0", state))

        assert :ok =
                 Lifecycle.start(
                   opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
                 )

        refute_receive :health_called, 100
        assert verbs(fake) == [:inspect]
      end
    end

    test "existing container, tag mismatch -> stop+remove+create+start (recreate)" do
      {fake, opts} = engine(core("2026.6.0", :running), ["2026.7.0"])

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert_receive :health_called
      assert verbs(fake) == [:inspect, :stop, :remove, :create, :start]
      assert [%{image: image}] = creates(fake)
      assert image == Container.image("2026.7.0")
      assert_started_created(fake, opts)
    end

    test "absent container -> create+start" do
      {fake, opts} = engine(nil, ["2026.7.0"])

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert_receive :health_called
      assert verbs(fake) == [:inspect, :create, :start]
      assert [%{name: "homeassistant"}] = creates(fake)
      assert_started_created(fake, opts)
    end

    test "a missing image surfaces as the create error, with no pull" do
      {fake, opts} = engine()

      assert {:error, {:failed, :create, :image_not_found}} =
               Lifecycle.start(opts ++ [versions: start_versions("2026.7.0")])

      assert verbs(fake) == [:inspect, :create]
    end

    test "no installed/desired version -> {:error, :no_version}, no engine calls" do
      {fake, opts} = engine()

      assert {:error, :no_version} = Lifecycle.start(opts ++ [versions: start_versions()])
      assert Fake.calls(fake) == []
    end

    test "health timeout after a recreate surfaces as {:error, :health_timeout}" do
      {_fake, opts} = engine(nil, ["2026.7.0"])

      assert {:error, :health_timeout} =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun(:timeout)]
               )
    end
  end

  ## start/1 spec-fingerprint drift (A1) — the reuse check is image tag AND
  ## the `io.vagus.spec-fingerprint` label, so an env/mount change in
  ## `Vagus.Core.Container` recreates the container the same way a version
  ## bump does.

  describe "start/1 spec fingerprint" do
    test "matching tag + matching fingerprint, running -> :ok, no recreate" do
      {fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert verbs(fake) == [:inspect]
    end

    for {label, labels} <- [
          drifted: %{"io.vagus.spec-fingerprint" => "0000000000000000000000000000stale"},
          missing: %{},
          no_labels_at_all: nil
        ] do
      @tag labels: labels
      test "a #{label} fingerprint on a running container -> stop+remove+create+start", ctx do
        {fake, opts} = engine(core("2026.7.0", :running, labels: ctx.labels), ["2026.7.0"])

        assert :ok =
                 Lifecycle.start(
                   opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
                 )

        assert_receive :health_called
        assert verbs(fake) == [:inspect, :stop, :remove, :create, :start]
        assert_started_created(fake, opts)
      end
    end

    test "a drifted-but-stopped container is recreated, not plain-started" do
      {fake, opts} = engine(core("2026.7.0", :exited, labels: %{}), ["2026.7.0"])

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert verbs(fake) == [:inspect, :stop, :remove, :create, :start]
    end

    test "the created container carries the fingerprint label + socket mount/env" do
      {fake, opts} = engine(nil, ["2026.7.0"])

      assert :ok =
               Lifecycle.start(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert [spec] = creates(fake)
      assert spec.labels[fingerprint_label()] == fingerprint("2026.7.0")
      assert {"SUPERVISOR_CORE_API_SOCKET", Container.socket_path()} in spec.env

      assert %{
               type: :bind,
               source: Container.socket_dir(),
               target: Container.socket_dir(),
               read_only: false
             } in spec.mounts
    end
  end

  ## stop/1

  describe "stop/1" do
    test "uses the S6_SERVICES_GRACETIME-derived timeout and keeps the container" do
      {fake, opts} =
        engine(core("2026.7.0", :running, env: %{"S6_SERVICES_GRACETIME" => "5000"}))

      assert :ok = Lifecycle.stop(opts)
      assert verbs(fake) == [:inspect, :stop]
      assert stop_timeouts(fake) == [25]
    end

    test "falls back to 260s when the gracetime env is absent" do
      {fake, opts} = engine(core("2026.7.0", :running))

      assert :ok = Lifecycle.stop(opts)
      assert stop_timeouts(fake) == [260]
    end

    test "falls back to 260s when the container can't be inspected" do
      {fake, opts} = engine(core("2026.7.0", :running))
      Fake.fail_next(fake, :inspect, :unavailable)

      assert :ok = Lifecycle.stop(opts)
      assert stop_timeouts(fake) == [260]
    end

    # The stop still goes out (the fallback timeout), and its not-found is
    # the op's answer, as the engine's 404 was before.
    test "an absent container fails the stop with :not_found" do
      {fake, opts} = engine()

      assert {:error, :not_found} = Lifecycle.stop(opts)
      assert stop_timeouts(fake) == [260]
    end

    test "an already-stopped container is :ok" do
      {_fake, opts} = engine(core("2026.7.0", :exited))
      assert :ok = Lifecycle.stop(opts)
    end
  end

  ## The socket file outlives Core (W1)

  describe "the Supervisor↔Core socket is unlinked when Core stops or is removed" do
    setup do
      prev = Application.get_env(:vagus, :core_socket_path)
      on_exit(fn -> Application.put_env(:vagus, :core_socket_path, prev) end)
      :ok
    end

    # A real AF_UNIX socket, left behind exactly as a dead Core leaves its
    # own: closing the listener does not unlink the file.
    defp stale_core_socket do
      path = Path.join(System.tmp_dir!(), "vagus_lifecycle_core_#{unique()}.sock")
      {:ok, listen} = :gen_tcp.listen(0, ifaddr: {:local, path})
      :gen_tcp.close(listen)
      on_exit(fn -> File.rm(path) end)

      Application.put_env(:vagus, :core_socket_path, path)
      path
    end

    test "stop/1 removes it, so the transport stops resolving a dead endpoint" do
      path = stale_core_socket()
      assert Vagus.Core.Transport.current() == {:socket, path}

      {_fake, opts} = engine(core("2026.7.0", :running))
      assert :ok = Lifecycle.stop(opts)

      refute File.exists?(path)
      assert {:tcp, _base_url} = Vagus.Core.Transport.current()
    end

    test "a failed stop leaves it alone — Core is still running" do
      path = stale_core_socket()
      {fake, opts} = engine(core("2026.7.0", :running))
      Fake.fail_next(fake, :stop, {:failed, :stop, "boom"})

      assert {:error, {:failed, :stop, "boom"}} = Lifecycle.stop(opts)
      assert File.exists?(path)
    end

    test "rebuild/1's remove takes it too (the container that owned it is gone)" do
      path = stale_core_socket()
      {_fake, opts} = engine(core("2026.6.0", :running), ["2026.7.0"])

      assert :ok =
               Lifecycle.rebuild(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     http_config: http_config_fun()
                   ]
               )

      refute File.exists?(path)
    end

    test "an unset :core_socket_path is a no-op, not a crash" do
      Application.put_env(:vagus, :core_socket_path, nil)
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok = Lifecycle.stop(opts)
    end
  end

  ## restart/1

  describe "restart/1" do
    test "restarts in place, no create/remove, then the health gate" do
      {fake, opts} = engine(core("2026.7.0", :running))

      assert :ok = Lifecycle.restart(opts ++ [health: health_fun()])
      assert_receive :health_called
      assert Fake.calls(fake) == [{:restart, [Container.name()]}]
    end
  end

  ## rebuild/1

  describe "rebuild/1" do
    test "full stop/remove/create/start sequence, create carries the parity spec" do
      {fake, opts} = engine(core("2026.6.0", :running), ["2026.7.0"])

      assert :ok =
               Lifecycle.rebuild(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert_receive :health_called
      assert verbs(fake) == [:inspect, :stop, :remove, :create, :start]
      assert [spec] = creates(fake)
      assert spec == Container.to_container_spec("2026.7.0")
      assert spec.image == Container.image("2026.7.0")
      assert spec.privileged == true
      assert spec.oom_score_adj == -300
    end

    test "absent container -> still create+start (an explicit op), the remove of nothing is :ok" do
      {fake, opts} = engine(nil, ["2026.7.0"])

      assert :ok =
               Lifecycle.rebuild(
                 opts ++ [versions: start_versions("2026.7.0"), health: health_fun()]
               )

      assert_receive :health_called
      assert verbs(fake) == [:inspect, :remove, :create, :start]
    end

    test "no installed version -> {:error, :no_version}, no engine calls" do
      {fake, opts} = engine()

      assert {:error, :no_version} = Lifecycle.rebuild(opts ++ [versions: start_versions()])
      assert Fake.calls(fake) == []
    end
  end

  ## safe_mode marker (audit E3) — restart/1 and rebuild/1

  describe "restart/1 safe_mode marker" do
    test "safe_mode: true writes an empty safe-mode file before the restart" do
      dir = tmp_config_dir()
      {fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.restart(
                 opts ++ [health: health_fun(), safe_mode: true, homeassistant_path: dir]
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
      assert verbs(fake) == [:restart]
    end

    test "safe_mode: false (the default) never touches the marker" do
      dir = tmp_config_dir()
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok = Lifecycle.restart(opts ++ [health: health_fun()])
      assert_receive :health_called
      refute File.exists?(Path.join(dir, "safe-mode"))
    end

    test "a nonexistent parent dir is created (W1) and the marker lands" do
      dir = tmp_uncreated_config_dir()
      refute File.exists?(dir)
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.restart(
                 opts ++ [health: health_fun(), safe_mode: true, homeassistant_path: dir]
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
    end

    test "a marker write failure aborts the restart before any engine call" do
      {fake, opts} = engine(core("2026.7.0", :running))

      assert {:error, {:safe_mode_marker, _reason}} =
               Lifecycle.restart(opts ++ [safe_mode: true, homeassistant_path: blocking_file()])

      assert Fake.calls(fake) == []
    end
  end

  defp safe_restart(dir) do
    {fake, opts} = engine(core("2026.7.0", :running))

    result =
      Lifecycle.restart(opts ++ [health: health_fun(), safe_mode: true, homeassistant_path: dir])

    {result, fake}
  end

  defp outside_file do
    path = Path.join(System.tmp_dir!(), "vagus_test_lifecycle_outside_#{unique()}")
    File.write!(path, "host data")
    File.touch!(path, 1_000_000_000)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp assert_regular_empty_marker(dir) do
    marker = Path.join(dir, "safe-mode")
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(marker)
    assert File.read!(marker) == ""
  end

  defp ok_verbs({result, fake}) do
    assert_receive :health_called
    {result, verbs(fake)}
  end

  describe "safe_mode marker over an existing entry" do
    test "an existing regular marker is left as-is" do
      dir = tmp_config_dir()
      marker = Path.join(dir, "safe-mode")
      File.write!(marker, "seeded")
      File.touch!(marker, 1_000_000_000)
      before = File.lstat!(marker, time: :posix)

      assert {:ok, [:restart]} = ok_verbs(safe_restart(dir))
      after_op = File.lstat!(marker, time: :posix)
      assert after_op.type == :regular
      assert File.read!(marker) == "seeded"
      assert after_op.mtime == before.mtime
      assert after_op.inode == before.inode
    end

    test "a symlink at the marker name is replaced, its target untouched" do
      dir = tmp_config_dir()
      target = outside_file()
      before = File.stat!(target, time: :posix)
      File.ln_s!(target, Path.join(dir, "safe-mode"))

      assert {:ok, [:restart]} = ok_verbs(safe_restart(dir))
      assert_regular_empty_marker(dir)
      assert File.read!(target) == "host data"
      assert File.stat!(target, time: :posix).mtime == before.mtime
    end

    test "a dangling symlink is replaced and its target never created" do
      dir = tmp_config_dir()
      target = Path.join(System.tmp_dir!(), "vagus_test_lifecycle_dangling_#{unique()}")
      on_exit(fn -> File.rm(target) end)
      File.ln_s!(target, Path.join(dir, "safe-mode"))

      assert {:ok, [:restart]} = ok_verbs(safe_restart(dir))
      assert_regular_empty_marker(dir)
      refute File.exists?(target)
    end

    test "an empty directory at the marker name is replaced" do
      dir = tmp_config_dir()
      File.mkdir!(Path.join(dir, "safe-mode"))

      assert {:ok, [:restart]} = ok_verbs(safe_restart(dir))
      assert_regular_empty_marker(dir)
    end

    test "a non-empty directory aborts the restart before any engine call" do
      dir = tmp_config_dir()
      File.mkdir_p!(Path.join([dir, "safe-mode", "inner"]))

      assert {{:error, {:safe_mode_marker, _reason}}, fake} = safe_restart(dir)
      assert Fake.calls(fake) == []
      assert File.dir?(Path.join([dir, "safe-mode", "inner"]))
    end

    test "a fifo at the marker name is replaced" do
      dir = tmp_config_dir()
      marker = Path.join(dir, "safe-mode")
      {_, 0} = System.cmd("mkfifo", [marker])

      assert {:ok, [:restart]} = ok_verbs(safe_restart(dir))
      assert_regular_empty_marker(dir)
    end
  end

  describe "rebuild/1 safe_mode marker" do
    test "safe_mode: true writes the marker after the version resolves, before stop/remove/create" do
      dir = tmp_config_dir()
      {_fake, opts} = engine(core("2026.6.0", :running), ["2026.7.0"])

      assert :ok =
               Lifecycle.rebuild(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     safe_mode: true,
                     homeassistant_path: dir
                   ]
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
    end

    test "no installed version -> {:error, :no_version}, marker never written" do
      dir = tmp_config_dir()
      {fake, opts} = engine()

      assert {:error, :no_version} =
               Lifecycle.rebuild(
                 opts ++ [versions: start_versions(), safe_mode: true, homeassistant_path: dir]
               )

      refute File.exists?(Path.join(dir, "safe-mode"))
      assert Fake.calls(fake) == []
    end

    test "a nonexistent parent dir is created (W1) and the marker lands" do
      dir = tmp_uncreated_config_dir()
      refute File.exists?(dir)
      {_fake, opts} = engine(core("2026.6.0", :running), ["2026.7.0"])

      assert :ok =
               Lifecycle.rebuild(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     safe_mode: true,
                     homeassistant_path: dir
                   ]
               )

      assert_receive :health_called
      assert File.read!(Path.join(dir, "safe-mode")) == ""
    end

    test "a marker write failure aborts before stop/remove/create reach the engine" do
      {fake, opts} = engine(core("2026.6.0", :running))

      assert {:error, {:safe_mode_marker, _reason}} =
               Lifecycle.rebuild(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     safe_mode: true,
                     homeassistant_path: blocking_file()
                   ]
               )

      assert Fake.calls(fake) == []
    end
  end

  ## update/2

  describe "update/2" do
    test "happy path: pull -> stop/remove/create/start -> health -> set_installed, {:ok, target}" do
      {fake, opts} = engine(core("2026.7.0", :running))
      versions = start_versions("2026.7.0")

      assert {:ok, "2026.8.0"} =
               Lifecycle.update("2026.8.0", opts ++ [versions: versions, health: health_fun()])

      assert_receive :health_called
      assert Versions.installed(versions) == "2026.8.0"
      assert verbs(fake) == [:pull, :inspect, :stop, :remove, :create, :start]
      assert {:pull, [image]} = hd(Fake.calls(fake))
      assert image == Container.image("2026.8.0")
      assert [%{image: ^image}] = creates(fake)
    end

    test "pull failure leaves the old Core untouched" do
      {fake, opts} = engine(core("2026.7.0", :running))
      Fake.fail_next(fake, :pull, {:pull_failed, "no such image"})
      versions = start_versions("2026.7.0")

      assert {:error, {:pull, {:pull_failed, "no such image"}}} =
               Lifecycle.update("2026.8.0", opts ++ [versions: versions])

      assert Versions.installed(versions) == "2026.7.0"
      assert verbs(fake) == [:pull]
    end

    test "a pull that outlasts its deadline fails the update and leaves the old Core untouched" do
      Application.put_env(:vagus, :core_pull_deadline_ms, 500)
      on_exit(fn -> Application.delete_env(:vagus, :core_pull_deadline_ms) end)

      {fake, opts} = engine(core("2026.7.0", :running))
      Fake.delay_next(fake, :pull, 2_000)
      versions = start_versions("2026.7.0")

      assert Lifecycle.update("2026.8.0", opts ++ [versions: versions]) ==
               {:error, {:pull, :timeout}}

      assert Versions.installed(versions) == "2026.7.0"
      assert verbs(fake) == [:pull]

      # The lock went with the failed op: the next one runs.
      assert Lifecycle.stop(opts) == :ok
    end

    test "health-gate timeout rolls back to the previous version" do
      {fake, opts} = engine(core("2026.7.0", :running), ["2026.7.0"])
      versions = start_versions("2026.7.0")

      assert {:error, {:health_timeout, :rolled_back}} =
               Lifecycle.update(
                 "2026.8.0",
                 opts ++ [versions: versions, health: health_fun(:timeout)]
               )

      assert Versions.installed(versions) == "2026.7.0"

      assert verbs(fake) ==
               [:pull, :inspect, :stop, :remove, :create, :start, :stop, :remove, :create, :start]

      assert [%{image: new}, %{image: rolled_back}] = creates(fake)
      assert new == Container.image("2026.8.0")
      assert rolled_back == Container.image("2026.7.0")
    end

    test "health-gate timeout, and the rollback recreate itself fails -> {:error, {:rollback_failed, _}}" do
      # The previous version's image is gone (pruned meanwhile).
      {fake, opts} = engine(core("2026.7.0", :running))
      versions = start_versions("2026.7.0")

      assert {:error, {:rollback_failed, {:failed, :create, :image_not_found}}} =
               Lifecycle.update(
                 "2026.8.0",
                 opts ++ [versions: versions, health: health_fun(:timeout)]
               )

      # set_installed already recorded the new (now-broken) version before
      # the health gate ran; the rollback recreate failing means it never
      # gets set back.
      assert Versions.installed(versions) == "2026.8.0"

      assert verbs(fake) == [
               :pull,
               :inspect,
               :stop,
               :remove,
               :create,
               :start,
               :stop,
               :remove,
               :create
             ]

      assert List.last(creates(fake)).image == Container.image("2026.7.0")
    end

    test "new-container create fails after the old one was removed -> rollback recreate succeeds" do
      {fake, opts} = engine(core("2026.7.0", :running), ["2026.7.0"])
      Fake.fail_next(fake, :create, {:failed, :create, :image_not_found})
      versions = start_versions("2026.7.0")

      assert {:error, {:recreate_failed, {:failed, :create, :image_not_found}, :rolled_back}} =
               Lifecycle.update("2026.8.0", opts ++ [versions: versions, health: health_fun()])

      refute_receive :health_called, 100
      assert Versions.installed(versions) == "2026.7.0"

      # Never created, so nothing to remove before the rollback create.
      assert verbs(fake) == [:pull, :inspect, :stop, :remove, :create, :create, :start]
      assert List.last(creates(fake)).image == Container.image("2026.7.0")
      assert_started_created(fake, opts)
    end

    test "same-version update -> {:error, :version_installed}, no engine calls" do
      {fake, opts} = engine()

      assert {:error, :version_installed} =
               Lifecycle.update("2026.7.0", opts ++ [versions: start_versions("2026.7.0")])

      assert Fake.calls(fake) == []
    end

    test "not-running update swaps image+version with no start and no health gate" do
      {fake, opts} = engine(core("2026.7.0", :exited))
      versions = start_versions("2026.7.0")

      assert {:ok, "2026.8.0"} =
               Lifecycle.update("2026.8.0", opts ++ [versions: versions, health: health_fun()])

      refute_receive :health_called, 100
      assert Versions.installed(versions) == "2026.8.0"
      assert verbs(fake) == [:pull, :inspect, :stop, :remove]
    end

    test "no container at all -> just records the new version, no health gate" do
      {fake, opts} = engine()
      versions = start_versions("2026.7.0")

      assert {:ok, "2026.8.0"} =
               Lifecycle.update("2026.8.0", opts ++ [versions: versions, health: health_fun()])

      refute_receive :health_called, 100
      assert Versions.installed(versions) == "2026.8.0"
      assert verbs(fake) == [:pull, :inspect]
    end

    test "no target version resolvable -> {:error, :no_version}, no engine calls" do
      {fake, opts} = engine()

      assert {:error, :no_version} =
               Lifecycle.update(nil, opts ++ [versions: start_versions("2026.7.0")])

      assert Fake.calls(fake) == []
    end
  end

  ## Serialization

  describe "the single non-blocking lock" do
    # Callers read a bare `:busy` as this lock being held (409, retry, no
    # escalation); the engine's own `:busy` must not look like it.
    test "an engine :busy is not the lock's :busy" do
      {fake, opts} = engine(core("2026.7.0", :running))
      Fake.fail_next(fake, :restart, :busy)

      assert Lifecycle.restart(opts ++ [health: health_fun()]) == {:error, {:engine, :busy}}
    end

    test "a second op returns {:error, :busy} while another op holds the lock" do
      {fake, opts} = engine(core("2026.7.0", :running))
      # Holds adopt's inspect, and so the lock adopt runs under, until released.
      Fake.block_next(fake, :inspect)

      task = Task.async(fn -> Lifecycle.adopt(opts) end)
      assert_receive {:fake_blocked, :inspect, blocked}, 1_000

      assert {:error, :busy} = Lifecycle.stop(opts)

      Fake.release(blocked)
      assert {:adopted, _info} = Task.await(task, 1_000)
    end
  end

  ## HTTP-config refresh (A4) — every point this module establishes that
  ## Core is up re-pulls Core's own HTTP parameters
  ## (`Vagus.Core.HttpConfig`), because Core's port can change across its
  ## restarts. The pull itself is `http_config_test.exs`'s subject; here we
  ## only prove WHERE it is triggered from.

  describe "HTTP-config refresh" do
    test "a passing health gate refreshes it" do
      {_fake, opts} = engine(core("2026.7.0", :exited))

      assert :ok =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     http_config: http_config_fun()
                   ]
               )

      assert_receive :http_config_refreshed
    end

    test "an already-running container (the boot reconcile no-op) refreshes it too" do
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     http_config: http_config_fun()
                   ]
               )

      refute_receive :health_called, 100
      assert_receive :http_config_refreshed
    end

    test "a restart refreshes it" do
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.restart(opts ++ [health: health_fun(), http_config: http_config_fun()])

      assert_receive :http_config_refreshed
    end

    test "a health-gate timeout does not" do
      {_fake, opts} = engine(nil, ["2026.7.0"])

      assert {:error, :health_timeout} =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(:timeout),
                     http_config: http_config_fun()
                   ]
               )

      refute_receive :http_config_refreshed, 100
    end

    test "a failed refresh never fails the op it was triggered from" do
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.restart(
                 opts ++
                   [
                     health: health_fun(),
                     http_config: http_config_fun({:error, {:http_error, 500}})
                   ]
               )

      assert_receive :http_config_refreshed
    end
  end

  ## The Core port migration — `Vagus.Core.PortMigration` owns the conditions
  ## and is unit-tested in full next door; these prove only which ops run it,
  ## i.e. that it lands whenever Core's process is about to (re)start and
  ## never against a Core that is up.

  # `Vagus.Core.PortMigration`'s fixtures, kept minimal here — that module's
  # own test owns the store's real shape and every condition.
  defp write_core_store!(dir, port) do
    File.mkdir_p!(Path.join(dir, ".storage"))

    File.write!(
      Path.join(dir, ".storage/http"),
      Jason.encode!(%{
        "version" => 2,
        "minor_version" => 2,
        "key" => "http",
        "data" => %{
          "stable" => %{"server_port" => port},
          "pending" => nil,
          "yaml_migration_done" => true
        }
      })
    )
  end

  defp stored_core_port(dir) do
    Path.join(dir, ".storage/http")
    |> File.read!()
    |> Jason.decode!()
    |> get_in(~w(data stable server_port))
  end

  defp migration_marker do
    path = Path.join(System.tmp_dir!(), "vagus_test_lifecycle_port_marker_#{unique()}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "Core port migration" do
    test "start/1 migrates Core's stored 8123 before the container is started" do
      dir = tmp_config_dir()
      marker = migration_marker()
      write_core_store!(dir, 8123)
      {_fake, opts} = engine(core("2026.7.0", :exited))

      assert :ok =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     homeassistant_path: dir,
                     port_migration_marker: marker
                   ]
               )

      assert_receive :health_called
      assert stored_core_port(dir) == 80
      # `Vagus.Core.HttpConfig` writes the marker, and only once Core has
      # actually served 80 — the rewrite itself confirms nothing.
      refute File.exists?(marker)
    end

    test "start/1 on an already-running container leaves the store alone" do
      # A live Core would not re-read the rewrite and would overwrite it from
      # its in-memory config at its next persist — this device heals at its
      # next actual restart, which is the only moment the edit can take.
      dir = tmp_config_dir()
      marker = migration_marker()
      write_core_store!(dir, 8123)
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     homeassistant_path: dir,
                     port_migration_marker: marker
                   ]
               )

      refute_receive :health_called, 100
      assert stored_core_port(dir) == 8123
    end

    test "restart/1 migrates — an engine restart stops Core before it starts it" do
      dir = tmp_config_dir()
      marker = migration_marker()
      write_core_store!(dir, 8123)
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert :ok =
               Lifecycle.restart(
                 opts ++
                   [health: health_fun(), homeassistant_path: dir, port_migration_marker: marker]
               )

      assert_receive :health_called
      assert stored_core_port(dir) == 80
    end

    test "rebuild/1 migrates before the recreated container starts" do
      dir = tmp_config_dir()
      marker = migration_marker()
      write_core_store!(dir, 8123)
      {_fake, opts} = engine(core("2026.7.0", :running), ["2026.7.0"])

      assert :ok =
               Lifecycle.rebuild(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     homeassistant_path: dir,
                     port_migration_marker: marker
                   ]
               )

      assert_receive :health_called
      assert stored_core_port(dir) == 80
    end

    test "update/2 migrates before the new container starts" do
      dir = tmp_config_dir()
      marker = migration_marker()
      write_core_store!(dir, 8123)
      {_fake, opts} = engine(core("2026.7.0", :running))

      assert {:ok, "2026.8.0"} =
               Lifecycle.update(
                 "2026.8.0",
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     homeassistant_path: dir,
                     port_migration_marker: marker
                   ]
               )

      assert_receive :health_called
      assert stored_core_port(dir) == 80
    end

    test "a migration that cannot run never fails the start" do
      dir = tmp_config_dir()
      {_fake, opts} = engine(core("2026.7.0", :exited))

      # No store file at all, and a marker under a path that is a regular
      # file — every write this could attempt fails.
      assert :ok =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     homeassistant_path: dir,
                     port_migration_marker: Path.join(blocking_file(), "marker")
                   ]
               )

      assert_receive :health_called
    end

    test "an unconfigured marker (the suite's own default) leaves the store alone" do
      dir = tmp_config_dir()
      write_core_store!(dir, 8123)
      {_fake, opts} = engine(core("2026.7.0", :exited))

      assert :ok =
               Lifecycle.start(
                 opts ++
                   [
                     versions: start_versions("2026.7.0"),
                     health: health_fun(),
                     homeassistant_path: dir
                   ]
               )

      assert stored_core_port(dir) == 8123
    end
  end
end
