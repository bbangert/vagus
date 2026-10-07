defmodule Vagus.Runtime.EngineLiveTest do
  @moduledoc """
  The engine layer against a real engine at the default socket. Excluded by
  default: `mix test --only docker`.

  Every container made here has a name no other run can have and is removed
  with it. An image is removed only if this run was what brought it.

  What is asserted here as the engine's own wording or codes was read off
  moby 29; `test/support/fake_engine_model.ex` answers the same way, and
  this is what keeps it honest.
  """

  use ExUnit.Case, async: false

  alias Vagus.App.Backend.Container
  alias Vagus.App.Pulls
  alias Vagus.Resource.{Runtime, Stamp, TestInstance}
  alias Vagus.Runtime.{Docker, Events}

  @moduletag :docker
  @moduletag timeout: 180_000

  @busybox "busybox:latest"
  @tiny "hello-world:linux"
  # Ignores the stop signal, so the engine waits out the grace and kills.
  @stubborn "trap '' TERM; while true; do sleep 1; done"

  setup_all do
    :ok = Docker.pull_image(@busybox)
  end

  # Random, so that what a crashed run left behind is never in the way.
  defp unique(prefix) do
    random = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    "#{prefix}_vagustest_#{random}"
  end

  defp container(name, cmd, extra \\ %{}) do
    config =
      Map.merge(
        %{"Image" => @busybox, "Cmd" => List.wrap(cmd), "Labels" => %{"vagustest" => name}},
        extra
      )

    on_exit(fn -> Docker.remove_container(name, force: true) end)
    {:ok, _id} = Docker.create_container(config, name: name)
    name
  end

  defp shell(command), do: ["sh", "-c", command]

  # Leaves an image the developer had alone; one this run brings goes with it.
  defp borrowed(image) do
    case Docker.inspect_image(image) do
      {:ok, _present} -> :ok
      {:error, {:http, 404, _message}} -> on_exit(fn -> Docker.remove_image(image) end)
    end
  end

  defp events do
    worker = start_supervised!({Events, name: :"#{unique("events")}"})
    :ok = Events.subscribe(worker)
    assert_receive {:docker_events, :gap}, 5_000
    worker
  end

  defp instance do
    instance = TestInstance.name()

    TestInstance.start!(
      instance: instance,
      services: Pulls.child_specs(instance: instance, progress_interval: 0)
    )

    Process.register(self(), Runtime.name(instance, __MODULE__.Waits))
    instance
  end

  defp waiter, do: {__MODULE__.Waits, "app"}

  describe "pull_image_stream/4" do
    test "a real pull streams progress lines and leaves the image present" do
      borrowed(@tiny)

      assert {:ok, lines} = Docker.pull_image_stream(@tiny, [], &[&1 | &2])

      assert length(lines) >= 2
      assert Enum.all?(lines, &is_binary(&1["status"]))
      assert "Status: " <> _ = hd(lines)["status"]
      assert {:ok, _image} = Docker.inspect_image(@tiny)
    end

    test "a repository that does not exist is refused before any stream" do
      image = "#{unique("vagus-does-not-exist")}:nope"

      assert {:error, reason} = Docker.pull_image_stream(image, [], &[&1 | &2])
      assert {:status, 404, "pull access denied for " <> _} = Docker.failure(reason)
    end

    test "a tag that does not exist is refused before any stream too" do
      assert {:error, reason} =
               Docker.pull_image_stream("busybox:vagus-no-such-tag", [], &[&1 | &2])

      assert {:status, 404, message} = Docker.failure(reason)
      assert message =~ "manifest unknown"
    end

    test "a reference by digest, with or without a tag, pulls that image" do
      {:ok, %{"RepoDigests" => [digest_ref | _]}} = Docker.inspect_image(@busybox)
      [repo, digest] = String.split(digest_ref, "@")

      for reference <- [digest_ref, "#{repo}:latest@#{digest}"] do
        assert {:ok, [last | _]} = Docker.pull_image_stream(reference, [], &[&1 | &2])
        assert last["status"] =~ ~r/^Status: (Image is up to date|Downloaded newer image)/
        assert :ok = Docker.pull_image(reference)
      end
    end
  end

  describe "listing" do
    test "name and label filters narrow the listing in the engine" do
      app = container(unique("app"), ["sleep", "300"])
      other = container(unique("other"), ["sleep", "300"])
      :ok = Docker.start_container(app)

      names = fn opts ->
        {:ok, listed} = Docker.list_containers(opts)

        listed
        |> Enum.flat_map(&Docker.summary(&1).names)
        |> Enum.filter(&(&1 in [app, other]))
        |> Enum.sort()
      end

      assert names.(all: true) == Enum.sort([app, other])
      assert names.([]) == [app]
      assert names.(all: true, filters: %{name: ["^#{app}$"]}) == [app]
      assert names.(all: true, filters: %{name: ["^/?#{app}$"]}) == [app]

      assert names.(all: true, filters: %{name: ["^#{app}$", "^#{other}$"]}) ==
               Enum.sort([app, other])

      assert names.(all: true, filters: %{label: ["vagustest=#{other}"]}) == [other]
      assert names.(all: true, filters: %{label: ["vagustest"], name: ["^#{app}$"]}) == [app]

      {:ok, [listed]} = Docker.list_containers(all: true, filters: %{name: ["^#{app}$"]})

      assert %{names: [^app], image: @busybox, state: "running", status: "Up " <> _} =
               Docker.summary(listed)

      {:ok, [stopped]} = Docker.list_containers(all: true, filters: %{name: ["^#{other}$"]})
      assert %{state: "created", status: "Created"} = Docker.summary(stopped)
    end

    test "Container.list/1 is ours by name or by label, and none that only looks like ours" do
      app = container(unique("app"), ["sleep", "300"])

      labelled =
        container(unique("custom"), ["sleep", "300"], %{
          "Labels" => %{"supervisor_managed" => ""}
        })

      near =
        for prefix <- ["my_app", "application", "homeassistant2", "addons"],
            do: container(unique(prefix), ["sleep", "300"])

      {:ok, listed} = Container.list()
      names = Enum.flat_map(listed, & &1.names)
      assert app in names
      assert labelled in names
      assert near -- names == near
    end
  end

  describe "events" do
    test "the worker passes on a real container's start and its death, with the exit code" do
      name = container(unique("app"), shell("exit 7"))
      events()

      :ok = Docker.start_container(name)

      assert_receive {:docker_event, %{action: "start", name: ^name, id: id}}, 5_000
      assert_receive {:docker_event, %{action: "die", name: ^name, exit_code: 7, id: ^id}}, 5_000
      assert {:ok, %{id: ^id, state: :exited, exit_code: 7}} = Container.observe(name)
    end

    test "a restart by the engine's policy is die then start, a higher count and a new start time" do
      name =
        container(unique("app"), shell("sleep 1; exit 3"), %{
          "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}}
        })

      events()

      :ok = Docker.start_container(name)
      assert_receive {:docker_event, %{action: "start", name: ^name}}, 5_000
      {:ok, first} = Container.observe(name)

      assert_receive {:docker_event, %{action: "die", name: ^name, exit_code: 3}}, 10_000
      assert_receive {:docker_event, %{action: "start", name: ^name}}, 10_000
      {:ok, raw} = Docker.inspect_container(name)
      second = Container.project(raw)

      assert second.restart_count > first.restart_count
      assert second.started_at != first.started_at
      assert second.id == first.id

      # Started again, the engine has put the exit code back to zero.
      if raw["State"]["Status"] == "running" do
        assert raw["State"]["ExitCode"] == 0
        assert second.exit_code == nil
      end

      # A stop by the API ends the restarting; its `stop` event comes after
      # anything the restarts before it would have sent.
      :ok = Docker.stop_container(name, timeout: 0)
      assert_receive {:docker_event, %{action: "stop", name: ^name}}, 10_000
      refute_received {:docker_event, %{action: "restart", name: ^name}}
    end

    test "a healthcheck shows in inspect and as a health_status event" do
      check = fn command ->
        %{
          "Healthcheck" => %{
            "Test" => ["CMD-SHELL", command],
            "Interval" => 1_000_000_000,
            "Timeout" => 1_000_000_000,
            "Retries" => 1
          }
        }
      end

      well = container(unique("app"), ["sleep", "300"], check.("exit 0"))
      ill = container(unique("app"), ["sleep", "300"], check.("exit 1"))
      events()

      :ok = Docker.start_container(well)
      assert {:ok, %{health: :starting, health_failing_streak: 0}} = Container.observe(well)
      assert_receive {:docker_event, %{action: "health_status: healthy", name: ^well}}, 20_000
      assert {:ok, %{health: :healthy, health_failing_streak: 0}} = Container.observe(well)

      :ok = Docker.start_container(ill)
      assert_receive {:docker_event, %{action: "health_status: unhealthy", name: ^ill}}, 20_000

      assert {:ok, %{health: :unhealthy, health_failing_streak: streak, state: :running}} =
               Container.observe(ill)

      assert streak >= 1
    end
  end

  describe "stop" do
    test "the engine waits the grace it was given, not its own default, and then kills" do
      name = container(unique("app"), shell(@stubborn))
      :ok = Docker.start_container(name)

      began = System.monotonic_time(:millisecond)
      assert :ok = Container.stop(name, 1)
      took = System.monotonic_time(:millisecond) - began

      # Its default is ten seconds.
      assert took >= 1_000
      assert took < 6_000
      assert {:ok, %{state: :exited, exit_code: 137}} = Container.observe(name)
    end

    test "a process that ends on the stop signal leaves 143" do
      # With an init as the first process, `sleep` gets the signal's default.
      name = container(unique("app"), ["sleep", "300"], %{"HostConfig" => %{"Init" => true}})
      :ok = Docker.start_container(name)

      assert :ok = Container.stop(name, 8)
      assert {:ok, %{state: :exited, exit_code: 143}} = Container.observe(name)
    end

    test "a call that gives up first does not stop the stop" do
      name = container(unique("app"), shell(@stubborn))
      :ok = Docker.start_container(name)

      assert {:error, reason} = Docker.stop_container(name, timeout: 2, recv_timeout: 300)
      assert Docker.failure(reason) == {:timeout, :recv}

      # A second stop is answered when the first has done its work.
      assert :ok = Container.stop(name, 5)
      assert {:ok, %{state: :exited}} = Container.observe(name)
    end
  end

  describe "the backend on a real container" do
    test "observe/2 through create, start, stop and remove" do
      name = unique("app")
      on_exit(fn -> Docker.remove_container(name, force: true) end)
      assert Container.observe(name) == {:ok, :absent}

      config = %{
        "Image" => @busybox,
        "Cmd" => ["sleep", "300"],
        "Env" => ["SUPERVISOR_TOKEN=t0ken"]
      }

      assert Container.create(name, config) == :ok
      assert Container.create(name, config) == {:error, :already_exists}

      assert {:ok,
              %{
                id: id,
                state: :created,
                started_at: nil,
                address: nil,
                health: :none,
                exit_code: nil
              }} =
               Container.observe(name)

      assert :ok = Container.start(name)
      assert :ok = Container.start(name)

      assert {:ok,
              %{id: ^id, state: :running, restart_count: 0, image: @busybox, exit_code: nil} =
                running} =
               Container.observe(name)

      assert running.env["SUPERVISOR_TOKEN"] == "t0ken"
      assert is_binary(running.started_at) and is_binary(running.address)

      assert :ok = Container.stop(name, 0)
      assert :ok = Container.stop(name, 0)

      assert {:ok, %{id: ^id, state: :exited, exit_code: 137, address: nil}} =
               Container.observe(name)

      assert :ok = Container.remove(name)
      assert :ok = Container.remove(name)
      assert Container.observe(name) == {:ok, :absent}
      assert Container.stop(name, 0) == :ok
    end

    test "the engine's words for what is missing or taken" do
      name = container(unique("app"), ["sleep", "300"])
      missing = unique("app")
      no_image = "#{unique("vagus-no-image")}:1"

      assert Container.start(missing) == {:error, {:status, 404, "No such container: #{missing}"}}

      assert {:error, {:http, 404, "No such container: " <> ^missing}} =
               Docker.inspect_container(missing)

      assert {:error, {:create_failed, 409, taken}} =
               Docker.create_container(%{"Image" => @busybox}, name: name)

      assert taken =~ ~s(Conflict. The container name "/#{name}" is already in use)

      assert {:error, {:status, 404, "No such image: " <> ^no_image}} =
               Container.create(unique("app"), %{"Image" => no_image})

      assert {:error, {:http, 404, no_such}} = Docker.inspect_image(no_image)
      assert no_such =~ "No such image"
    end

    test "the last reference to an image a container uses is not removed: 409" do
      # An image of this run's own, committed from a container, so that
      # nobody's image is at stake and no other tag keeps it alive.
      repo = String.replace(unique("vagustest-image"), "_", "-")
      image = "#{repo}:1"
      source = container(unique("app"), ["sleep", "300"])

      {:ok, %{status: 201}} =
        Docker.request(:post, "/commit", query: [container: source, repo: repo, tag: "1"])

      on_exit(fn -> Docker.remove_image(image) end)
      container(unique("app"), ["sleep", "300"], %{"Image" => image})

      assert {:error, {:status, 409, message}} = Container.remove_image(image)
      assert message =~ "conflict"
      assert Container.image_present?(image) == {:ok, true}
    end

    test "a tag is removed while another keeps the image, whoever uses it" do
      repo = String.replace(unique("vagustest-image"), "_", "-")
      image = "#{repo}:1"

      {:ok, %{status: 201}} =
        Docker.request(:post, "/images/#{@busybox}/tag", query: [repo: repo, tag: "1"])

      on_exit(fn -> Docker.remove_image(image) end)
      container(unique("app"), ["sleep", "300"], %{"Image" => image})

      assert Container.remove_image(image) == :ok
      assert Container.image_present?(image) == {:ok, false}
      assert Container.image_present?(@busybox) == {:ok, true}
    end

    test "a port already taken is the engine's refusal, with its message" do
      {:ok, taken} = :gen_tcp.listen(0, [:binary, ip: {0, 0, 0, 0}])
      {:ok, port} = :inet.port(taken)
      on_exit(fn -> :gen_tcp.close(taken) end)

      name =
        container(unique("app"), ["sleep", "300"], %{
          "ExposedPorts" => %{"80/tcp" => %{}},
          "HostConfig" => %{"PortBindings" => %{"80/tcp" => [%{"HostPort" => "#{port}"}]}}
        })

      assert {:error, {:status, 500, message}} = Container.start(name)
      assert message =~ "address already in use"
    end

    test "image_present?/2" do
      assert Container.image_present?(@busybox) == {:ok, true}
      assert Container.image_present?("#{unique("vagus-no-image")}:1") == {:ok, false}
    end
  end

  describe "Vagus.App.Pulls" do
    test "pulls through the lane, and its last summary has every layer done" do
      borrowed(@tiny)
      test = self()
      instance = instance()

      :ok =
        Pulls.request(@tiny, waiter(),
          instance: instance,
          on_progress: &send(test, {:progress, &1})
        )

      assert_receive {:"$gen_cast", {:enqueue, "app"}}, 120_000
      assert Pulls.state(@tiny, instance: instance) == :idle
      assert Container.image_present?(@tiny) == {:ok, true}

      summaries = collect_progress()
      last = List.last(summaries)
      assert "Status: " <> _ = last.status
      assert last.layers_done == last.layers
      assert last.current == last.total
      # A pull that had something to fetch said so on the way.
      if last.layers > 0, do: assert(Enum.any?(summaries, &(&1.layers_done < &1.layers)))
    end

    test "a reference that does not exist is remembered as a failure" do
      instance = instance()
      image = "#{unique("vagus-does-not-exist")}:nope"

      :ok = Pulls.request(image, waiter(), instance: instance)
      assert_receive {:"$gen_cast", {:enqueue, "app"}}, 120_000

      assert {:failed, {:status, 404, "pull access denied for " <> _}, %Stamp{}} =
               Pulls.state(image, instance: instance)
    end
  end

  # The pull has ended, so every summary it passed on is in the mailbox.
  defp collect_progress do
    receive do
      {:progress, progress} -> [progress | collect_progress()]
    after
      0 -> []
    end
  end
end
