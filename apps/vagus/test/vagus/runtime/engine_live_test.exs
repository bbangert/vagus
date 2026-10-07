defmodule Vagus.Runtime.EngineLiveTest do
  @moduledoc """
  The engine layer against a real engine at the default socket. Excluded by
  default: `mix test --only docker`.

  Every container made here has a name unique to the run and is removed with
  it. An image is removed only if this run was what pulled it.
  """

  use ExUnit.Case, async: false

  alias Vagus.App.Backend.Container
  alias Vagus.App.Pulls
  alias Vagus.Resource.{Runtime, TestInstance}
  alias Vagus.Runtime.{Docker, Events}

  @moduletag :docker
  @moduletag timeout: 180_000

  @busybox "busybox:latest"
  @tiny "hello-world:linux"

  setup_all do
    :ok = Docker.pull_image(@busybox)
  end

  defp unique(prefix), do: "#{prefix}_vagustest_#{System.unique_integer([:positive])}"

  defp container(name, cmd, extra \\ %{}) do
    config =
      Map.merge(
        %{"Image" => @busybox, "Cmd" => ["sh", "-c", cmd], "Labels" => %{"vagustest" => name}},
        extra
      )

    on_exit(fn -> Docker.remove_container(name, force: true) end)
    {:ok, _id} = Docker.create_container(config, name: name)
    name
  end

  # Removes the image afterwards unless it was here before.
  defp borrowed(image) do
    case Docker.inspect_image(image) do
      {:ok, _present} ->
        :ok

      {:error, {:http, 404, _message}} ->
        on_exit(fn -> Docker.remove_image(image) end)
    end
  end

  defp since(nano) do
    fraction = nano |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{div(nano, 1_000_000_000)}.#{fraction}"
  end

  defp replay(name, since, until) do
    filters = Jason.encode!(%{"type" => ["container"], "container" => [name]})
    query = [since: since, until: until, filters: filters]
    {:ok, %{status: 200, body: body}} = Docker.request(:get, "/events", query: query)

    # One line is valid JSON by itself, and the client has decoded it.
    case body do
      empty when empty == %{} -> []
      %{} = event -> [event]
      text -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end
  end

  describe "pull_image_stream/4" do
    test "a real pull streams progress lines and leaves the image present" do
      borrowed(@tiny)
      _ = Docker.remove_image(@tiny)

      assert {:ok, lines} = Docker.pull_image_stream(@tiny, [], &[&1 | &2])
      lines = Enum.reverse(lines)

      IO.puts(
        "live pull: #{length(lines)} lines, statuses #{inspect(Enum.uniq(for l <- lines, do: l["status"]))}"
      )

      assert length(lines) >= 2
      assert Enum.all?(lines, &is_binary(&1["status"]))
      assert {:ok, _image} = Docker.inspect_image(@tiny)
    end

    test "a reference that does not exist fails, in the stream or as a status" do
      image = "vagus-does-not-exist-#{System.unique_integer([:positive])}:nope"

      assert {:error, reason} = Docker.pull_image_stream(image, [], &[&1 | &2])
      failure = Docker.failure(reason)
      IO.puts("live pull of a missing reference: #{inspect(failure)}")

      assert match?({:stream, _message}, failure) or match?({:status, 404, _message}, failure)
    end
  end

  describe "list_containers/1 filters" do
    test "name and label filters narrow the listing in the engine" do
      app = container(unique("app"), "sleep 300")
      other = container(unique("other"), "sleep 300")
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
      assert names.(all: true, filters: %{name: ["^app_vagustest_"]}) == [app]

      assert names.(all: true, filters: %{name: ["^#{app}$", "^#{other}$"]}) ==
               Enum.sort([app, other])

      assert names.(all: true, filters: %{label: ["vagustest=#{other}"]}) == [other]
      assert names.(all: true, filters: %{label: ["vagustest"], name: ["^#{app}$"]}) == [app]

      {:ok, [listed]} = Docker.list_containers(all: true, filters: %{name: ["^#{app}$"]})

      assert %{names: [^app], image: @busybox, state: "running", labels: %{"vagustest" => ^app}} =
               Docker.summary(listed)
    end

    test "Container.list/1 finds an app_ container and not a bystander" do
      app = container(unique("app"), "sleep 300")
      other = container(unique("other"), "sleep 300")

      assert {:ok, listed} = Container.list()
      names = Enum.flat_map(listed, & &1.names)
      assert app in names
      refute other in names
    end
  end

  describe "events" do
    test "since replays from that instant, inclusive, in the form the worker sends" do
      name = container(unique("app"), "sleep 300")
      :ok = Docker.start_container(name)
      until = System.os_time(:second) + 1

      assert [
               %{"Action" => "create", "timeNano" => created},
               %{"Action" => "start", "timeNano" => started}
             ] =
               replay(name, 0, until)

      assert [%{"Action" => "create"}, %{"Action" => "start"}] =
               replay(name, since(created), until)

      assert [%{"Action" => "start"}] = replay(name, since(created + 1), until)
      assert [%{"Action" => "start"}] = replay(name, since(started), until)
      assert [] = replay(name, since(started + 1), until)
    end

    test "the worker resumes after a drop: the missed event once, the seen one not again" do
      name = container(unique("app"), "sleep 300")
      events = start_supervised!({Events, name: :"#{name}_events", backoff: {300, 300}})
      :ok = Events.subscribe(events)
      assert_receive {:docker_events, :gap}, 5_000

      :ok = Docker.start_container(name)
      assert_receive {:docker_event, %{action: "start", name: ^name}}, 5_000

      # The stream ends for the worker, as if the engine had closed it, and
      # the container dies while nothing is listening.
      send(events, {:tcp_closed, Mint.HTTP.get_socket(:sys.get_state(events).conn)})
      :ok = Docker.stop_container(name, timeout: 0)

      assert_receive {:docker_events, :gap}, 5_000
      assert_receive {:docker_event, %{action: "die", name: ^name}}, 5_000
      refute_received {:docker_event, %{action: "start", name: ^name}}
    end

    test "a restart by the engine's policy is die then start, a higher count and a new start time" do
      name =
        container(unique("app"), "sleep 1; exit 3", %{
          "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}}
        })

      events = start_supervised!({Events, name: :"#{name}_events"})
      :ok = Events.subscribe(events)
      assert_receive {:docker_events, :gap}, 5_000

      :ok = Docker.start_container(name)
      assert_receive {:docker_event, %{action: "start", name: ^name}}, 5_000
      {:ok, first} = Container.observe(name)

      assert_receive {:docker_event, %{action: "die", name: ^name, exit_code: 3}}, 10_000
      assert_receive {:docker_event, %{action: "start", name: ^name}}, 10_000
      {:ok, second} = Container.observe(name)

      assert second.restart_count > first.restart_count
      assert second.started_at != first.started_at
      assert second.id == first.id
      refute_received {:docker_event, %{action: "restart", name: ^name}}
    end
  end

  describe "stop with a grace" do
    # Ignores the stop signal, so the engine waits out the grace and kills.
    @stubborn "trap '' TERM; while true; do sleep 1; done"

    test "the engine answers only once the grace is over" do
      name = container(unique("app"), @stubborn)
      :ok = Docker.start_container(name)

      began = System.monotonic_time(:millisecond)
      assert :ok = Container.stop(name, 2)
      took = System.monotonic_time(:millisecond) - began

      IO.puts("live stop with a 2 s grace took #{took} ms")
      assert took >= 2_000
      assert {:ok, %{state: :exited, exit_code: 137}} = Container.observe(name)
    end

    test "a call that gives up first does not stop the stop" do
      name = container(unique("app"), @stubborn)
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

      assert {:ok, id} = Container.create(name, config)
      assert Container.create(name, config) == {:error, :already_exists}

      assert {:ok, %{id: ^id, state: :created, started_at: nil, address: nil, health: :none}} =
               Container.observe(name)

      assert :ok = Container.start(name)
      assert :ok = Container.start(name)

      assert {:ok, %{state: :running, restart_count: 0, image: @busybox} = running} =
               Container.observe(name)

      assert running.env["SUPERVISOR_TOKEN"] == "t0ken"
      assert is_binary(running.started_at) and is_binary(running.address)

      assert :ok = Container.stop(name, 0)
      assert :ok = Container.stop(name, 0)
      assert {:ok, %{state: :exited, exit_code: 137, address: nil}} = Container.observe(name)

      assert :ok = Container.remove(name)
      assert :ok = Container.remove(name)
      assert Container.observe(name) == {:ok, :absent}
      assert Container.stop(name, 0) == :ok
      assert {:error, {:status, 404, _message}} = Container.start(name)
    end

    test "a port already taken is the engine's refusal, with its message" do
      {:ok, taken} = :gen_tcp.listen(0, [:binary, ip: {0, 0, 0, 0}])
      {:ok, port} = :inet.port(taken)
      on_exit(fn -> :gen_tcp.close(taken) end)

      name =
        container(unique("app"), "sleep 300", %{
          "ExposedPorts" => %{"80/tcp" => %{}},
          "HostConfig" => %{"PortBindings" => %{"80/tcp" => [%{"HostPort" => "#{port}"}]}}
        })

      assert {:error, {:status, status, message}} = Container.start(name)
      IO.puts("live start on a taken port: #{status} #{inspect(message)}")
      assert status in [400, 500]
      assert message =~ "already"
    end

    test "image_present?/2" do
      assert Container.image_present?(@busybox) == {:ok, true}
      assert Container.image_present?("vagus-does-not-exist:nope") == {:ok, false}
    end
  end

  describe "Vagus.App.Pulls" do
    test "pulls through the lane, reports progress and wakes its waiter" do
      borrowed(@tiny)
      _ = Docker.remove_image(@tiny)
      test = self()

      instance = TestInstance.start!()
      Process.register(self(), Runtime.name(instance, __MODULE__.Waits))

      :ok =
        Pulls.request(@tiny,
          instance: instance,
          waiter: {__MODULE__.Waits, "app"},
          on_progress: &send(test, {:progress, &1})
        )

      assert_receive {:"$gen_cast", {:enqueue, "app"}}, 120_000
      assert_received {:progress, %{status: status}} when is_binary(status)
      assert Pulls.state(@tiny, instance: instance) == :idle
      assert Container.image_present?(@tiny) == {:ok, true}
    end

    test "a reference that does not exist is remembered as a failure" do
      instance = TestInstance.start!()
      Process.register(self(), Runtime.name(instance, __MODULE__.Waits))
      image = "vagus-does-not-exist-#{System.unique_integer([:positive])}:nope"

      :ok = Pulls.request(image, instance: instance, waiter: {__MODULE__.Waits, "app"})
      assert_receive {:"$gen_cast", {:enqueue, "app"}}, 120_000

      assert {:failed, failure, %Vagus.Resource.Stamp{}} = Pulls.state(image, instance: instance)
      assert match?({:stream, _message}, failure) or match?({:status, 404, _message}, failure)
    end
  end
end
