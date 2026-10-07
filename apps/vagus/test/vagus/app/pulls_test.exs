defmodule Vagus.App.PullsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.App.Backend.Container
  alias Vagus.App.Pulls
  alias Vagus.Resource.{Lanes, Runtime, Stamp, TestClock, TestInstance}
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log

  defmodule Crashing do
    @moduledoc "An engine client whose pull dies."
    def pull_image_stream(_image, _acc, _fun, _opts), do: raise("the pull died")
  end

  setup context do
    engine = FakeEngine.start_model(notify: self())
    on_exit(fn -> FakeEngine.stop(engine) end)
    clock = start_supervised!(TestClock)

    pulls =
      Keyword.merge(
        [engine: [socket: engine.socket], clock: TestClock.clock(clock), progress_interval: 0],
        Map.get(context, :pulls, [])
      )

    instance = TestInstance.start!(pulls: pulls)
    i = [instance: instance]

    # Wake-ups are casts to the runtime of the waiter's controller. This
    # test is that runtime, for a controller that exists only as a name.
    Process.register(self(), Runtime.name(instance, __MODULE__.Waits))

    %{
      engine: engine,
      clock: clock,
      instance: instance,
      i: i,
      engine_opts: [engine: [socket: engine.socket]]
    }
  end

  defp waiter(name), do: {__MODULE__.Waits, name}

  defmacrop assert_woken(name) do
    quote do
      assert_receive {:"$gen_cast", {:enqueue, unquote(name)}}, 2_000
    end
  end

  defmacrop refute_woken(name) do
    quote do
      refute_received {:"$gen_cast", {:enqueue, unquote(name)}}
    end
  end

  defp requests(engine, path \\ "/images/create"),
    do: for(%{path: ^path} = request <- FakeEngine.requests(engine), do: request.query)

  # A pull that has read one line and then hears nothing more. Returns once
  # it is there, with the pull's task.
  defp stalled(context, image, opts \\ []) do
    test = self()
    Model.script_pull(context.engine, image, {:stall, [Model.downloading("l1", 1, 2)]})

    :ok =
      Pulls.request(
        image,
        [on_progress: &send(test, {:progress, image, &1})] ++ opts ++ context.i
      )

    assert_receive {:progress, ^image, _progress}, 2_000
    Pulls.info(context.i)[image].task
  end

  # Returns once `count` requests for the pull lane have reached the lanes.
  defp traced_lanes(instance) do
    lanes = Process.whereis(Lanes.name(instance))
    :erlang.trace(lanes, true, [:receive])
    lanes
  end

  defmacrop assert_lane_asked(lanes) do
    quote do
      assert_receive {:trace, ^unquote(lanes), :receive,
                      {:"$gen_call", _from, {:acquire, :pull, _priority}}},
                     2_000
    end
  end

  describe "request/2" do
    test "returns while the pull is still running, and state/2 says it is", context do
      stalled(context, "repo/a:1", waiter: waiter("a"))

      assert {:pulling, %{current: 1, total: 2}} = Pulls.state("repo/a:1", context.i)
      refute_woken("a")
    end

    test "a pull that succeeds leaves :idle, the image present, and wakes its waiter", context do
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)

      assert_woken("a")
      assert Pulls.state("repo/a:1", context.i) == :idle
      assert Container.image_present?("repo/a:1", context.engine_opts) == {:ok, true}
      assert Pulls.info(context.i) == %{}
    end

    test "a second request for a reference being pulled joins that pull", context do
      task = stalled(context, "repo/a:1", waiter: waiter("a"))

      :ok = Pulls.request("repo/a:1", [waiter: waiter("b")] ++ context.i)

      assert %{"repo/a:1" => %{task: ^task, waiters: waiters}} = Pulls.info(context.i)
      assert Enum.sort(waiters) == [waiter("a"), waiter("b")]
      assert length(requests(context.engine)) == 1
    end

    test "when a pull ends, every waiter of it is woken and nobody else", context do
      test = self()

      Model.script_pull(context.engine, "repo/a:1", {
        :steps,
        [
          {:line, Model.downloading("l1", 1, 2)},
          {:run, fn -> send(test, {:held, self()}) && receive(do: (:go -> :ok)) end}
        ]
      })

      stalled(context, "repo/other:1", waiter: waiter("c"))
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      :ok = Pulls.request("repo/a:1", [waiter: waiter("b")] ++ context.i)
      :ok = Pulls.cancel("repo/other:1", context.i)
      assert_woken("c")

      assert_receive {:held, handler}, 2_000
      send(handler, :go)

      assert_woken("a")
      assert_woken("b")
      refute_woken("c")
    end

    test "the platform asked for is the engine's platform parameter", context do
      :ok = Pulls.request("repo/a:1", [platform: "linux/arm64", waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert [%{"fromImage" => "repo/a", "tag" => "1", "platform" => "linux/arm64"}] =
               requests(context.engine)
    end

    test "with no worker it exits", _context do
      assert {:noproc, _call} =
               catch_exit(Pulls.request("repo/a:1", instance: __MODULE__.Nowhere))
    end
  end

  describe "a failed pull" do
    test "an error in the stream is remembered with the reason and when", context do
      Model.script_pull(context.engine, "repo/a:1", {:error, "manifest unknown"})
      TestClock.advance(context.clock, 1_234)

      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert Pulls.state("repo/a:1", context.i) ==
               {:failed, {:stream, "manifest unknown"}, %Stamp{incarnation: 1, at: 1_234}}
    end

    test "an image the registry does not have is the engine's status", context do
      Model.script_pull(context.engine, "repo/a:1", :not_found)

      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert {:failed, {:status, 404, "pull access denied for repo/a"}, %Stamp{}} =
               Pulls.state("repo/a:1", context.i)
    end

    @tag pulls: [engine: [socket: "/tmp/vagus-pulls-no-engine.sock"]]
    test "an engine that is away is a failure that says so", context do
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert {:failed, {:unreachable, :enoent}, %Stamp{}} = Pulls.state("repo/a:1", context.i)
    end

    @tag pulls: [client: Crashing]
    test "a pull that dies is a failure too, and its waiter is woken", context do
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert {:failed, {:crashed, {%RuntimeError{message: "the pull died"}, _stack}}, %Stamp{}} =
               Pulls.state("repo/a:1", context.i)
    end

    test "is not retried by itself; the next request pulls again", context do
      Model.script_pull(context.engine, "repo/a:1", {:error, "manifest unknown"})
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")
      assert length(requests(context.engine)) == 1

      Model.script_pull(context.engine, "repo/a:1", :ok)
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert Pulls.state("repo/a:1", context.i) == :idle
      assert length(requests(context.engine)) == 2
    end

    test "is forgotten on cancel", context do
      Model.script_pull(context.engine, "repo/a:1", {:error, "manifest unknown"})
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")

      assert :ok = Pulls.cancel("repo/a:1", context.i)
      assert Pulls.state("repo/a:1", context.i) == :idle
    end
  end

  describe "cancel/2" do
    test "ends the pull: the task is gone, the engine's connection closed, the waiter woken",
         context do
      task = stalled(context, "repo/a:1", waiter: waiter("a"))
      monitor = Process.monitor(task)

      assert :ok = Pulls.cancel("repo/a:1", context.i)

      assert_receive {:DOWN, ^monitor, :process, ^task, :shutdown}, 2_000
      assert_receive {:fake_engine, :client_closed, "/images/create"}, 2_000
      assert_woken("a")
      assert Pulls.state("repo/a:1", context.i) == :idle
      assert Pulls.info(context.i) == %{}
    end

    test "by one of two waiters withdraws it and leaves the pull running", context do
      task = stalled(context, "repo/a:1", waiter: waiter("a"))
      :ok = Pulls.request("repo/a:1", [waiter: waiter("b")] ++ context.i)

      assert :ok = Pulls.cancel("repo/a:1", [waiter: waiter("a")] ++ context.i)

      assert Pulls.info(context.i) == %{"repo/a:1" => %{task: task, waiters: [waiter("b")]}}
      assert {:pulling, _progress} = Pulls.state("repo/a:1", context.i)
      refute_woken("a")
      refute_woken("b")
    end

    test "by the last waiter ends the pull", context do
      task = stalled(context, "repo/a:1", waiter: waiter("a"))
      monitor = Process.monitor(task)

      assert :ok = Pulls.cancel("repo/a:1", [waiter: waiter("a")] ++ context.i)

      assert_receive {:DOWN, ^monitor, :process, ^task, :shutdown}, 2_000
      assert Pulls.state("repo/a:1", context.i) == :idle
      assert_woken("a")
    end

    test "of a reference nobody pulls is :ok", context do
      assert :ok = Pulls.cancel("repo/none:1", context.i)
    end

    test "a pull cancelled can be requested again", context do
      stalled(context, "repo/a:1", waiter: waiter("a"))
      :ok = Pulls.cancel("repo/a:1", context.i)
      assert_woken("a")

      Model.script_pull(context.engine, "repo/a:1", :ok)
      :ok = Pulls.request("repo/a:1", [waiter: waiter("a")] ++ context.i)
      assert_woken("a")
      assert Container.image_present?("repo/a:1", context.engine_opts) == {:ok, true}
    end
  end

  describe "the pull lane" do
    test "one pull runs at a time; the next waits its turn with nothing asked of the engine",
         context do
      lanes = traced_lanes(context.instance)
      stalled(context, "repo/a:1", waiter: waiter("a"))
      assert_lane_asked(lanes)

      :ok = Pulls.request("repo/b:1", [waiter: waiter("b")] ++ context.i)
      assert_lane_asked(lanes)

      first = Pulls.info(context.i)["repo/a:1"].task
      assert %{pull: %{cap: 1, held: [^first], waiting: 1}} = Lanes.info(context.i)
      assert Pulls.state("repo/b:1", context.i) == {:pulling, nil}
      assert [%{"fromImage" => "repo/a"}] = requests(context.engine)

      :ok = Pulls.cancel("repo/a:1", context.i)
      assert_woken("b")
      assert [%{"fromImage" => "repo/a"}, %{"fromImage" => "repo/b"}] = requests(context.engine)
    end

    test "the lane goes to the waiting pull with the lowest priority number", context do
      lanes = traced_lanes(context.instance)
      stalled(context, "repo/a:1")
      assert_lane_asked(lanes)

      :ok = Pulls.request("repo/late:1", [priority: 5] ++ context.i)
      assert_lane_asked(lanes)
      :ok = Pulls.request("repo/first:1", [priority: 1, waiter: waiter("first")] ++ context.i)
      assert_lane_asked(lanes)

      Model.script_pull(context.engine, "repo/late:1", {:stall, []})
      :ok = Pulls.cancel("repo/a:1", context.i)
      assert_woken("first")

      assert [%{"fromImage" => "repo/a"}, %{"fromImage" => "repo/first"} | _] =
               requests(context.engine)
    end

    test "a pull cancelled while it waits for the lane leaves the line", context do
      lanes = traced_lanes(context.instance)
      stalled(context, "repo/a:1")
      assert_lane_asked(lanes)
      :ok = Pulls.request("repo/b:1", context.i)
      assert_lane_asked(lanes)

      :ok = Pulls.cancel("repo/b:1", context.i)
      :ok = Pulls.cancel("repo/a:1", context.i)
      :ok = Pulls.request("repo/c:1", [waiter: waiter("c")] ++ context.i)
      assert_woken("c")

      assert [%{"fromImage" => "repo/a"}, %{"fromImage" => "repo/c"}] = requests(context.engine)
    end
  end

  defp next_progress do
    receive do
      {:progress, progress} -> progress
    after
      2_000 -> flunk("no progress")
    end
  end

  describe "progress" do
    test "summarises the layers seen so far, in the table and to the request's function",
         context do
      test = self()

      Model.script_pull(context.engine, "repo/a:1", {
        :stall,
        [
          %{"status" => "Pulling from repo/a", "id" => "1"},
          %{"status" => "Pulling fs layer", "id" => "l1"},
          Model.downloading("l1", 50, 100),
          Model.downloading("l2", 10, 300),
          %{"status" => "Download complete", "id" => "l1"},
          %{"status" => "Already exists", "id" => "l0"},
          %{
            "status" => "Extracting",
            "id" => "l1",
            "progressDetail" => %{"current" => 1, "total" => 9}
          }
        ]
      })

      :ok = Pulls.request("repo/a:1", [on_progress: &send(test, {:progress, &1})] ++ context.i)

      seen = for _line <- 1..7, do: next_progress()

      assert Enum.at(seen, 0) == %{
               status: "Pulling from repo/a",
               current: 0,
               total: 0,
               layers: 0,
               layers_done: 0
             }

      assert Enum.at(seen, 1) == %{
               status: "Pulling fs layer",
               current: 0,
               total: 0,
               layers: 1,
               layers_done: 0
             }

      assert Enum.at(seen, 2) == %{
               status: "Downloading",
               current: 50,
               total: 100,
               layers: 1,
               layers_done: 0
             }

      assert Enum.at(seen, 3) == %{
               status: "Downloading",
               current: 60,
               total: 400,
               layers: 2,
               layers_done: 0
             }

      assert Enum.at(seen, 4) == %{
               status: "Download complete",
               current: 110,
               total: 400,
               layers: 2,
               layers_done: 1
             }

      assert Enum.at(seen, 5) == %{
               status: "Already exists",
               current: 110,
               total: 400,
               layers: 3,
               layers_done: 2
             }

      assert Enum.at(seen, 6) == %{
               status: "Extracting",
               current: 110,
               total: 400,
               layers: 3,
               layers_done: 2
             }

      # The call that carried the last summary wrote the table before it
      # answered the task, which then ran the function.
      assert Pulls.state("repo/a:1", context.i) == {:pulling, Enum.at(seen, 6)}
    end

    @tag pulls: [progress_interval: 3_600_000]
    test "a pull that reports faster than the interval is passed on once per interval", context do
      test = self()
      lines = for n <- 1..200, do: Model.downloading("l1", n, 200)
      Model.script_pull(context.engine, "repo/a:1", {:lines, lines})

      :ok =
        Pulls.request(
          "repo/a:1",
          [on_progress: &send(test, {:progress, &1}), waiter: waiter("a")] ++ context.i
        )

      assert_woken("a")
      assert_received {:progress, %{current: 1, total: 200}}
      refute_received {:progress, _later}
    end

    test "a request that joins has its function told from then on", context do
      test = self()

      Model.script_pull(context.engine, "repo/a:1", {
        :steps,
        [
          {:line, Model.downloading("l1", 1, 3)},
          {:run, fn -> send(test, {:held, self()}) && receive(do: (:go -> :ok)) end},
          {:line, Model.downloading("l1", 2, 3)},
          :stall
        ]
      })

      :ok =
        Pulls.request("repo/a:1", [on_progress: &send(test, {:first, &1.current})] ++ context.i)

      assert_receive {:first, 1}, 2_000

      :ok =
        Pulls.request("repo/a:1", [on_progress: &send(test, {:second, &1.current})] ++ context.i)

      assert_receive {:held, handler}, 2_000
      send(handler, :go)

      assert_receive {:first, 2}, 2_000
      assert_receive {:second, 2}, 2_000
      refute_received {:second, 1}
    end

    test "a progress function that raises costs the pull nothing", context do
      test = self()

      log =
        capture_log(fn ->
          :ok =
            Pulls.request(
              "repo/a:1",
              [
                on_progress: fn _progress -> raise "not the pull's problem" end,
                waiter: waiter("a")
              ] ++ context.i
            )

          assert_woken("a")
          send(test, :done)
        end)

      assert_received :done
      assert Pulls.state("repo/a:1", context.i) == :idle
      assert Container.image_present?("repo/a:1", context.engine_opts) == {:ok, true}
      assert log =~ "a progress function failed"
    end

    test "progress from anyone but the pull's own task changes nothing", context do
      task = stalled(context, "repo/a:1")
      before = Pulls.state("repo/a:1", context.i)

      worker = Process.whereis(Pulls.name(context.instance))
      assert GenServer.call(worker, {:progress, "repo/a:1", %{status: "forged"}}) == []

      assert Pulls.state("repo/a:1", context.i) == before
      assert Pulls.info(context.i)["repo/a:1"].task == task
    end
  end

  describe "the worker" do
    test "state/2 answers while the worker cannot", context do
      stalled(context, "repo/a:1")
      worker = Process.whereis(Pulls.name(context.instance))
      :ok = :sys.suspend(worker)

      reading = Task.async(fn -> Pulls.state("repo/a:1", context.i) end)

      assert {:ok, {:pulling, %{current: 1}}} =
               Task.yield(reading, 2_000) || Task.shutdown(reading)

      :ok = :sys.resume(worker)
    end

    test "state/2 with no worker is :idle" do
      assert Pulls.state("repo/a:1", instance: __MODULE__.Nowhere) == :idle
    end

    test "when it dies its pulls die with it, and their connections close", context do
      task = stalled(context, "repo/a:1", waiter: waiter("a"))
      monitor = Process.monitor(task)
      worker = Process.whereis(Pulls.name(context.instance))
      tasks = Process.whereis(Pulls.tasks(context.instance))
      supervisor = Process.whereis(Module.concat(context.instance, Supervisor))

      TestInstance.kill_observed(worker, supervisor)

      assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 2_000
      assert_receive {:fake_engine, :client_closed, "/images/create"}, 2_000

      # The replacement knows of no pull, and none is running to contradict it.
      assert Process.whereis(Pulls.name(context.instance)) != worker
      assert Process.whereis(Pulls.tasks(context.instance)) != tasks
      assert Pulls.info(context.i) == %{}
      assert Pulls.state("repo/a:1", context.i) == :idle
    end

    test "when it dies, the runtimes after it are replaced and look at everything", context do
      controllers = Process.whereis(Vagus.Resource.Controllers.Supervisor.name(context.instance))
      worker = Process.whereis(Pulls.name(context.instance))
      supervisor = Process.whereis(Module.concat(context.instance, Supervisor))

      TestInstance.kill_observed(worker, supervisor)

      replaced = Process.whereis(Vagus.Resource.Controllers.Supervisor.name(context.instance))
      assert is_pid(replaced) and replaced != controllers
    end

    test "when the lanes die, its pulls end and it starts over with them", context do
      task = stalled(context, "repo/a:1")
      monitor = Process.monitor(task)
      worker = Process.whereis(Pulls.name(context.instance))
      supervisor = Process.whereis(Module.concat(context.instance, Supervisor))

      TestInstance.kill_observed(Process.whereis(Lanes.name(context.instance)), supervisor)

      assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 2_000
      assert Process.whereis(Pulls.name(context.instance)) != worker
      assert Pulls.state("repo/a:1", context.i) == :idle
    end
  end
end
