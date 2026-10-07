defmodule Vagus.App.Backend.ContainerTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Backend.Container
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  setup do
    engine = FakeEngine.start_model()
    on_exit(fn -> FakeEngine.stop(engine) end)
    %{engine: engine, opts: [engine: [socket: engine.socket]]}
  end

  defp paths(engine),
    do: for(request <- FakeEngine.requests(engine), do: {request.method, request.path})

  defp inspect_map(state, extra \\ %{}) do
    Map.merge(
      %{
        "Id" => "abc",
        "RestartCount" => 0,
        "Image" => "sha256:feed",
        "State" => state,
        "Config" => %{"Image" => "repo/a:1", "Env" => [], "Labels" => %{}},
        "NetworkSettings" => %{"Networks" => %{}}
      },
      extra
    )
  end

  describe "observe/2" do
    test "no container under the name is :absent", %{opts: opts} do
      assert Container.observe("app_none", opts) == {:ok, :absent}
    end

    test "a running container, with everything a controller decides from", %{
      engine: engine,
      opts: opts
    } do
      id =
        Model.put_container(engine, "app_a",
          image: "repo/a:1",
          labels: %{"supervisor_managed" => "", "io.vagus.spec" => "f00"},
          env: ["SUPERVISOR_TOKEN=secret", "TZ=UTC", "EMPTY=", "A=b=c", "FLAG"],
          ip: "172.30.33.7"
        )

      assert {:ok, instance} = Container.observe("app_a", opts)

      assert instance == %{
               id: id,
               state: :running,
               exit_code: nil,
               started_at: Model.container(engine, "app_a").started_at,
               restart_count: 0,
               health: :none,
               health_failing_streak: 0,
               image: "repo/a:1",
               image_id: "sha256:repo/a:1",
               labels: %{"supervisor_managed" => "", "io.vagus.spec" => "f00"},
               env: %{
                 "SUPERVISOR_TOKEN" => "secret",
                 "TZ" => "UTC",
                 "EMPTY" => "",
                 "A" => "b=c",
                 "FLAG" => ""
               },
               address: "172.30.33.7"
             }
    end

    test "a created container has never started and has no address", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a", state: "created")

      assert {:ok, %{state: :created, started_at: nil, address: nil, exit_code: nil}} =
               Container.observe("app_a", opts)
    end

    test "an exited container keeps its exit code", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a", state: "exited", exit_code: 137)
      assert {:ok, %{state: :exited, exit_code: 137}} = Container.observe("app_a", opts)
    end

    for {word, state} <- [
          {"created", :created},
          {"running", :running},
          {"paused", :paused},
          {"restarting", :restarting},
          {"removing", :removing},
          {"exited", :exited},
          {"dead", :dead}
        ] do
      test "the engine's #{word} is #{inspect(state)}", %{engine: engine, opts: opts} do
        Model.put_container(engine, "app_a", state: unquote(word))
        assert {:ok, %{state: unquote(state)}} = Container.observe("app_a", opts)
      end
    end

    for {word, health} <- [
          {"starting", :starting},
          {"healthy", :healthy},
          {"unhealthy", :unhealthy},
          {"none", :none}
        ] do
      test "health #{word} is #{inspect(health)}, with its failing streak", %{
        engine: engine,
        opts: opts
      } do
        Model.put_container(engine, "app_a", health: {unquote(word), 3})

        assert {:ok, %{health: unquote(health), health_failing_streak: 3}} =
                 Container.observe("app_a", opts)
      end
    end

    test "the last exit's code is kept while the engine waits to restart it", %{
      engine: engine,
      opts: opts
    } do
      Model.put_container(engine, "app_a", state: "restarting", exit_code: 3)
      assert {:ok, %{state: :restarting, exit_code: 3}} = Container.observe("app_a", opts)
    end

    test "a paused container has not exited", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a", state: "paused", exit_code: 0)
      assert {:ok, %{state: :paused, exit_code: nil}} = Container.observe("app_a", opts)
    end

    test "a restart by the engine's policy shows as a higher count and a new start time", %{
      engine: engine,
      opts: opts
    } do
      Model.put_container(engine, "homeassistant", restart_policy: "unless-stopped")
      {:ok, before} = Container.observe("homeassistant", opts)

      Model.crash(engine, "homeassistant", 1)
      {:ok, later} = Container.observe("homeassistant", opts)

      assert later.restart_count == before.restart_count + 1
      assert later.started_at != before.started_at
      assert later.id == before.id
      assert later.state == :running
      assert later.exit_code == nil
    end

    test "a crash with no restart policy leaves it exited, count unchanged", %{
      engine: engine,
      opts: opts
    } do
      Model.put_container(engine, "app_a")
      Model.crash(engine, "app_a", 2)

      assert {:ok, %{state: :exited, exit_code: 2, restart_count: 0}} =
               Container.observe("app_a", opts)
    end

    test "no engine at the socket is unavailable, never absent" do
      missing = FakeEngine.socket_path()

      assert Container.observe("app_a", engine: [socket: missing]) ==
               {:unavailable, :engine_unavailable}
    end

    test "an engine that fails to answer is an error, never absent" do
      engine = FakeEngine.start([{500, %{"message" => "boom"}}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      assert Container.observe("app_a", engine: [socket: engine.socket]) ==
               {:error, {:status, 500, "boom"}}
    end

    test "an engine that does not answer in time is an error, never absent" do
      engine = FakeEngine.start([{200, %{}, delay: 400}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      assert Container.observe("app_a", engine: [socket: engine.socket, recv_timeout: 30]) ==
               {:error, {:timeout, :recv}}
    end
  end

  describe "project/1" do
    test "without a Status word the flags decide, restarting before running" do
      assert %{state: :restarting} =
               Container.project(inspect_map(%{"Running" => true, "Restarting" => true}))

      assert %{state: :running} = Container.project(inspect_map(%{"Running" => true}))

      assert %{state: :paused} =
               Container.project(inspect_map(%{"Running" => true, "Paused" => true}))

      assert %{state: :dead} = Container.project(inspect_map(%{"Dead" => true}))
      assert %{state: :exited} = Container.project(inspect_map(%{"Running" => false}))
    end

    test "the app network's address is preferred to another network's" do
      networks = %{
        "bridge" => %{"IPAddress" => "172.17.0.2"},
        Vagus.Network.name() => %{"IPAddress" => "172.30.33.2"}
      }

      inspect =
        inspect_map(%{"Status" => "running"}, %{"NetworkSettings" => %{"Networks" => networks}})

      assert %{address: "172.30.33.2"} = Container.project(inspect)
    end

    test "a container on another network only has that network's address" do
      networks = %{"other" => %{"IPAddress" => "10.0.0.2"}}

      inspect =
        inspect_map(%{"Status" => "running"}, %{"NetworkSettings" => %{"Networks" => networks}})

      assert %{address: "10.0.0.2"} = Container.project(inspect)
    end

    test "of two networks that are not the app's, the first by name" do
      networks = %{
        "zeta" => %{"IPAddress" => "10.9.0.2"},
        "alpha" => %{"IPAddress" => "10.1.0.2"}
      }

      inspect =
        inspect_map(%{"Status" => "running"}, %{"NetworkSettings" => %{"Networks" => networks}})

      assert %{address: "10.1.0.2"} = Container.project(inspect)
    end

    test "the host network gives no address" do
      networks = %{"host" => %{"IPAddress" => ""}}

      inspect =
        inspect_map(%{"Status" => "running"}, %{"NetworkSettings" => %{"Networks" => networks}})

      assert %{address: nil} = Container.project(inspect)
    end

    test "fields the engine leaves out read as empty, not as a crash" do
      assert %{
               restart_count: 0,
               health: :none,
               health_failing_streak: 0,
               image: nil,
               labels: %{},
               env: %{},
               address: nil,
               exit_code: nil,
               started_at: nil
             } = Container.project(%{"Id" => "abc"})
    end
  end

  describe "image_present?/2" do
    test "true for an image the engine has, false for one it has not", %{
      engine: engine,
      opts: opts
    } do
      Model.put_image(engine, "ghcr.io/org/a:1")

      assert Container.image_present?("ghcr.io/org/a:1", opts) == {:ok, true}
      assert Container.image_present?("ghcr.io/org/a:2", opts) == {:ok, false}
    end

    test "no engine is unavailable, not false" do
      missing = FakeEngine.socket_path()

      assert Container.image_present?("a:1", engine: [socket: missing]) ==
               {:unavailable, :engine_unavailable}
    end
  end

  describe "list/1" do
    test "our containers, running or not, in one call", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a")
      Model.put_container(engine, "addon_b", state: "exited")
      Model.put_container(engine, "homeassistant", state: "exited")
      Model.put_container(engine, "bystander")
      Model.put_container(engine, "my_app_x")

      assert {:ok, listed} = Container.list(opts)

      assert Enum.sort(Enum.flat_map(listed, & &1.names)) == ["addon_b", "app_a", "homeassistant"]
      assert [%{state: "exited"}] = Enum.filter(listed, &(&1.names == ["addon_b"]))

      assert [%{path: "/containers/json", query: %{"all" => "true", "filters" => filters}}] =
               FakeEngine.requests(engine)

      assert Jason.decode!(filters) == %{"name" => Container.name_filters()}
      assert Container.name_filters() == ["^/?app_", "^/?addon_", "^/?homeassistant$"]
    end

    for {how, slashed?} <- [{"the bare name", false}, {"the name with its slash", true}] do
      test "the name patterns select ours on an engine that matches #{how}" do
        engine = FakeEngine.start_model(slashed_names: unquote(slashed?))
        on_exit(fn -> FakeEngine.stop(engine) end)

        for name <- ~w(app_a addon_b homeassistant my_app_x application homeassistant2 bystander),
            do: Model.put_container(engine, name)

        # The engine's own answer, before anything is filtered here.
        {:ok, listed} =
          Vagus.Runtime.Docker.list_containers(
            all: true,
            filters: %{name: Container.name_filters()},
            socket: engine.socket
          )

        assert listed |> Enum.flat_map(& &1["Names"]) |> Enum.sort() ==
                 ["/addon_b", "/app_a", "/homeassistant"]
      end
    end

    test "an engine that fails to list is an error, not an empty list" do
      engine = FakeEngine.start([{500, %{"message" => "boom"}}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      assert Container.list(engine: [socket: engine.socket]) == {:error, {:status, 500, "boom"}}
    end

    test "an engine that ignores the filter is filtered here" do
      listing = [
        %{"Id" => "1", "Names" => ["/app_a"], "Labels" => %{}},
        %{"Id" => "2", "Names" => ["/bystander"], "Labels" => %{}},
        %{"Id" => "3", "Names" => ["/labelled"], "Labels" => %{"supervisor_managed" => ""}}
      ]

      engine = FakeEngine.start([{200, listing}])
      on_exit(fn -> FakeEngine.stop(engine) end)

      assert {:ok, listed} = Container.list(engine: [socket: engine.socket])
      assert Enum.flat_map(listed, & &1.names) == ["app_a", "labelled"]
    end

    test "no engine is unavailable, not an empty list" do
      missing = FakeEngine.socket_path()
      assert Container.list(engine: [socket: missing]) == {:unavailable, :engine_unavailable}
    end
  end

  describe "create/3" do
    setup %{engine: engine} do
      Model.put_image(engine, "repo/a:1")
      :ok
    end

    test "makes the container from the config, under the name, not started", %{
      engine: engine,
      opts: opts
    } do
      config = %{
        "Image" => "repo/a:1",
        "Env" => ["SUPERVISOR_TOKEN=t"],
        "Labels" => %{"supervisor_managed" => ""},
        "HostConfig" => %{"RestartPolicy" => %{"Name" => "unless-stopped"}}
      }

      assert Container.create("app_a", config, opts) == :ok

      assert {:ok, %{state: :created, env: %{"SUPERVISOR_TOKEN" => "t"}}} =
               Container.observe("app_a", opts)

      assert [
               %{
                 method: :post,
                 path: "/containers/create",
                 query: %{"name" => "app_a"},
                 body: ^config
               }
               | _
             ] =
               FakeEngine.requests(engine)
    end

    test "a name already taken is :already_exists, and the container there is untouched", %{
      engine: engine,
      opts: opts
    } do
      id = Model.put_container(engine, "app_a", image: "repo/other:1")

      assert Container.create("app_a", %{"Image" => "repo/a:1"}, opts) ==
               {:error, :already_exists}

      assert {:ok, %{id: ^id, image: "repo/other:1"}} = Container.observe("app_a", opts)
    end

    test "a missing image is the engine's 404 and message", %{opts: opts} do
      assert Container.create("app_a", %{"Image" => "repo/none:1"}, opts) ==
               {:error, {:status, 404, "No such image: repo/none:1"}}
    end

    test "is one engine call", %{engine: engine, opts: opts} do
      :ok = Container.create("app_a", %{"Image" => "repo/a:1"}, opts)
      assert paths(engine) == [{:post, "/containers/create"}]
    end
  end

  describe "start/2" do
    test "starts a created container", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a", state: "created")

      assert Container.start("app_a", opts) == :ok
      assert {:ok, %{state: :running}} = Container.observe("app_a", opts)
    end

    test "is :ok for a container already running, and starts nothing twice", %{
      engine: engine,
      opts: opts
    } do
      Model.put_container(engine, "app_a")
      started_at = Model.container(engine, "app_a").started_at

      assert Container.start("app_a", opts) == :ok
      assert Model.container(engine, "app_a").started_at == started_at
      assert paths(engine) == [{:post, "/containers/app_a/start"}]
    end

    test "no container is the engine's 404", %{opts: opts} do
      assert Container.start("app_none", opts) ==
               {:error, {:status, 404, "No such container: app_none"}}
    end

    test "a refusal carries the engine's message", %{engine: engine, opts: opts} do
      message = "driver failed programming external connectivity: port is already allocated"
      Model.put_container(engine, "app_a", state: "created", fail_start: message)

      assert Container.start("app_a", opts) == {:error, {:status, 500, message}}
    end

    test "no engine is an error that says so" do
      missing = FakeEngine.socket_path()

      assert Container.start("app_a", engine: [socket: missing]) ==
               {:error, {:unreachable, :enoent}}
    end
  end

  describe "stop/3" do
    test "stops a running container with the grace asked for", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a")

      assert Container.stop("app_a", 7, opts) == :ok
      assert {:ok, %{state: :exited}} = Container.observe("app_a", opts)

      assert [%{path: "/containers/app_a/stop", query: %{"t" => "7"}} | _] =
               FakeEngine.requests(engine)
    end

    test "with no grace it names none, leaving the engine's default", %{
      engine: engine,
      opts: opts
    } do
      Model.put_container(engine, "app_a")

      assert Container.stop("app_a", nil, opts) == :ok
      assert [%{path: "/containers/app_a/stop", query: query}] = FakeEngine.requests(engine)
      assert query == %{}
    end

    test "is :ok for a container already stopped", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a", state: "exited")
      assert Container.stop("app_a", 5, opts) == :ok
    end

    test "is :ok when there is no container", %{opts: opts} do
      assert Container.stop("app_none", 5, opts) == :ok
    end

    test "is one engine call", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a")
      :ok = Container.stop("app_a", 5, opts)
      assert paths(engine) == [{:post, "/containers/app_a/stop"}]
    end
  end

  describe "remove/2" do
    test "removes a container, running or not", %{engine: engine, opts: opts} do
      Model.put_container(engine, "app_a")

      assert Container.remove("app_a", opts) == :ok
      assert Container.observe("app_a", opts) == {:ok, :absent}

      assert [%{method: :delete, path: "/containers/app_a", query: %{"force" => "true"}} | _] =
               FakeEngine.requests(engine)
    end

    test "is :ok when there is no container", %{opts: opts} do
      assert Container.remove("app_none", opts) == :ok
    end
  end

  describe "remove_image/2" do
    test "removes an image nothing uses, and is :ok for one already gone", %{
      engine: engine,
      opts: opts
    } do
      Model.put_image(engine, "repo/a:1")

      assert Container.remove_image("repo/a:1", opts) == :ok
      assert Container.image_present?("repo/a:1", opts) == {:ok, false}
      assert Container.remove_image("repo/a:1", opts) == :ok
    end

    test "an image a container still uses is the engine's 409", %{engine: engine, opts: opts} do
      Model.put_image(engine, "repo/a:1")
      Model.put_container(engine, "app_a", image: "repo/a:1")

      assert {:error, {:status, 409, "conflict" <> _}} = Container.remove_image("repo/a:1", opts)
    end
  end

  describe "an engine that refuses" do
    defp refusing(status, message) do
      engine = FakeEngine.start([{status, %{"message" => message}}])
      on_exit(fn -> FakeEngine.stop(engine) end)
      [engine: [socket: engine.socket]]
    end

    for {status, message} <- [{500, "boom"}, {409, "busy with it"}] do
      @refusal {:error, {:status, status, message}}

      test "create answered #{status} is that status, unless it is the name that is taken" do
        opts = refusing(unquote(status), unquote(message))
        expected = if unquote(status) == 409, do: {:error, :already_exists}, else: @refusal
        assert Container.create("app_a", %{"Image" => "a:1"}, opts) == expected
      end

      test "start answered #{status} is that status and the engine's message" do
        assert Container.start("app_a", refusing(unquote(status), unquote(message))) == @refusal
      end

      test "stop answered #{status} is that status and the engine's message" do
        assert Container.stop("app_a", 1, refusing(unquote(status), unquote(message))) == @refusal
      end

      test "remove answered #{status} is that status and the engine's message" do
        assert Container.remove("app_a", refusing(unquote(status), unquote(message))) == @refusal
      end

      test "remove_image answered #{status} is that status and the engine's message" do
        opts = refusing(unquote(status), unquote(message))
        assert Container.remove_image("a:1", opts) == @refusal
      end

      test "image_present? answered #{status} is an error, not false" do
        opts = refusing(unquote(status), unquote(message))
        assert Container.image_present?("a:1", opts) == @refusal
      end
    end
  end

  test "every action runs in the engine lane" do
    for action <- [:create, :start, :stop, :remove, :remove_image],
        do: assert(Container.lane(action) == :engine)
  end
end

defmodule Vagus.App.Backend.ContainerSlowStopTest do
  # Not async: the client's default receive timeout, cut short here so that
  # an answer held for 400 ms is "longer than the default", is global.
  use ExUnit.Case, async: false

  alias Vagus.App.Backend.Container
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  setup do
    previous = Application.fetch_env(:vagus, :docker_recv_timeout)
    Application.put_env(:vagus, :docker_recv_timeout, 50)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vagus, :docker_recv_timeout, value)
        :error -> Application.delete_env(:vagus, :docker_recv_timeout)
      end
    end)

    engine = FakeEngine.start_model(stop_delay: 400)
    on_exit(fn -> FakeEngine.stop(engine) end)
    Model.put_container(engine, "homeassistant")
    %{engine: engine, opts: [engine: [socket: engine.socket]]}
  end

  # The answer comes 400 ms in, eight times the default wait. A grace of
  # zero adds nothing, so what outwaits it is the margin alone.
  test "a stop outwaits its grace by a margin, past the default receive timeout", %{
    engine: engine,
    opts: opts
  } do
    assert Container.stop("homeassistant", 0, opts) == :ok
    assert %{state: "exited"} = Model.container(engine, "homeassistant")
  end

  test "without a grace the default applies, and the call gives up as a timeout", %{opts: opts} do
    assert Container.stop("homeassistant", nil, opts) == {:error, {:timeout, :recv}}
  end
end
