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
    @moduledoc """
    A listing that does not answer: as many times as the counter in
    `opts[:fuse]` says it raises, or exits with `how: :exit`, and after
    that it is `Listing`.
    """
    def list(opts) do
      if :atomics.sub_get(opts[:fuse], 1, 1) >= 0 do
        send(opts[:test], :listed)
        if opts[:how] == :exit, do: exit(:gone), else: raise("no listing today")
      else
        Listing.list(opts)
      end
    end
  end

  defmodule TwoNames do
    @moduledoc "A listing of one container that has two names."
    def list(_opts) do
      {:ok,
       [
         %{
           id: "i1",
           names: ["app_one", "addon_other"],
           image: "r:1",
           state: "running",
           status: "Up 1 second",
           labels: %{}
         }
       ]}
    end
  end

  defmodule NoEvents do
    @moduledoc "An events worker that is never there."
    def subscribe(test) do
      send(test, :subscribe_tried)
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

  # An observer that hears of the engine only what the test sends it, and
  # whose timers are the test's to fire: each is reported as `{:timer,
  # message, ms}` and nothing comes of it until `fire/2`. `timer: :real`
  # leaves it its own.
  defp observer(context, opts \\ []) do
    test = self()

    defaults = [
      instance: context.instance,
      controller: @controller,
      enqueue: fn controller, app, i -> send(test, {:woken, controller, app, i}) end,
      resync: fn controller, i -> send(test, {:resynced, controller, i}) end,
      events: nil,
      backend: Listing,
      backend_opts: [test: test, engine: [socket: context.engine.socket]],
      interval: :infinity,
      timer: fn message, ms ->
        send(test, {:timer, message, ms})
        make_ref()
      end
    ]

    {id, opts} = Keyword.pop(opts, :id, EngineObserver)
    opts = Keyword.merge(defaults, opts)
    opts = if opts[:timer] == :real, do: Keyword.delete(opts, :timer), else: opts

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

  defp gap(pid), do: fire(pid, {:docker_events, :gap})

  defp fire(pid, message) do
    send(pid, message)
    sync(pid)
  end

  defp event(pid, name, action),
    do: fire(pid, {:docker_event, %{name: name, action: action}})

  defp woken(seen \\ []) do
    receive do
      {:woken, @controller, app, _i} -> woken([app | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end

  defp count(message, n \\ 0) do
    receive do
      ^message -> count(message, n + 1)
    after
      0 -> n
    end
  end

  defp listed, do: count(:listed)

  # The timers asked for since this was last called, oldest first.
  defp timers(seen \\ []) do
    receive do
      {:timer, message, ms} -> timers([{message, ms} | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end

  defp traced(pid, message, n \\ 0) do
    receive do
      {:trace, ^pid, :receive, ^message} -> traced(pid, message, n + 1)
      {:trace, ^pid, :receive, _other} -> traced(pid, message, n)
    after
      0 -> n
    end
  end

  # Wakes arrive in the order the observer sent them, and it sends a drain's
  # in order of name: once this one is here, every wake caused before it is.
  defp barrier(engine) do
    Model.emit(engine, "die", "app_zzzz")
    assert_receive {:woken, @controller, "zzzz", _i}, 2_000
    :ok
  end

  # An engine at the socket of one that was stopped, with nothing in it.
  defp engine_back(%{socket: path}) do
    engine = FakeEngine.start_model(socket: path)
    on_exit(fn -> FakeEngine.stop(engine) end)
    engine
  end

  describe "at its start" do
    test "has its controller's runtime look at everything, in its instance", context do
      observer(context)

      instance = context.instance
      assert_received {:resynced, @controller, [instance: ^instance]}
      refute_received {:resynced, _controller, _i}
    end

    test "wakes every app that has a container, once, and nothing that is no app", context do
      Model.put_container(context.engine, "app_a")
      Model.put_container(context.engine, "addon_b", state: "exited", exit_code: 3)
      Model.put_container(context.engine, "homeassistant")
      Model.put_container(context.engine, "hassio_dns", labels: %{"supervisor_managed" => ""})
      Model.put_container(context.engine, "unrelated")

      observer(context)

      assert woken() == ["a", "b", "homeassistant"]
      assert listed() == 1
      assert timers() == []
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

    test "a container with two names is each name's app", context do
      observer(context, backend: TwoNames)
      assert woken() == ["one", "other"]
    end
  end

  describe "a notice that events were missed" do
    setup context do
      Model.put_container(context.engine, "app_keep")
      Model.put_container(context.engine, "app_crash")
      Model.put_container(context.engine, "app_gone")
      Model.put_container(context.engine, "homeassistant", restart_policy: "unless-stopped")

      pid = observer(context)
      assert woken() == ["crash", "gone", "homeassistant", "keep"]
      assert listed() == 1
      %{pid: pid, engine_opts: [socket: context.engine.socket]}
    end

    test "is one listing, and wakes every app with a container, changed or not", %{pid: pid} do
      gap(pid)
      assert listed() == 1
      assert woken() == ["crash", "gone", "homeassistant", "keep"]
    end

    test "wakes Core for a restart by the engine that no listing shows", context do
      %{pid: pid, engine: engine, engine_opts: opts} = context

      core = fn ->
        {:ok, list} = Backend.Container.list(engine: opts)
        list |> Enum.find(&(&1.names == ["homeassistant"])) |> EngineObserver.row()
      end

      before = core.()
      # Its events are the ones that were lost.
      Model.crash(engine, "homeassistant")
      assert core.() == before

      gap(pid)
      assert "homeassistant" in woken()
    end

    test "wakes the apps whose container went meanwhile, and those that came", context do
      %{pid: pid, engine: engine, engine_opts: opts} = context

      :ok = Backend.Container.remove("app_gone", engine: opts)
      Model.put_container(engine, "app_new")

      gap(pid)
      assert woken() == ["crash", "gone", "homeassistant", "keep", "new"]

      # What went is not in the listing kept, and is not woken again.
      gap(pid)
      assert woken() == ["crash", "homeassistant", "keep", "new"]
    end

    test "arriving in a burst, with events, is one listing and one wake an app", context do
      %{pid: pid, engine: engine} = context
      Model.put_container(engine, "app_new")

      :sys.suspend(pid)

      for n <- 1..2_000 do
        send(pid, {:docker_event, %{name: "app_keep", action: "die", n: n}})
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
      assert woken() == ["crash", "gone", "homeassistant", "keep", "new", "other"]
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)

      # The burst cost the mailbox one message more, not one each.
      delivered = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^delivered}, 2_000
      assert traced(pid, :drain) == 1
    end
  end

  describe "the interval" do
    setup context do
      Model.put_container(context.engine, "app_keep")
      Model.put_container(context.engine, "app_crash")
      Model.put_container(context.engine, "app_gone")
      Model.put_container(context.engine, "app_sick", health: {"healthy", 0})
      Model.put_container(context.engine, "app_anew", image: "repo/a:1")
      Model.put_container(context.engine, "homeassistant", restart_policy: "unless-stopped")

      pid = observer(context, interval: 300_000)
      assert length(woken()) == 6
      assert listed() == 1
      assert timers() == [{:tick, 300_000}]
      %{pid: pid, engine_opts: [socket: context.engine.socket]}
    end

    test "is one listing each time it passes, armed again each time", %{pid: pid} do
      for _ <- 1..3 do
        fire(pid, :tick)
        assert listed() == 1
        assert timers() == [{:tick, 300_000}]
      end

      assert woken() == []
    end

    test "wakes nobody for a status text that only aged", %{pid: pid, engine_opts: engine} do
      {:ok, [first | _]} = Docker.list_containers([all: true] ++ engine)
      {:ok, [second | _]} = Docker.list_containers([all: true] ++ engine)
      # What the model does, as the engine does: the sentence differs each time.
      assert first["Status"] =~ ~r/^Up \d+ seconds/
      assert first["Status"] != second["Status"]

      for _ <- 1..3, do: fire(pid, :tick)
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

      fire(pid, :tick)
      assert listed() == 1
      assert woken() == ["anew", "crash", "gone", "new", "sick"]

      fire(pid, :tick)
      assert woken() == []
    end

    test "tells a container made again from one that only looks the same", context do
      %{pid: pid, engine: engine, engine_opts: opts} = context

      :ok = Backend.Container.remove("app_anew", engine: opts)
      Model.put_container(engine, "app_anew", image: "repo/a:1")

      fire(pid, :tick)
      assert woken() == ["anew"]
    end

    test "does not show a restart by the engine, which is what a notice is for", context do
      %{pid: pid, engine: engine} = context

      Model.crash(engine, "homeassistant")
      fire(pid, :tick)
      assert woken() == []

      gap(pid)
      assert "homeassistant" in woken()
    end

    test "that passes while a notice's listing is still owed wakes no fewer", context do
      %{pid: pid, engine: engine} = context
      FakeEngine.stop(engine)

      gap(pid)
      assert woken() == []

      Model.put_container(engine_back(engine), "app_keep")
      fire(pid, :tick)
      assert length(woken()) == 6
    end

    test "of :infinity arms nothing", context do
      pid = observer(context, id: :never, interval: :infinity)
      assert timers() == []
      assert %{ticker: nil} = :sys.get_state(pid)
    end

    test "is real time when no timer is given", context do
      observer(context, id: :real, timer: :real, interval: 15)
      for _ <- 1..4, do: assert_receive(:listed, 2_000)
    end
  end

  describe "a listing that fails" do
    setup context do
      Model.put_container(context.engine, "app_keep")
      Model.put_container(context.engine, "app_gone")
      pid = observer(context, relist: {100, 450})
      assert woken() == ["gone", "keep"]
      assert listed() == 1
      %{pid: pid}
    end

    test "is tried again by one timer, later each time up to a bound, and no more often",
         context do
      %{pid: pid, engine: engine} = context
      FakeEngine.stop(engine)

      log =
        capture_log(fn ->
          gap(pid)
          assert listed() == 1
          assert [{{:relist, first}, 100}] = timers()

          # Nothing else is armed, and nothing lists by itself.
          sync(pid)
          assert listed() == 0
          assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)

          # A notice is a try of its own, and arms no second timer.
          for _ <- 1..3, do: gap(pid)
          assert listed() == 3
          assert timers() == []

          # An event is not: the engine has just failed to answer.
          event(pid, "app_keep", "die")
          assert listed() == 0
          assert woken() == ["keep"]

          Enum.reduce([200, 400, 450, 450], first, fn expected, token ->
            fire(pid, {:relist, token})
            assert listed() == 1
            assert [{{:relist, next}, ^expected}] = timers()
            next
          end)

          # A timer's message that comes twice lists once.
          fire(pid, {:relist, first})
          assert listed() == 0
          assert timers() == []
        end)

      # An engine that is away is how every boot begins: not a warning.
      refute log =~ "could not be listed"
      assert woken() == []
    end

    test "keeps what was last listed and what was owed, and success ends the retrying",
         context do
      %{pid: pid, engine: engine} = context
      FakeEngine.stop(engine)

      fire(pid, :tick)
      assert listed() == 1
      assert [{{:relist, token}, 100}] = timers()
      assert woken() == []

      # Back, as an engine restart leaves it: one container as it was, one
      # gone, one new. The first is put first, so that its id is the same.
      engine = engine_back(engine)
      Model.put_container(engine, "app_keep")
      Model.put_container(engine, "app_new")

      fire(pid, {:relist, token})
      assert listed() == 1
      # Compared with the listing from before the outage: had that been
      # dropped, "keep" would be woken as well.
      assert woken() == ["gone", "new"]
      assert timers() == []
      assert %{retry: nil, owed: nil} = :sys.get_state(pid)

      # The next failure starts from the first delay again.
      FakeEngine.stop(engine)
      fire(pid, :tick)
      assert [{{:relist, _token}, 100}] = timers()
    end

    test "leaves its timer's message harmless once a notice's listing has succeeded", context do
      %{pid: pid, engine: engine} = context
      FakeEngine.stop(engine)
      gap(pid)
      assert listed() == 1
      assert [{{:relist, token}, 100}] = timers()

      Model.put_container(engine_back(engine), "app_keep")
      gap(pid)
      assert listed() == 1
      assert woken() == ["gone", "keep"]

      fire(pid, {:relist, token})
      assert listed() == 0
      assert timers() == []
    end

    test "with an error of the engine's is the same, and a warning", context do
      %{pid: pid, engine: engine} = context
      path = engine.socket
      FakeEngine.stop(engine)
      scripted = FakeEngine.start([{500, %{"message" => "boom"}}])
      File.rename!(scripted.socket, path)
      on_exit(fn -> FakeEngine.stop(%{scripted | socket: path}) end)

      log = capture_log(fn -> gap(pid) end)

      assert log =~ "[warning] Vagus.App.EngineObserver: the containers could not be listed"
      assert log =~ "boom"
      assert woken() == []
      assert [{{:relist, _token}, 100}] = timers()

      assert %{rows: %{"app_keep" => _, "app_gone" => _}, owed: :everything} =
               :sys.get_state(pid)
    end

    test "because the engine says nothing gives up after the silence allowed", context do
      path = context.engine.socket
      FakeEngine.stop(context.engine)
      silent = FakeEngine.start([{:stream, 200, [:stall]}])
      File.rename!(silent.socket, path)
      on_exit(fn -> FakeEngine.stop(%{silent | socket: path}) end)
      test = self()

      log =
        capture_log(fn ->
          pid =
            observer(context,
              id: :silent,
              list_timeout: 30,
              backend_opts: [test: test, engine: [socket: path]]
            )

          assert listed() == 1
          assert [{{:relist, _token}, 1_000}] = timers()
          assert woken() == []
          assert %{rows: nil} = :sys.get_state(pid)
        end)

      assert log =~ "could not be listed"
      assert log =~ "timeout"
    end

    test "by a backend whose call exits is the same, and is tried again", context do
      fuse = :atomics.new(1, [])
      :atomics.put(fuse, 1, 1)
      test = self()

      log =
        capture_log(fn ->
          pid =
            observer(context,
              id: :exits,
              backend: Broken,
              backend_opts: [
                test: test,
                fuse: fuse,
                how: :exit,
                engine: [socket: context.engine.socket]
              ]
            )

          assert listed() == 1
          assert [{{:relist, token}, 1_000}] = timers()
          assert woken() == []

          fire(pid, {:relist, token})
          assert woken() == ["gone", "keep"]
          assert timers() == []
        end)

      assert log =~ "could not be listed"
      assert log =~ ":gone"
    end

    test "by a backend that raises ends the observer: a defect is not a failure to retry",
         context do
      fuse = :atomics.new(1, [])

      pid =
        observer(context,
          id: :raises,
          backend: Broken,
          backend_opts: [test: self(), fuse: fuse, engine: [socket: context.engine.socket]]
        )

      ref = Process.monitor(pid)
      :atomics.put(fuse, 1, 1)
      send(pid, {:docker_events, :gap})

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {%RuntimeError{message: "no listing today"}, _stack}},
                     2_000
    end

    test "bounds the listing by a silence of its own, unless given one", context do
      pid = observer(context, id: :own, list_timeout: 1_234)
      assert :sys.get_state(pid).backend_opts[:engine][:recv_timeout] == 1_234

      other =
        observer(context,
          id: :given,
          backend_opts: [test: self(), engine: [socket: context.engine.socket, recv_timeout: 7]]
        )

      assert :sys.get_state(other).backend_opts[:engine] ==
               [socket: context.engine.socket, recv_timeout: 7]

      bare =
        observer(context,
          id: :bare,
          backend: TwoNames,
          backend_opts: [],
          list_timeout: 99
        )

      assert :sys.get_state(bare).backend_opts == [engine: [recv_timeout: 99]]
    end
  end

  describe "an event about a container" do
    # Several containers are there before it starts, so that a listing, or
    # a wake of everything, would show.
    setup context do
      for name <- ["app_a", "app_b", "app_c", "addon_legacy", "homeassistant"],
          do: Model.put_container(context.engine, name)

      {name, events} = events(context)
      pid = observer(context, events: {Events, name})
      # Its own start, and the notice a subscriber to a running stream gets.
      assert listed() == 2
      assert Enum.uniq(woken()) == ["a", "b", "c", "homeassistant", "legacy"]
      %{pid: pid, events: events, events_name: name}
    end

    test "wakes the app it is named for, and no other", %{engine: engine} do
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

    test "wakes for each action that can change what a pass decides", %{engine: engine} do
      actions =
        ~w(create start die stop kill oom destroy pause unpause restart rename) ++
          ["health_status: healthy", "health_status: unhealthy", "health_status: starting"]

      for action <- actions do
        Model.emit(engine, action, "app_b")
        assert_receive {:woken, @controller, "b", _i}, 2_000
      end

      barrier(engine)
      assert woken() == []
    end

    test "does not wake for what a healthcheck and an attach emit, or for no action", %{
      engine: engine,
      pid: pid
    } do
      for action <- [
            "exec_create: /bin/sh -c health",
            "exec_start: /bin/sh -c health",
            "exec_die",
            "attach",
            "top",
            "resize",
            "export",
            "commit",
            "update",
            "Die",
            ""
          ] do
        Model.emit(engine, action, "app_b")
      end

      barrier(engine)
      assert woken() == []

      for action <- [nil, :die, 7, %{}] do
        fire(pid, {:docker_event, %{name: "app_b", action: action}})
      end

      fire(pid, {:docker_event, %{name: "app_b"}})
      assert woken() == []
    end

    test "waking?/1 is those and nothing else" do
      assert Enum.filter(
               ~w(create start die stop kill oom destroy pause unpause restart rename exec_die
                  exec_start attach top copy update resize),
               &EngineObserver.waking?/1
             ) == ~w(create start die stop kill oom destroy pause unpause restart rename)

      assert EngineObserver.waking?("health_status: healthy")
      assert EngineObserver.waking?("health_status")
      refute EngineObserver.waking?("exec_create: health_status")
      refute EngineObserver.waking?(nil)
    end
  end

  describe "the events worker" do
    test "replaced is subscribed to again, and a later event still wakes", context do
      {name, events} = events(context)
      pid = observer(context, events: {Events, name}, resubscribe: {5, 40}, timer: :real)
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
      pid = observer(context, events: {Events, name}, resubscribe: {5, 40}, timer: :real)
      assert %{subscription: {:retrying, _delay}} = :sys.get_state(pid)

      :erlang.trace(pid, true, [:receive])
      start_supervised!({Events, name: name, socket: context.engine.socket, backoff: {5, 40}})
      assert_receive {:trace, ^pid, :receive, {:docker_events, :gap}}, 5_000
      :erlang.trace(pid, false, [:receive])

      Model.emit(context.engine, "die", "app_late")
      assert_receive {:woken, @controller, "late", _i}, 2_000
      assert %{subscription: {:subscribed, _monitor}} = :sys.get_state(pid)
    end

    test "that never comes is tried once a timer, each later up to a bound", context do
      pid = observer(context, events: {NoEvents, self()}, resubscribe: {10, 45})
      assert count(:subscribe_tried) == 1
      assert timers() == [{:subscribe, 10}]

      for expected <- [20, 40, 45, 45] do
        fire(pid, :subscribe)
        assert count(:subscribe_tried) == 1
        assert timers() == [{:subscribe, expected}]
      end

      # Nothing tries between two timers.
      for _ <- 1..3, do: gap(pid)
      assert count(:subscribe_tried) == 0
      assert %{subscription: {:retrying, 45}} = :sys.get_state(pid)
    end

    test "that goes is tried again from the first delay", context do
      {name, _events} = events(context)
      pid = observer(context, events: {Events, name}, resubscribe: {10, 45})
      assert timers() == []

      :erlang.trace(pid, true, [:receive])
      stop_supervised!(Events)
      assert_receive {:trace, ^pid, :receive, {:DOWN, _ref, :process, _worker, _reason}}, 2_000
      :erlang.trace(pid, false, [:receive])
      sync(pid)

      assert timers() == [{:subscribe, 10}]
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
      assert_receive {:DOWN, ^ref, :process, ^native, :killed}, 2_000

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
      assert {:monitored_by, [^pid]} = Process.info(first, :monitored_by)

      second = instance_process()
      :ok = EngineObserver.watch("mqtt", second, i)
      sync(pid)

      assert %{natives: %{"mqtt" => {^second, _monitor}}, monitors: monitors} =
               :sys.get_state(pid)

      assert map_size(monitors) == 1

      # Nobody monitors the first now, so its end is told to nobody.
      assert {:monitored_by, []} = Process.info(first, :monitored_by)
      assert {:monitored_by, [^pid]} = Process.info(second, :monitored_by)

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
      assert row("Up Less than a second") == row("Up 3 seconds")
      assert row("Up About a minute (healthy)") == row("Up 3 hours (healthy)")

      assert row("Up Less than a second (health: starting)") ==
               row("Up 9 seconds (health: starting)")

      assert row("Exited (137) 3 seconds ago") == row("Exited (137) 4 hours ago")
      assert row("Exited (0) Less than a second ago") == row("Exited (0) 2 days ago")
      assert row("Restarting (1) 2 seconds ago") == row("Restarting (1) 9 seconds ago")
    end

    test "is what the engine's sentence says, without its durations" do
      assert row("Up Less than a second").detail == {nil, nil}
      assert row("Up 2 minutes (unhealthy)").detail == {nil, "unhealthy"}
      assert row("Up 2 minutes (Paused)").detail == {nil, "Paused"}
      assert row("Exited (-1) 2 minutes ago").detail == {-1, nil}
      assert row("Restarting (255) Less than a second ago").detail == {255, nil}
      assert row("Removal In Progress", %{state: "removing"}).detail == {nil, nil}
      assert row("Dead", %{state: "dead"}).detail == {nil, nil}
      assert row("Created", %{state: "created"}).detail == {nil, nil}
      assert row("").detail == {nil, nil}
      assert row(nil).detail == {nil, nil}
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
        row("Removal In Progress", %{state: "removing"}),
        row("Dead", %{state: "dead"}),
        row("Up 3 seconds", %{image: "r:2"}),
        row("Up 3 seconds", %{id: "j"}),
        row(nil, %{state: nil})
      ]

      assert length(Enum.uniq(rows)) == length(rows)
    end
  end

  describe "under the resource supervisor, beside real runtimes" do
    import Vagus.Resource.Harness

    alias Vagus.App.{AuthIndex, Pulls}
    alias Vagus.Resource.{Runtime, Store}
    alias Vagus.Resource.Toys.{Follower, Probe}

    # Two followers, each of which leaves a note per pass and writes
    # nothing, with the token table and the pull worker as the application
    # has them.
    setup context do
      socket = context.engine.socket
      test = self()
      fuse = :atomics.new(1, [])

      sys =
        start_system(
          controllers: [Probe, Follower],
          services: &[{AuthIndex, instance: &1}],
          pulls: [engine: [socket: socket]],
          observers:
            &[
              {EngineObserver,
               instance: &1,
               controller: Follower,
               events: nil,
               interval: :infinity,
               backend: Broken,
               backend_opts: [test: test, fuse: fuse, engine: [socket: socket]]}
            ]
        )

      given_ready(sys, {:probe, "p", %{}})

      for name <- ["a", "b"],
          do: {:ok, _} = Store.create(:follower, name, %{"target" => "p"}, sys.i)

      settle(sys)
      notes(sys)
      %{sys: sys, pid: Process.whereis(EngineObserver.name(sys.instance)), fuse: fuse}
    end

    defp whereabouts(sys) do
      %{
        follower: Process.whereis(Runtime.name(sys.instance, Follower)),
        probe: Process.whereis(Runtime.name(sys.instance, Probe)),
        index: Process.whereis(AuthIndex.name(sys.instance)),
        pulls: Process.whereis(Pulls.name(sys.instance)),
        pull_tasks: Process.whereis(Pulls.tasks(sys.instance)),
        controllers: Process.whereis(Vagus.Resource.Controllers.Supervisor.name(sys.instance))
      }
    end

    # A pass of "a" that is in flight, parked in its observation.
    defp step_in_flight(sys) do
      put_fact(sys, {:follow, "a"}, :block)
      Runtime.enqueue(Follower, "a", sys.i)
      assert_receive {:following, "a", step}, sys.wait
      step
    end

    defp finish(sys, step) do
      put_fact(sys, {:follow, "a"}, nil)
      send(step, :go)
      settle(sys)
    end

    test "stands last: after the controllers, which stand after the services", %{sys: sys} do
      children =
        for {id, _pid, _type, _modules} <-
              Supervisor.which_children(Module.concat(sys.instance, Supervisor)),
            do: id

      # Listed last started first.
      assert [
               EngineObserver,
               Vagus.Resource.Controllers.Supervisor,
               _pull_tasks,
               Pulls,
               AuthIndex | _
             ] = children
    end

    test "an event is a pass for that app's resource and for no other", %{sys: sys, pid: pid} do
      event(pid, "app_b", "die")
      event(pid, "app_nobody", "die")
      settle(sys)

      assert notes(sys) == [{:followed, "b", 1}]
    end

    test "a container that appeared is a pass for its app", %{sys: sys, pid: pid, engine: engine} do
      Model.put_container(engine, "app_a")
      fire(pid, :tick)
      settle(sys)

      assert notes(sys) == [{:followed, "a", 1}]
    end

    test "killed, it takes nothing with it, and its replacement has everything looked at", %{
      sys: sys,
      pid: pid
    } do
      before = whereabouts(sys)
      step = step_in_flight(sys)
      alive = Process.monitor(step)
      notes(sys)

      TestInstance.kill_observed(pid, Process.whereis(Module.concat(sys.instance, Supervisor)))

      # The supervisor has dealt with the death: whatever it was going to
      # replace, it has.
      assert whereabouts(sys) == before
      assert Process.whereis(EngineObserver.name(sys.instance)) != pid
      refute_received {:DOWN, ^alive, :process, ^step, _reason}

      finish(sys, step)
      assert_received {:DOWN, ^alive, :process, ^step, :normal}

      # "b" had no reason for a pass but the new observer's resync.
      assert {:followed, "b", 1} in notes(sys)
    end

    test "ended by a backend that raises, the same: the defect costs the observer alone", %{
      sys: sys,
      pid: pid,
      fuse: fuse
    } do
      before = whereabouts(sys)
      step = step_in_flight(sys)
      alive = Process.monitor(step)
      notes(sys)
      count(:listed)

      ref = Process.monitor(pid)
      :atomics.put(fuse, 1, 1)
      send(pid, {:docker_events, :gap})
      assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{}, _stack}}, 2_000

      # The listing that raised, and the one its replacement starts with.
      assert_receive :listed, 2_000
      assert_receive :listed, 2_000

      assert whereabouts(sys) == before
      refute_received {:DOWN, ^alive, :process, ^step, _reason}

      finish(sys, step)
      assert {:followed, "b", 1} in notes(sys)
    end

    test "the controllers' supervisor replaced, it is replaced after it", %{sys: sys, pid: pid} do
      before = whereabouts(sys)
      supervisor = Process.whereis(Module.concat(sys.instance, Supervisor))

      # Ended, not killed: a supervisor that is killed leaves its children.
      :erlang.trace(supervisor, true, [:receive])
      :ok = :sys.terminate(before.controllers, :boom)
      controllers = before.controllers
      assert_receive {:trace, ^supervisor, :receive, {:EXIT, ^controllers, :boom}}, 2_000
      :erlang.trace(supervisor, false, [:receive])
      :sys.get_state(supervisor)

      settle(sys)
      now = whereabouts(sys)
      assert now.controllers != before.controllers
      assert Process.whereis(EngineObserver.name(sys.instance)) != pid
      assert {now.index, now.pulls} == {before.index, before.pulls}
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
         resync: fn _controller, _i -> :ok end,
         events: nil,
         backend_opts: [engine: [socket: Vagus.Test.FakeEngine.socket_path()]],
         interval: :infinity}
      )

    :ok = Native.start(slug, opts)
    # The process to watch is the observation's own.
    assert {:ok, %{process: broker}} = Native.observe(slug, opts)
    assert is_pid(broker)

    :ok = EngineObserver.watch(slug, broker, instance: instance)
    :sys.get_state(observer)
    refute_received {:woken, _controller, _app}

    # Returns once the supervisor has dealt with the death, and would have
    # started the child again had it been one to start again.
    TestInstance.kill_observed(broker, supervisor)

    assert_receive {:woken, __MODULE__, ^slug}, 2_000
    assert %{active: 0, specs: 0} = DynamicSupervisor.count_children(supervisor)
    assert Native.observe(slug, opts) == {:ok, :absent}
  end
end
