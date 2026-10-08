defmodule Vagus.App.PullsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.App.Backend.Container
  alias Vagus.App.Pulls
  alias Vagus.Resource.{Lanes, Runtime, Stamp, TestClock, TestInstance}
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log

  defmodule Chatty do
    @moduledoc """
    An engine client whose pull is 200 lines at once, and which then tells
    the test named in its options how many it fed.
    """
    def pull_image_stream(_image, acc, fun, opts) do
      line = &Vagus.Test.FakeEngine.Model.downloading("l1", &1, 200)
      acc = Enum.reduce(1..200, acc, &fun.(line.(&1), &2))
      send(Keyword.fetch!(opts, :test), {:fed, 200})
      {:ok, acc}
    end
  end

  defmodule Crashing do
    @moduledoc "An engine client whose pull dies."
    def pull_image_stream(_image, _acc, _fun, _opts), do: raise("the pull died")
  end

  setup context do
    engine = FakeEngine.start_model(notify: self())
    on_exit(fn -> FakeEngine.stop(engine) end)
    clock = start_supervised!(TestClock)
    instance = TestInstance.name()

    pulls =
      Keyword.merge(
        [
          instance: instance,
          engine: [socket: engine.socket, test: self()],
          clock: TestClock.clock(clock),
          progress_interval: 0
        ],
        Map.get(context, :pulls, [])
      )

    # As the application places it: among the resource supervisor's services.
    TestInstance.start!(instance: instance, services: Pulls.child_specs(pulls))

    # Wake-ups are casts to the runtime of the waiter's controller. This
    # test is that runtime, for a controller that exists only as a name.
    Process.register(self(), Runtime.name(instance, __MODULE__.Waits))

    %{
      engine: engine,
      clock: clock,
      instance: instance,
      i: [instance: instance],
      engine_opts: [engine: [socket: engine.socket]]
    }
  end

  defp waiter(name), do: {__MODULE__.Waits, name}

  defmacrop assert_woken(name) do
    quote do
      assert_receive {:"$gen_cast", {:enqueue, unquote(name)}}, 2_000
    end
  end

  # The worker's answer comes after any wake-up it had sent this process
  # before answering: the same sender, the same receiver.
  defmacrop refute_woken(context, name) do
    quote do
      Pulls.info(unquote(context).i)
      refute_received {:"$gen_cast", {:enqueue, unquote(name)}}
    end
  end

  defp requests(engine),
    do: for(%{path: "/images/create"} = request <- FakeEngine.requests(engine), do: request.query)

  # A pull that has read one line and then hears nothing more, asked for by
  # `who`. Returns once it is there, with the pull's task.
  defp stalled(context, image, who, opts \\ []) do
    test = self()
    Model.script_pull(context.engine, image, {:stall, [Model.downloading("l1", 1, 2)]})

    :ok =
      Pulls.request(
        image,
        waiter(who),
        [on_progress: &send(test, {:progress, image, &1})] ++ opts ++ context.i
      )

    assert_receive {:progress, ^image, _progress}, 2_000
    Pulls.info(context.i)[image].task
  end

  # A pull whose engine writes `lines`, then waits for `:go` from the test,
  # which is sent `{:held, handler}`, then writes `more` and falls silent,
  # or with `:end` ends the stream as a pull that worked.
  defp held(context, image, lines, more, last \\ :stall) do
    test = self()

    steps =
      Enum.map(lines, &{:line, &1}) ++
        [{:run, fn -> send(test, {:held, self()}) && receive(do: (:go -> :ok)) end}] ++
        Enum.map(more, &{:line, &1}) ++ if(last == :stall, do: [:stall], else: [])

    Model.script_pull(context.engine, image, {:steps, steps})
  end

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

  defp next_progress do
    receive do
      {:progress, progress} -> progress
    after
      2_000 -> flunk("no progress")
    end
  end

  # The summaries a pull of these lines passes on, one a line.
  defp summaries(context, lines) do
    test = self()
    Model.script_pull(context.engine, "repo/a:1", {:stall, lines})

    :ok =
      Pulls.request(
        "repo/a:1",
        waiter("a"),
        [on_progress: &send(test, {:progress, &1})] ++ context.i
      )

    for _line <- lines, do: next_progress()
  end

  describe "request/3" do
    test "returns while the pull is still running, and state/2 says it is", context do
      stalled(context, "repo/a:1", "a")

      assert {:pulling, %{current: 1, total: 2}} = Pulls.state("repo/a:1", context.i)
      refute_woken(context, "a")
    end

    test "a pull that succeeds leaves :idle, the image present, and wakes its waiter", context do
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)

      assert_woken("a")
      assert Pulls.state("repo/a:1", context.i) == :idle
      assert Container.image_present?("repo/a:1", context.engine_opts) == {:ok, true}
      assert Pulls.info(context.i) == %{}
    end

    test "a second request for a reference being pulled joins that pull", context do
      task = stalled(context, "repo/a:1", "a")

      :ok = Pulls.request("repo/a:1", waiter("b"), context.i)

      assert Pulls.info(context.i) == %{
               "repo/a:1" => %{task: task, waiters: [waiter("a"), waiter("b")]}
             }

      assert length(requests(context.engine)) == 1
    end

    test "when a pull ends, every waiter of it is woken and nobody else", context do
      held(context, "repo/a:1", [Model.downloading("l1", 1, 2)], [], :end)
      Model.script_pull(context.engine, "repo/other:1", {:stall, []})

      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      :ok = Pulls.request("repo/a:1", waiter("b"), context.i)
      assert_receive {:held, handler}, 2_000
      # Asked for once the first has the lane: two pulls asked for together
      # race for it, and this one, had it won, would hold it for good.
      # It waits behind the first, and then hears nothing.
      :ok = Pulls.request("repo/other:1", waiter("c"), context.i)
      send(handler, :go)

      assert_woken("a")
      assert_woken("b")
      refute_woken(context, "c")
      assert Pulls.state("repo/a:1", context.i) == :idle
    end

    test "a waiter is one waiter however often it asks", context do
      task = stalled(context, "repo/a:1", "a")
      for _again <- 1..4, do: :ok = Pulls.request("repo/a:1", waiter("a"), context.i)

      assert Pulls.info(context.i) == %{"repo/a:1" => %{task: task, waiters: [waiter("a")]}}

      :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      assert_woken("a")
      refute_woken(context, "a")
    end

    test "the platform asked for is the engine's platform parameter", context do
      :ok = Pulls.request("repo/a:1", waiter("a"), [platform: "linux/arm64"] ++ context.i)
      assert_woken("a")

      assert [%{"fromImage" => "repo/a", "tag" => "1", "platform" => "linux/arm64"}] =
               requests(context.engine)
    end

    test "with no worker it exits", _context do
      assert {:noproc, _call} =
               catch_exit(Pulls.request("repo/a:1", waiter("a"), instance: __MODULE__.Nowhere))
    end

    test "a request names its waiter", context do
      # Read at run time, so that the compiler has no say on its type.
      nobody = Process.get(:no_such_waiter)
      assert_raise FunctionClauseError, fn -> Pulls.request("repo/a:1", nobody, context.i) end
    end
  end

  describe "a failed pull" do
    test "an error in the stream is remembered with the reason and when", context do
      Model.script_pull(context.engine, "repo/a:1", {:error, "manifest unknown"})
      TestClock.advance(context.clock, 1_234)

      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      assert Pulls.state("repo/a:1", context.i) ==
               {:failed, {:stream, "manifest unknown"}, %Stamp{incarnation: 1, at: 1_234}}
    end

    test "an image the registry does not have is the engine's status", context do
      Model.script_pull(context.engine, "repo/a:1", :not_found)

      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      assert {:failed, {:status, 404, "pull access denied for repo/a"}, %Stamp{}} =
               Pulls.state("repo/a:1", context.i)
    end

    @tag pulls: [engine: [socket: "/tmp/vagus-pulls-no-engine-#{System.pid()}.sock"]]
    test "an engine that is away is a failure that says so", context do
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      assert {:failed, {:unreachable, :enoent}, %Stamp{}} = Pulls.state("repo/a:1", context.i)
    end

    @tag pulls: [client: Crashing]
    test "a pull that dies is a failure too, and its waiter is woken", context do
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      assert {:failed, {:crashed, {%RuntimeError{message: "the pull died"}, _stack}}, %Stamp{}} =
               Pulls.state("repo/a:1", context.i)
    end

    test "is not retried by itself; the next request pulls again", context do
      Model.script_pull(context.engine, "repo/a:1", {:error, "manifest unknown"})
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      # Nothing is in flight and nothing was asked of the engine again.
      assert Pulls.info(context.i) == %{}
      assert {:failed, {:stream, "manifest unknown"}, _stamp} = Pulls.state("repo/a:1", context.i)

      Model.script_pull(context.engine, "repo/a:1", :ok)
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      assert Pulls.state("repo/a:1", context.i) == :idle
      assert length(requests(context.engine)) == 2
    end

    test "is forgotten on cancel", context do
      Model.script_pull(context.engine, "repo/a:1", {:error, "manifest unknown"})
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      assert :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      assert Pulls.state("repo/a:1", context.i) == :idle
    end
  end

  describe "cancel/3" do
    test "by the only waiter ends the pull: task gone, connection closed, waiter woken",
         context do
      task = stalled(context, "repo/a:1", "a")
      monitor = Process.monitor(task)

      assert :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)

      assert_receive {:DOWN, ^monitor, :process, ^task, :shutdown}, 2_000
      assert_receive {:fake_engine, :client_closed, "/images/create"}, 2_000
      assert_woken("a")
      assert Pulls.state("repo/a:1", context.i) == :idle
      assert Pulls.info(context.i) == %{}
    end

    test "by one of two waiters withdraws it and leaves the pull running", context do
      task = stalled(context, "repo/a:1", "a")
      :ok = Pulls.request("repo/a:1", waiter("b"), context.i)

      assert :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)

      assert Pulls.info(context.i) == %{"repo/a:1" => %{task: task, waiters: [waiter("b")]}}
      assert {:pulling, _progress} = Pulls.state("repo/a:1", context.i)
      refute_woken(context, "a")
      refute_woken(context, "b")
    end

    test "by someone who never asked leaves the pull and its waiter alone", context do
      task = stalled(context, "repo/a:1", "a")

      assert :ok = Pulls.cancel("repo/a:1", waiter("stranger"), context.i)

      assert Pulls.info(context.i) == %{"repo/a:1" => %{task: task, waiters: [waiter("a")]}}
      assert {:pulling, _progress} = Pulls.state("repo/a:1", context.i)
      refute_woken(context, "a")
    end

    test "of a reference nobody pulls is :ok", context do
      assert :ok = Pulls.cancel("repo/none:1", waiter("a"), context.i)
    end

    test "a pull cancelled can be requested again", context do
      stalled(context, "repo/a:1", "a")
      :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      assert_woken("a")

      Model.script_pull(context.engine, "repo/a:1", :ok)
      :ok = Pulls.request("repo/a:1", waiter("a"), context.i)
      assert_woken("a")
      assert Container.image_present?("repo/a:1", context.engine_opts) == {:ok, true}
    end
  end

  describe "the pull lane" do
    test "one pull runs at a time; the next waits its turn with nothing asked of the engine",
         context do
      lanes = traced_lanes(context.instance)
      first = stalled(context, "repo/a:1", "a")
      assert_lane_asked(lanes)

      :ok = Pulls.request("repo/b:1", waiter("b"), context.i)
      assert_lane_asked(lanes)

      assert %{pull: %{cap: 1, held: [^first], waiting: 1}} = Lanes.info(context.i)
      assert Pulls.state("repo/b:1", context.i) == {:pulling, nil}
      assert [%{"fromImage" => "repo/a"}] = requests(context.engine)

      :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      assert_woken("b")
      assert [%{"fromImage" => "repo/a"}, %{"fromImage" => "repo/b"}] = requests(context.engine)
    end

    test "the lane goes to the waiting pull with the lowest priority number", context do
      lanes = traced_lanes(context.instance)
      stalled(context, "repo/a:1", "a")
      assert_lane_asked(lanes)

      Model.script_pull(context.engine, "repo/late:1", {:stall, []})
      :ok = Pulls.request("repo/late:1", waiter("late"), [priority: 5] ++ context.i)
      assert_lane_asked(lanes)
      :ok = Pulls.request("repo/first:1", waiter("first"), [priority: 1] ++ context.i)
      assert_lane_asked(lanes)

      :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      assert_woken("first")

      assert [%{"fromImage" => "repo/a"}, %{"fromImage" => "repo/first"} | _] =
               requests(context.engine)
    end

    test "a pull cancelled while it waits for the lane leaves the line", context do
      lanes = traced_lanes(context.instance)
      stalled(context, "repo/a:1", "a")
      assert_lane_asked(lanes)
      :ok = Pulls.request("repo/b:1", waiter("b"), context.i)
      assert_lane_asked(lanes)

      :ok = Pulls.cancel("repo/b:1", waiter("b"), context.i)
      :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      :ok = Pulls.request("repo/c:1", waiter("c"), context.i)
      assert_woken("c")

      assert [%{"fromImage" => "repo/a"}, %{"fromImage" => "repo/c"}] = requests(context.engine)
    end
  end

  describe "progress" do
    test "a layer downloaded: bytes while it downloads, done from Download complete on",
         context do
      seen =
        summaries(context, [
          %{"status" => "Pulling from repo/a", "id" => "1"},
          %{"status" => "Pulling fs layer", "id" => "l1"},
          %{"status" => "Waiting", "id" => "l1"},
          Model.downloading("l1", 50, 100),
          %{"status" => "Verifying Checksum", "id" => "l1"},
          %{"status" => "Download complete", "id" => "l1"},
          %{
            "status" => "Extracting",
            "id" => "l1",
            "progressDetail" => %{"current" => 1, "total" => 9}
          },
          %{"status" => "Pull complete", "id" => "l1"},
          %{"status" => "Digest: sha256:abc"},
          %{"status" => "Status: Downloaded newer image for repo/a:1"}
        ])

      assert Enum.map(seen, &{&1.current, &1.total, &1.layers, &1.layers_done}) == [
               {0, 0, 0, 0},
               {0, 0, 1, 0},
               {0, 0, 1, 0},
               {50, 100, 1, 0},
               {50, 100, 1, 0},
               {100, 100, 1, 1},
               {100, 100, 1, 1},
               {100, 100, 1, 1},
               {100, 100, 1, 1},
               {100, 100, 1, 1}
             ]

      assert List.last(seen).status == "Status: Downloaded newer image for repo/a:1"

      # The call that carried the last summary wrote the table before it
      # answered the task, which then ran the function.
      assert Pulls.state("repo/a:1", context.i) == {:pulling, List.last(seen)}
    end

    test "a layer never seen downloading: waiting, then complete", context do
      seen =
        summaries(context, [
          %{"status" => "Pulling fs layer", "id" => "l1"},
          %{"status" => "Download complete", "id" => "l1"},
          %{"status" => "Pulling fs layer", "id" => "l2"},
          %{"status" => "Pull complete", "id" => "l2"}
        ])

      assert Enum.map(seen, &{&1.layers, &1.layers_done}) == [{1, 0}, {1, 1}, {2, 1}, {2, 2}]
    end

    test "a layer the engine already has is done from its first line", context do
      seen =
        summaries(context, [
          %{"status" => "Already exists", "id" => "l0"},
          %{"status" => "Pull complete", "id" => "l9"},
          Model.downloading("l1", 10, 300)
        ])

      assert Enum.map(seen, &{&1.current, &1.total, &1.layers, &1.layers_done}) ==
               [{0, 0, 1, 1}, {0, 0, 2, 2}, {10, 300, 3, 2}]
    end

    test "several layers are summed, and lines that name no layer change no count", context do
      seen =
        summaries(context, [
          Model.downloading("l1", 50, 100),
          Model.downloading("l2", 10, 300),
          %{"status" => "Download complete", "id" => "l1"},
          %{"status" => "Downloading", "id" => "l3"},
          %{"status" => "Downloading", "id" => "l2", "progressDetail" => %{}},
          %{"id" => "l4"},
          %{"status" => "Extracting", "id" => nil},
          %{"progressDetail" => %{"current" => 5, "total" => 5}}
        ])

      assert Enum.map(seen, &{&1.current, &1.total, &1.layers, &1.layers_done}) == [
               {50, 100, 1, 0},
               {60, 400, 2, 0},
               {110, 400, 2, 1},
               {110, 400, 3, 1},
               {110, 400, 3, 1},
               {110, 400, 3, 1},
               {110, 400, 3, 1},
               {110, 400, 3, 1}
             ]
    end

    @tag pulls: [progress_interval: 3_600_000, client: Chatty]
    test "a pull that reports faster than the interval is passed on once per interval", context do
      test = self()

      :ok =
        Pulls.request(
          "repo/a:1",
          waiter("a"),
          [on_progress: &send(test, {:progress, &1})] ++ context.i
        )

      # Sent by the pull's task after its last line, as the summaries are.
      assert_receive {:fed, 200}, 2_000
      assert_received {:progress, %{current: 1, total: 200}}
      refute_received {:progress, _later}
    end

    test "a request that joins has its function told from then on", context do
      test = self()
      held(context, "repo/a:1", [Model.downloading("l1", 1, 3)], [Model.downloading("l1", 2, 3)])

      :ok =
        Pulls.request(
          "repo/a:1",
          waiter("a"),
          [on_progress: &send(test, {:first, &1.current})] ++ context.i
        )

      assert_receive {:first, 1}, 2_000

      :ok =
        Pulls.request(
          "repo/a:1",
          waiter("b"),
          [on_progress: &send(test, {:second, &1.current})] ++ context.i
        )

      assert_receive {:held, handler}, 2_000
      send(handler, :go)

      assert_receive {:first, 2}, 2_000
      assert_receive {:second, 2}, 2_000
      refute_received {:second, 1}
    end

    test "a waiter has one function, that of its latest request", context do
      test = self()
      held(context, "repo/a:1", [Model.downloading("l1", 1, 3)], [Model.downloading("l1", 2, 3)])

      for n <- 1..5 do
        :ok =
          Pulls.request(
            "repo/a:1",
            waiter("a"),
            [on_progress: &send(test, {n, &1.current})] ++ context.i
          )
      end

      assert_receive {:held, handler}, 2_000
      send(handler, :go)

      assert_receive {5, 2}, 2_000
      for n <- 1..4, do: refute_received({^n, 2})
    end

    test "a waiter that withdrew is told nothing more", context do
      test = self()
      held(context, "repo/a:1", [Model.downloading("l1", 1, 3)], [Model.downloading("l1", 2, 3)])

      :ok =
        Pulls.request(
          "repo/a:1",
          waiter("a"),
          [on_progress: &send(test, {:gone, &1.current})] ++ context.i
        )

      :ok =
        Pulls.request(
          "repo/a:1",
          waiter("b"),
          [on_progress: &send(test, {:stays, &1.current})] ++ context.i
        )

      assert_receive {:held, handler}, 2_000
      :ok = Pulls.cancel("repo/a:1", waiter("a"), context.i)
      send(handler, :go)

      # Each tick's functions run in the order of one list, in one process.
      assert_receive {:stays, 2}, 2_000
      refute_received {:gone, 2}
    end

    # A pull with waiters "a" and "b" whose first summary is on its way:
    # the task holds both functions, is inside "a"'s, and has yet to call
    # "b"'s. Returns the task, to be sent `:go`, and the engine's handler,
    # which then sends two more lines.
    defp summary_in_flight(context, b_function) do
      test = self()
      lines = for n <- 2..3, do: Model.downloading("l1", n, 3)
      held(context, "repo/a:1", [Model.downloading("l1", 1, 3)], lines)

      a_function = fn progress ->
        send(test, {:a, progress.current, self()})
        if progress.current == 1, do: receive(do: (:go -> :ok))
      end

      # Both join while the pull waits for the lane, so both are waiting
      # when its first line is read.
      stalled(context, "repo/other:1", "z")
      :ok = Pulls.request("repo/a:1", waiter("a"), [on_progress: a_function] ++ context.i)
      :ok = Pulls.request("repo/a:1", waiter("b"), [on_progress: b_function] ++ context.i)
      :ok = Pulls.cancel("repo/other:1", waiter("z"), context.i)

      assert_receive {:a, 1, task}, 2_000
      assert_receive {:held, handler}, 2_000
      {task, handler}
    end

    test "a function withdrawn while a summary is on its way gets that one, and none after",
         context do
      test = self()
      {task, handler} = summary_in_flight(context, &send(test, {:b, &1.current}))

      :ok = Pulls.cancel("repo/a:1", waiter("b"), context.i)
      refute_received {:b, 1}
      send(task, :go)
      assert_receive {:b, 1}, 2_000

      send(handler, :go)
      # The third summary's call comes after every call for the second.
      assert_receive {:a, 3, _task}, 2_000
      refute_received {:b, 2}
      refute_received {:b, 3}
    end

    test "a function replaced while a summary is on its way gets that one, and its successor the rest",
         context do
      test = self()
      {task, handler} = summary_in_flight(context, &send(test, {:old, &1.current}))

      :ok =
        Pulls.request(
          "repo/a:1",
          waiter("b"),
          [on_progress: &send(test, {:new, &1.current})] ++ context.i
        )

      send(task, :go)
      assert_receive {:old, 1}, 2_000

      send(handler, :go)
      assert_receive {:a, 3, _task}, 2_000
      assert_received {:new, 2}
      refute_received {:new, 1}
      refute_received {:old, 2}
      refute_received {:old, 3}
    end

    test "a progress function that raises costs the pull nothing", context do
      log =
        capture_log(fn ->
          :ok =
            Pulls.request(
              "repo/a:1",
              waiter("a"),
              [on_progress: fn _progress -> raise "not the pull's problem" end] ++ context.i
            )

          assert_woken("a")
        end)

      assert Pulls.state("repo/a:1", context.i) == :idle
      assert Container.image_present?("repo/a:1", context.engine_opts) == {:ok, true}
      assert log =~ "a progress function failed"
    end

    test "progress from anyone but the pull's own task changes nothing", context do
      task = stalled(context, "repo/a:1", "a")
      before = Pulls.state("repo/a:1", context.i)

      worker = Process.whereis(Pulls.name(context.instance))
      assert GenServer.call(worker, {:progress, "repo/a:1", %{status: "forged"}}) == []

      assert Pulls.state("repo/a:1", context.i) == before
      assert Pulls.info(context.i)["repo/a:1"].task == task
    end
  end

  describe "the worker" do
    test "state/2 answers while the worker cannot", context do
      stalled(context, "repo/a:1", "a")
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
      task = stalled(context, "repo/a:1", "a")
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

    test "when the lanes die, its pulls end and it starts over with them", context do
      task = stalled(context, "repo/a:1", "a")
      monitor = Process.monitor(task)
      worker = Process.whereis(Pulls.name(context.instance))
      supervisor = Process.whereis(Module.concat(context.instance, Supervisor))

      TestInstance.kill_observed(Process.whereis(Lanes.name(context.instance)), supervisor)

      assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 2_000
      assert Process.whereis(Pulls.name(context.instance)) != worker
      assert Pulls.state("repo/a:1", context.i) == :idle
    end

    test "child_specs/1 is the worker, then the supervisor of its tasks", context do
      assert [
               {Pulls, [instance: instance]},
               %{id: tasks, start: {Task.Supervisor, :start_link, [[name: tasks]]}}
             ] =
               Pulls.child_specs(instance: context.instance)

      assert instance == context.instance
      assert tasks == Pulls.tasks(context.instance)
    end
  end
end
