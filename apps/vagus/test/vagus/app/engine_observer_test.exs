defmodule Vagus.App.EngineObserverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.App.Backend
  alias Vagus.App.EngineObserver
  alias Vagus.Resource.TestInstance
  alias Vagus.Runtime.{Docker, Events}
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  defmodule Listing do
    @moduledoc "The container backend's listing, telling the test of each call."
    def list(opts) do
      send(opts[:test], :listed)
      Backend.Container.list(opts)
    end
  end

  defmodule Broken do
    @moduledoc "A listing that raises or exits instead of answering."
    def list(opts) do
      send(opts[:test], :listed)
      if opts[:how] == :exit, do: exit(:gone), else: raise("no listing today")
    end
  end

  defmodule NoEvents do
    @moduledoc "An events worker that is never there."
    def subscribe(test) do
      send(test, {:subscribe_tried, System.monotonic_time(:millisecond)})
      exit({:noproc, {GenServer, :call, [:nobody, :subscribe]}})
    end
  end

  @controller __MODULE__.App
  @moduletag :capture_log

  setup do
    engine = FakeEngine.start_model()
    on_exit(fn -> FakeEngine.stop(engine) end)
    %{engine: engine, instance: TestInstance.name()}
  end

  # An observer that hears of the engine only what the test sends it.
  defp observer(context, opts \\ []) do
    test = self()

    defaults = [
      instance: context.instance,
      controller: @controller,
      enqueue: fn controller, app, i -> send(test, {:woken, controller, app, i}) end,
      events: nil,
      backend: Listing,
      backend_opts: [test: test, engine: [socket: context.engine.socket]],
      interval: :infinity
    ]

    {id, opts} = Keyword.pop(opts, :id, EngineObserver)
    opts = Keyword.merge(defaults, opts)

    opts =
      if id == EngineObserver, do: opts, else: Keyword.put(opts, :instance, TestInstance.name())

    pid = start_supervised!({EngineObserver, opts}, id: id)
    sync(pid)
    pid
  end

  # The real events worker on the model's stream, established before this
  # returns: the test subscribes too, and is told when it is.
  defp events(context) do
    name = Module.concat(context.instance, Events)

    pid =
      start_supervised!(
        {Events, name: name, socket: context.engine.socket, backoff: {5, 40}},
        restart: :permanent
      )

    :ok = Events.subscribe(name)
    assert_receive {:docker_events, :gap}, 2_000
    {name, pid}
  end

  # A message is handled, and what it asked for done in the drain it queued
  # behind whatever else was waiting, by the time the second answer comes.
  defp sync(pid) do
    :sys.get_state(pid)
    :sys.get_state(pid)
    :ok
  end

  defp gap(pid) do
    send(pid, {:docker_events, :gap})
    sync(pid)
  end

  defp woken(seen \\ []) do
    receive do
      {:woken, @controller, app, _i} -> woken([app | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end

  defp drains(pid, count \\ 0) do
    receive do
      {:trace, ^pid, :receive, :drain} -> drains(pid, count + 1)
      {:trace, ^pid, :receive, _other} -> drains(pid, count)
    after
      0 -> count
    end
  end

  defp listed(count \\ 0) do
    receive do
      :listed -> listed(count + 1)
    after
      0 -> count
    end
  end

  # Wakes arrive in the order the observer sent them, and it sends a drain's
  # in order of name: once this one is here, every wake caused before it is.
  defp barrier(engine) do
    Model.emit(engine, "barrier", "app_zzzz")
    assert_receive {:woken, @controller, "zzzz", _i}, 2_000
    :ok
  end

  describe "the first listing after its start" do
    test "wakes every app that has a container, once, and nothing that is no app", context do
      Model.put_container(context.engine, "app_a")
      Model.put_container(context.engine, "addon_b", state: "exited", exit_code: 3)
      Model.put_container(context.engine, "homeassistant")
      Model.put_container(context.engine, "hassio_dns", labels: %{"supervisor_managed" => ""})
      Model.put_container(context.engine, "unrelated")

      observer(context)

      assert woken() == ["a", "b", "homeassistant"]
      assert listed() == 1
    end

    test "passes the instance it runs in to whoever it wakes", context do
      Model.put_container(context.engine, "app_a")
      observer(context)

      instance = context.instance
      assert_received {:woken, @controller, "a", [instance: ^instance]}
    end

    test "an app with a container under the old name and the new is woken once", context do
      Model.put_container(context.engine, "app_a")
      Model.put_container(context.engine, "addon_a", state: "exited")

      observer(context)
      assert woken() == ["a"]
    end

    test "with no engine wakes nobody, and the first that succeeds wakes everything", context do
      path = context.engine.socket
      FakeEngine.stop(context.engine)

      pid = observer(context)
      assert woken() == []
      assert listed() == 1

      engine = FakeEngine.start_model(socket: path)
      on_exit(fn -> FakeEngine.stop(engine) end)
      Model.put_container(engine, "app_a")
      Model.put_container(engine, "app_b")

      gap(pid)
      assert woken() == ["a", "b"]
    end
  end

  describe "a notice that events were missed" do
    setup context do
      Model.put_container(context.engine, "app_keep")
      Model.put_container(context.engine, "app_crash")
      Model.put_container(context.engine, "app_gone")
      Model.put_container(context.engine, "app_sick", health: {"healthy", 0})
      Model.put_container(context.engine, "app_anew", image: "repo/a:1")
      Model.put_container(context.engine, "homeassistant", restart_policy: "unless-stopped")

      pid = observer(context)
      assert length(woken()) == 6
      assert listed() == 1
      %{pid: pid, engine_opts: [socket: context.engine.socket]}
    end

    test "is one listing, which wakes nobody when nothing changed", %{pid: pid} do
      gap(pid)
      assert listed() == 1
      assert woken() == []
    end

    test "wakes nobody for a status text that only aged", %{pid: pid, engine_opts: engine} do
      {:ok, [first | _]} = Docker.list_containers([all: true] ++ engine)
      {:ok, [second | _]} = Docker.list_containers([all: true] ++ engine)
      # What the model does, as the engine does: the sentence differs each time.
      assert first["Status"] =~ ~r/^Up \d+ seconds/
      assert first["Status"] != second["Status"]

      for _ <- 1..3, do: gap(pid)
      assert listed() == 3
      assert woken() == []
    end

    test "wakes exactly the apps whose container appeared, went or changed", context do
      %{pid: pid, engine: engine, engine_opts: opts} = context

      Model.put_container(engine, "app_new")
      Model.crash(engine, "app_crash", 137)
      :ok = Backend.Container.remove("app_gone", engine: opts)
      Model.set_health(engine, "app_sick", "unhealthy", 3)
      :ok = Backend.Container.remove("app_anew", engine: opts)
      Model.put_container(engine, "app_anew", image: "repo/a:2")

      gap(pid)
      assert listed() == 1
      assert woken() == ["anew", "crash", "gone", "new", "sick"]

      gap(pid)
      assert woken() == []
    end

    test "tells a container made again from one that only looks the same", context do
      %{pid: pid, engine: engine, engine_opts: opts} = context

      :ok = Backend.Container.remove("app_anew", engine: opts)
      Model.put_container(engine, "app_anew", image: "repo/a:1")

      gap(pid)
      assert woken() == ["anew"]
    end

    test "tells a restart by the engine only by what a listing shows of it", context do
      %{pid: pid, engine: engine} = context

      # Running before and after, under the same id: nothing to compare.
      # The `die` and `start` events are what wake the app for this.
      Model.crash(engine, "homeassistant")
      gap(pid)
      assert woken() == []
    end

    test "arriving in a burst, with events, is one listing and one wake an app", context do
      %{pid: pid, engine: engine} = context
      Model.put_container(engine, "app_new")

      :sys.suspend(pid)

      for n <- 1..2_000 do
        send(pid, {:docker_event, %{name: "app_keep", action: "exec_start: #{n}"}})
        if rem(n, 100) == 0, do: send(pid, {:docker_events, :gap})
      end

      send(pid, {:docker_event, %{name: "addon_keep", action: "die"}})
      send(pid, {:docker_event, %{name: "app_other", action: "die"}})
      assert {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
      assert queued >= 2_000

      :erlang.trace(pid, true, [:receive])
      :sys.resume(pid)
      sync(pid)
      :erlang.trace(pid, false, [:receive])

      assert listed() == 1
      assert woken() == ["keep", "new", "other"]
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)

      # The burst cost the mailbox one message more, not one each.
      delivered = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^delivered}
      assert drains(pid) == 1
    end
  end

  describe "an engine that cannot be listed" do
    setup context do
      Model.put_container(context.engine, "app_keep")
      Model.put_container(context.engine, "app_gone")
      pid = observer(context)
      assert woken() == ["gone", "keep"]
      assert listed() == 1
      %{pid: pid}
    end

    test "is asked once a notice, never by itself, and what was last listed is kept", context do
      %{pid: pid, engine: engine} = context
      path = engine.socket
      FakeEngine.stop(engine)

      gap(pid)
      assert listed() == 1
      assert woken() == []

      # Nothing is armed to try again: it waits for the next notice.
      sync(pid)
      assert listed() == 0
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
      assert %{list?: false, drain?: false} = :sys.get_state(pid)

      gap(pid)
      assert listed() == 1
      assert woken() == []

      # Back, as an engine restart leaves it: one container as it was, one
      # gone, one new. The first is put first, so that its id is the same.
      engine = FakeEngine.start_model(socket: path)
      on_exit(fn -> FakeEngine.stop(engine) end)
      Model.put_container(engine, "app_keep")
      Model.put_container(engine, "app_new")

      gap(pid)
      assert listed() == 1
      # Compared with the listing from before the outage: had that been
      # dropped, "keep" would be woken as well.
      assert woken() == ["gone", "new"]
    end

    test "that answers with an error keeps the listing too", context do
      %{pid: pid, engine: engine} = context
      path = engine.socket
      FakeEngine.stop(engine)
      scripted = FakeEngine.start([{500, %{"message" => "boom"}}])
      File.rename!(scripted.socket, path)
      on_exit(fn -> FakeEngine.stop(%{scripted | socket: path}) end)

      log = capture_log(fn -> gap(pid) end)

      assert log =~ "could not be listed"
      assert woken() == []
      assert %{rows: %{"app_keep" => _, "app_gone" => _}} = :sys.get_state(pid)
    end

    test "by a backend that raises or exits survives it, and says so", context do
      for how <- [:raise, :exit] do
        pid =
          start_supervised!(
            {EngineObserver,
             instance: TestInstance.name(),
             controller: @controller,
             enqueue: fn _, _, _ -> :ok end,
             events: nil,
             backend: Broken,
             backend_opts: [test: self(), how: how],
             interval: :infinity},
            id: how
          )

        log = capture_log(fn -> gap(pid) end)

        assert log =~ "could not be listed"
        assert listed() == 2
        assert Process.alive?(pid)
        assert %{rows: nil} = :sys.get_state(pid)
      end

      _ = context
    end
  end

  describe "the interval" do
    test "lists again each time it passes, and wakes what changed since", context do
      Model.put_container(context.engine, "app_a")
      pid = observer(context, interval: 20)
      assert woken() == ["a"]

      for _ <- 1..3, do: assert_receive(:listed, 2_000)
      assert woken() == []

      Model.put_container(context.engine, "app_b")
      assert_receive {:woken, @controller, "b", _i}, 2_000
      assert Process.alive?(pid)
    end

    test "of :infinity arms nothing", context do
      pid = observer(context, interval: :infinity)
      assert listed() == 1
      assert %{ticker: nil} = :sys.get_state(pid)

      assert is_reference(
               :sys.get_state(observer(context, id: :ticking, interval: 60_000)).ticker
             )
    end

    test "bounds the listing by a receive timeout of its own, unless given one", context do
      pid = observer(context, list_timeout: 1_234)
      assert :sys.get_state(pid).backend_opts[:engine][:recv_timeout] == 1_234

      other =
        start_supervised!(
          {EngineObserver,
           instance: TestInstance.name(),
           controller: @controller,
           events: nil,
           interval: :infinity,
           backend_opts: [engine: [socket: context.engine.socket, recv_timeout: 7]]},
          id: :other
        )

      assert :sys.get_state(other).backend_opts[:engine] ==
               [socket: context.engine.socket, recv_timeout: 7]

      bare =
        observer(context,
          id: :bare,
          backend: Broken,
          backend_opts: [test: self()],
          list_timeout: 99
        )

      assert :sys.get_state(bare).backend_opts[:engine] == [recv_timeout: 99]
    end
  end

  describe "an event about a container" do
    setup context do
      {name, events} = events(context)
      pid = observer(context, events: {Events, name})
      # Its own start, and the notice a subscriber to a running stream gets.
      assert listed() == 2
      %{pid: pid, events: events, events_name: name}
    end

    test "wakes the app it is named for, and no other", %{engine: engine} do
      Model.put_container(engine, "app_a")
      Model.put_container(engine, "app_b")
      barrier(engine)
      woken()

      Model.crash(engine, "app_a")
      barrier(engine)
      assert woken() == ["a"]
    end

    test "under the old container name wakes the same app, and Core's wakes Core", %{
      engine: engine
    } do
      Model.emit(engine, "die", "addon_legacy")
      Model.emit(engine, "health_status: unhealthy", "homeassistant")
      barrier(engine)
      # Two events, each possibly a drain of its own.
      assert Enum.sort(woken()) == ["homeassistant", "legacy"]
    end

    test "that is ours and no app's wakes nobody", %{engine: engine} do
      Model.emit(engine, "die", "hassio_dns", %{"supervisor_managed" => ""})
      Model.emit(engine, "die", "unrelated")
      barrier(engine)
      assert woken() == []
    end

    test "is no listing", %{engine: engine} do
      Model.emit(engine, "die", "app_a")
      barrier(engine)
      assert listed() == 0
    end
  end

  describe "the events worker" do
    test "replaced is subscribed to again, and a later event still wakes", context do
      {name, events} = events(context)
      pid = observer(context, events: {Events, name}, resubscribe: {5, 40})
      assert %{subscription: {:subscribed, _monitor}} = :sys.get_state(pid)
      listed()

      # The test's own subscription died with the worker; the observer's is
      # the only one the new worker gets.
      :erlang.trace(pid, true, [:receive])
      Process.exit(events, :kill)
      assert_receive {:trace, ^pid, :receive, {:DOWN, _ref, :process, _worker, :killed}}, 2_000

      # Sent only by a worker whose stream is up, to a subscriber, and after
      # the old worker's end only by the new one.
      assert_receive {:trace, ^pid, :receive, {:docker_events, :gap}}, 5_000
      :erlang.trace(pid, false, [:receive])

      assert Process.whereis(name) != events
      sync(pid)
      assert listed() >= 1

      Model.emit(context.engine, "die", "app_after")
      assert_receive {:woken, @controller, "after", _i}, 2_000
    end

    test "that is not there yet is subscribed to when it is", context do
      name = Module.concat(context.instance, Events)
      pid = observer(context, events: {Events, name}, resubscribe: {5, 40})
      assert %{subscription: {:retrying, _delay}} = :sys.get_state(pid)

      :erlang.trace(pid, true, [:receive])
      start_supervised!({Events, name: name, socket: context.engine.socket, backoff: {5, 40}})
      assert_receive {:trace, ^pid, :receive, {:docker_events, :gap}}, 5_000
      :erlang.trace(pid, false, [:receive])

      Model.emit(context.engine, "die", "app_late")
      assert_receive {:woken, @controller, "late", _i}, 2_000
      assert %{subscription: {:subscribed, _monitor}} = :sys.get_state(pid)
    end

    test "that never comes is tried at a pace that slows to its bound", context do
      pid = observer(context, events: {NoEvents, self()}, resubscribe: {10, 40})

      times =
        for _ <- 1..7 do
          assert_receive {:subscribe_tried, at}, 2_000
          at
        end

      gaps = times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

      # 10, 20, 40, 40, ...: a timer is never early.
      assert Enum.at(gaps, 0) >= 10
      assert Enum.at(gaps, 1) >= 20
      assert Enum.all?(Enum.drop(gaps, 2), &(&1 >= 40))
      assert %{subscription: {:retrying, 40}} = :sys.get_state(pid)
    end
  end

  describe "a native instance" do
    setup context do
      %{pid: observer(context), i: [instance: context.instance]}
    end

    defp instance_process do
      pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    test "that ends wakes its app, however it ended", %{pid: pid, i: i} do
      for {app, reason} <- [{"killed", :kill}, {"crashed", :boom}] do
        native = instance_process()
        :ok = EngineObserver.watch(app, native, i)
        sync(pid)
        assert woken() == []

        Process.exit(native, reason)
        assert_receive {:woken, @controller, ^app, _i}, 2_000
      end

      native = instance_process()
      :ok = EngineObserver.watch("stopped", native, i)
      send(native, :stop)
      assert_receive {:woken, @controller, "stopped", _i}, 2_000

      sync(pid)
      assert %{natives: natives, monitors: monitors} = :sys.get_state(pid)
      assert natives == %{} and monitors == %{}
    end

    test "that had already ended wakes its app at once", %{pid: pid, i: i} do
      native = instance_process()
      ref = Process.monitor(native)
      Process.exit(native, :kill)
      assert_receive {:DOWN, ^ref, :process, ^native, :killed}

      :ok = EngineObserver.watch("late", native, i)
      assert_receive {:woken, @controller, "late", _i}, 2_000
      sync(pid)
      assert woken() == []
    end

    test "watched again is watched once, and a new one replaces the old", %{pid: pid, i: i} do
      first = instance_process()
      for _ <- 1..5, do: :ok = EngineObserver.watch("mqtt", first, i)
      sync(pid)
      assert %{monitors: monitors} = :sys.get_state(pid)
      assert map_size(monitors) == 1

      second = instance_process()
      :ok = EngineObserver.watch("mqtt", second, i)
      sync(pid)

      assert %{natives: %{"mqtt" => {^second, _monitor}}, monitors: monitors} =
               :sys.get_state(pid)

      assert map_size(monitors) == 1

      # The first is no longer its instance: its end is nobody's news.
      Process.exit(first, :kill)
      sync(pid)
      assert woken() == []

      Process.exit(second, :kill)
      assert_receive {:woken, @controller, "mqtt", _i}, 2_000
    end

    test "is not watched by an observer that is not there, and nothing fails" do
      assert EngineObserver.watch("mqtt", self(), instance: TestInstance.name()) == :ok
    end
  end

  describe "row/1" do
    defp row(status, fields \\ %{}) do
      EngineObserver.row(
        Map.merge(
          %{
            id: "i",
            names: ["app_a"],
            image: "r:1",
            state: "running",
            status: status,
            labels: %{}
          },
          fields
        )
      )
    end

    test "is the same for a status that differs only in how long ago" do
      assert row("Up 3 seconds") == row("Up 4 seconds")
      assert row("Up 3 seconds") == row("Up 2 weeks")
      assert row("Up About a minute (healthy)") == row("Up 3 hours (healthy)")
      assert row("Exited (137) 3 seconds ago") == row("Exited (137) 4 hours ago")
      assert row("Restarting (1) 2 seconds ago") == row("Restarting (1) 9 seconds ago")
    end

    test "differs by exit code, health, pause, state, image and id" do
      rows = [
        row("Up 3 seconds"),
        row("Up 3 seconds (healthy)"),
        row("Up 3 seconds (unhealthy)"),
        row("Up 3 seconds (health: starting)"),
        row("Up 3 seconds (Paused)"),
        row("Exited (0) 3 seconds ago", %{state: "exited"}),
        row("Exited (137) 3 seconds ago", %{state: "exited"}),
        row("Exited (-1) 3 seconds ago", %{state: "exited"}),
        row("Created", %{state: "created"}),
        row("Up 3 seconds", %{image: "r:2"}),
        row("Up 3 seconds", %{id: "j"}),
        row(nil, %{state: nil})
      ]

      assert length(Enum.uniq(rows)) == length(rows)
    end
  end

  describe "under the resource supervisor, waking a real runtime" do
    import Vagus.Resource.Harness

    alias Vagus.Resource.{Runtime, Store}
    alias Vagus.Resource.Toys.{Follower, Probe}

    # Two followers, each of which leaves a note per pass and writes nothing.
    setup context do
      socket = context.engine.socket

      sys =
        start_system(
          controllers: [Probe, Follower],
          services:
            &[
              {EngineObserver,
               instance: &1,
               controller: Follower,
               events: nil,
               interval: :infinity,
               backend_opts: [engine: [socket: socket]]}
            ]
        )

      given_ready(sys, {:probe, "p", %{}})

      for name <- ["a", "b"],
          do: {:ok, _} = Store.create(:follower, name, %{"target" => "p"}, sys.i)

      settle(sys)
      notes(sys)
      %{sys: sys, pid: Process.whereis(EngineObserver.name(sys.instance))}
    end

    test "stands after the lanes and before the controllers", %{sys: sys} do
      children =
        for {id, _pid, _type, _modules} <-
              Supervisor.which_children(Module.concat(sys.instance, Supervisor)),
            do: id

      # Listed last started first.
      assert [Vagus.Resource.Controllers.Supervisor, EngineObserver, Vagus.Resource.Lanes | _] =
               children
    end

    test "an event is a pass for that app's resource and for no other", %{sys: sys, pid: pid} do
      send(pid, {:docker_event, %{name: "app_b", action: "die"}})
      send(pid, {:docker_event, %{name: "app_nobody", action: "die"}})
      sync(pid)
      settle(sys)

      assert notes(sys) == [{:followed, "b", 1}]
    end

    test "a container that appeared is a pass for its app", %{sys: sys, pid: pid, engine: engine} do
      Model.put_container(engine, "app_a")
      gap(pid)
      settle(sys)

      assert notes(sys) == [{:followed, "a", 1}]
    end

    test "when it dies the runtimes are replaced and look at everything", %{sys: sys, pid: pid} do
      runtime = Process.whereis(Runtime.name(sys.instance, Follower))
      supervisor = Process.whereis(Module.concat(sys.instance, Supervisor))

      TestInstance.kill_observed(pid, supervisor)
      settle(sys)

      assert Process.whereis(EngineObserver.name(sys.instance)) != pid
      assert Process.whereis(Runtime.name(sys.instance, Follower)) != runtime

      assert notes(sys) |> Enum.uniq() |> Enum.sort() == [
               {:followed, "a", 1},
               {:followed, "b", 1}
             ]
    end
  end
end

defmodule Vagus.App.EngineObserverNativeTest do
  # Not async: it runs a real broker, which registers names and binds a port.
  use ExUnit.Case, async: false

  alias Vagus.App.Backend.Native
  alias Vagus.App.EngineObserver
  alias Vagus.Resource.TestInstance

  @moduletag :capture_log

  test "the broker's subtree killed wakes its app, and nothing starts it again" do
    supervisor =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_restarts: 5, max_seconds: 30}
      )

    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    slug = "native_#{System.unique_integer([:positive])}"
    opts = [supervisor: supervisor, port: port, provider: nil]
    instance = TestInstance.name()
    test = self()

    observer =
      start_supervised!(
        {EngineObserver,
         instance: instance,
         controller: __MODULE__,
         enqueue: fn controller, app, _i -> send(test, {:woken, controller, app}) end,
         events: nil,
         backend_opts: [engine: [socket: Vagus.Test.FakeEngine.socket_path()]],
         interval: :infinity}
      )

    :ok = Native.start(slug, opts)
    broker = Native.pid(slug, opts)
    assert is_pid(broker)

    :ok = EngineObserver.watch(slug, broker, instance: instance)
    :sys.get_state(observer)
    refute_received {:woken, _controller, _app}

    Process.exit(broker, :kill)

    assert_receive {:woken, __MODULE__, ^slug}, 2_000
    assert Native.observe(slug, opts) == {:ok, :absent}
    assert Native.pid(slug, opts) == nil
  end
end
