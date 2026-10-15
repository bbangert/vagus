defmodule Vagus.Runtime.EventsTest.Source do
  @moduledoc false
  # Driven by the test: `{:stub, notices}` arrives as notices and
  # `{:stub_closed, reason}` closes the stream.
  @behaviour Vagus.Runtime.Events.Source

  @impl true
  def init(opts), do: %{test: Keyword.fetch!(opts, :test)}

  @impl true
  def connect(src) do
    send(src.test, {:source_connected, self()})
    {:ok, src}
  end

  @impl true
  def handle_info({:stub, notices}, src), do: {:ok, notices, src}
  def handle_info({:stub_closed, reason}, src), do: {:closed, reason, [], src}
  def handle_info(_other, _src), do: :unknown

  @impl true
  def close(src), do: src
end

defmodule Vagus.Runtime.EventsTest do
  # async: false — app processes register in the global App.Directory.
  use ExUnit.Case, async: false

  alias Vagus.Runtime.Engine.{Event, Fake}
  alias Vagus.Runtime.Events
  alias Vagus.Runtime.EventsTest.Source

  defp unique_name, do: :"events_#{System.unique_integer([:positive])}"

  # Starts an instance on the stub source; returns its pid once connected.
  defp start_events(opts \\ []) do
    name = unique_name()
    start_supervised!({Events, [name: name, source: Source, test: self()] ++ opts})
    assert_receive {:source_connected, events}, 1_000
    {name, events}
  end

  defp subscribed(opts \\ []) do
    {name, events} = start_events(opts)
    :ok = Events.subscribe(name)
    events
  end

  defp emit(events, notices), do: send(events, {:stub, List.wrap(notices)})

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(10) && do_wait_until(fun, deadline)
    end
  end

  describe "the managed gate" do
    test "a managed event reaches subscribers as {:engine_event, event}" do
      events = subscribed()

      event = %Event{
        action: :die,
        name: "unlabelled",
        id: "abc123",
        exit_code: 137,
        managed: true
      }

      emit(events, event)
      assert_receive {:engine_event, ^event}, 1_000
    end

    test "an unmanaged, non-addon event is not forwarded; an addon_ one is" do
      events = subscribed()

      emit(events, %Event{action: :die, name: "unrelated-container", id: "zzz999"})
      refute_receive {:engine_event, _}, 300

      emit(events, %Event{action: :start, name: "addon_bar", id: "def456"})
      assert_receive {:engine_event, %Event{name: "addon_bar", action: :start}}, 1_000
    end

    test "a Core-named event passes without the label; a look-alike name does not" do
      events = subscribed()
      core = Vagus.Core.Container.name()

      emit(events, %Event{action: :die, name: core, id: "core01", exit_code: 1})
      assert_receive {:engine_event, %Event{name: ^core, exit_code: 1}}, 1_000

      emit(events, %Event{action: :die, name: core <> "-imposter", id: "imp01"})
      refute_receive {:engine_event, %Event{id: "imp01"}}, 300
    end
  end

  describe "the stream" do
    test "a closed stream reconnects and the subscriber keeps receiving" do
      events = subscribed()

      ExUnit.CaptureLog.capture_log(fn ->
        send(events, {:stub_closed, :stream_ended})
        # The first retry waits the 1 s floor.
        assert_receive {:source_connected, ^events}, 5_000
      end)

      emit(events, %Event{action: :start, name: "addon_reco", id: "reco1"})
      assert_receive {:engine_event, %Event{name: "addon_reco"}}, 1_000
    end

    test "a dead subscriber is pruned and does not crash the server" do
      {name, events} = start_events()
      task = Task.async(fn -> Events.subscribe(name) end)
      dead_pid = task.pid
      Task.await(task)

      wait_until(fn -> not Map.has_key?(:sys.get_state(events).subscribers, dead_pid) end)

      emit(events, %Event{action: :start, name: "addon_alive", id: "alive1"})
      _ = :sys.get_state(events)
      assert Process.alive?(events)
    end
  end

  describe "schedule_reconnect/2" do
    import ExUnit.CaptureLog

    # A close can be reported twice for one drop: that must arm one timer,
    # warn once and advance the backoff once.
    test "a second schedule for the same drop is a no-op" do
      {state, log} =
        with_log(fn ->
          state =
            Events.schedule_reconnect(:stream_ended, %{backoff_ms: 1_000, reconnect_timer: nil})

          Events.schedule_reconnect({:closed, :again}, state)
        end)

      assert state.backoff_ms == 2_000
      assert is_reference(state.reconnect_timer)
      assert length(Regex.scan(~r/event stream dropped/, log)) == 1

      Process.cancel_timer(state.reconnect_timer)
    end
  end

  describe "app processes" do
    import Vagus.AppFixtures, only: [app_config: 2, app_info: 1, install_app: 1]

    defp app_slug, do: "events_app_#{System.unique_integer([:positive])}"

    defp app_pid(slug) do
      [{pid, _}] = Registry.lookup(Vagus.App.Directory, {:slug, slug})
      pid
    end

    test "an app's container event goes to whichever process holds its slug when sent" do
      slug = app_slug()
      {_name, events} = start_events()

      {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
      emit(events, %Event{action: :die, name: "addon_" <> slug, id: "c1"})
      assert_receive {:engine_event, %Event{action: :die, id: "c1"}}, 1_000

      # A restarted app process is found by the next event, with no subscribe.
      :ok = Registry.unregister(Vagus.App.Directory, {:slug, slug})
      test = self()

      owner =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
          send(test, :registered)

          receive do
            event -> send(test, {:owner_got, event})
          end
        end)

      assert_receive :registered
      emit(events, %Event{action: :start, name: "addon_" <> slug, id: "c2"})
      assert_receive {:owner_got, {:engine_event, %Event{action: :start, id: "c2"}}}, 1_000
      refute_received {:engine_event, %Event{id: "c2"}}
      assert is_pid(owner)
    end

    # The repair for an event lost while the stream was down: a reconnect
    # lists the engine's containers and the app process is told the die.
    test "a die missed while disconnected is repaired by the reconnect's listing" do
      slug = app_slug()
      install_app(app_config(slug, %{}))
      pid = app_pid(slug)
      name = "addon_" <> slug

      fake = Fake.start()
      Fake.put_container(fake, name, id: "c1", state: :running)

      :erlang.trace(pid, true, [:receive])
      on_exit(fn -> :erlang.trace(pid, false, [:receive]) end)

      {_name, events} = start_events(resync: true, engine_opts: [engine: Fake, fake: fake])

      # The first connect: a running container this process did not start is
      # adopted as its own.
      emit(events, :ready)

      assert_receive {:trace, ^pid, :receive, {:engine_event, %Event{action: :start, id: "c1"}}},
                     1_000

      assert {:ok, %{state: :started}} = app_info(slug)

      # The container dies while the stream is down; nobody hears it.
      ExUnit.CaptureLog.capture_log(fn ->
        send(events, {:stub_closed, :stream_ended})
        Fake.put_container(fake, name, id: "c1", state: :exited, exit_code: 137)
        assert_receive {:source_connected, ^events}, 5_000
      end)

      emit(events, :ready)

      assert_receive {:trace, ^pid, :receive,
                      {:engine_event, %Event{action: :die, id: "c1", exit_code: 137}}},
                     1_000

      assert {:ok, %{state: :error}} = app_info(slug)
      assert %{last_event: {:exited, 137}} = :sys.get_state(pid) |> elem(1)
    end

    test "a listing that fails leaves the stream running" do
      test = self()
      list = fn -> send(test, :listed) && {:error, :down} end
      events = subscribed(list: list)

      ExUnit.CaptureLog.capture_log(fn ->
        emit(events, :ready)
        assert_receive :listed, 1_000
      end)

      emit(events, %Event{action: :start, name: "addon_after", id: "a1"})
      assert_receive {:engine_event, %Event{id: "a1"}}, 1_000
    end

    test "a live event that arrives while the listing runs is sent after the listing's" do
      slug = app_slug()
      owner = owner(slug)
      events = subscribed(list: held_listing(self()))

      emit(events, :ready)
      assert_receive {:listing, lister}, 1_000

      emit(events, %Event{action: :start, name: "addon_" <> slug, id: "c1"})
      assert_receive {:engine_event, %Event{action: :start, id: "c1"}}, 1_000

      send(lister, {:go, [container("addon_" <> slug, "c1", :exited, 1)]})

      assert_receive {:owner_got, %Event{action: first, id: "c1"}}, 1_000
      assert_receive {:owner_got, %Event{action: last, id: "c1"}}, 1_000
      assert {first, last} == {:die, :start}
      assert ping(owner) == :pong
      refute_received {:owner_got, _}
    end

    test "a listing from an earlier connection is dropped" do
      slug = app_slug()
      owner = owner(slug)
      {_name, events} = start_events(list: held_listing(self()))

      emit(events, :ready)
      assert_receive {:listing, old}, 1_000

      ExUnit.CaptureLog.capture_log(fn ->
        send(events, {:stub_closed, :stream_ended})
        assert_receive {:source_connected, ^events}, 5_000
      end)

      emit(events, :ready)
      assert_receive {:listing, new}, 1_000

      # Answered while the new connection's listing still runs.
      ref = Process.monitor(old)
      send(old, {:go, [container("addon_" <> slug, "c1", :exited, 1)]})
      assert_receive {:DOWN, ^ref, :process, ^old, :normal}, 1_000
      _ = :sys.get_state(events)
      assert ping(owner) == :pong
      refute_received {:owner_got, _}

      send(new, {:go, [container("addon_" <> slug, "c2", :running, nil)]})
      assert_receive {:owner_got, %Event{action: :start, id: "c2"}}, 1_000
      assert ping(owner) == :pong
      refute_received {:owner_got, _}
    end

    test "a listing that dies lets go of the live events it held back" do
      slug = app_slug()
      owner = owner(slug)
      events = subscribed(list: held_listing(self()))

      emit(events, :ready)
      assert_receive {:listing, lister}, 1_000
      emit(events, %Event{action: :start, name: "addon_" <> slug, id: "c1"})
      assert_receive {:engine_event, %Event{action: :start, id: "c1"}}, 1_000

      ExUnit.CaptureLog.capture_log(fn ->
        ref = Process.monitor(lister)
        Process.exit(lister, :kill)
        assert_receive {:DOWN, ^ref, :process, ^lister, :killed}
        assert_receive {:owner_got, %Event{action: :start, id: "c1"}}, 1_000
      end)

      assert ping(owner) == :pong
    end

    defp held_listing(test) do
      fn ->
        send(test, {:listing, self()})

        receive do
          {:go, containers} -> {:ok, containers}
        end
      end
    end

    # Registered as the app process, it forwards each event it is routed.
    defp owner(slug) do
      test = self()

      pid =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Vagus.App.Directory, {:slug, slug}, nil)
          send(test, :registered)
          forward(test)
        end)

      assert_receive :registered
      pid
    end

    defp forward(test) do
      receive do
        {:engine_event, event} -> send(test, {:owner_got, event})
        {:ping, from} -> send(from, :pong)
      end

      forward(test)
    end

    # Every routed event the process was sent is forwarded before the reply.
    defp ping(owner) do
      send(owner, {:ping, self()})
      assert_receive :pong, 1_000
      :pong
    end

    defp container(name, id, state, exit_code),
      do: %Vagus.Runtime.Engine.Container{name: name, id: id, state: state, exit_code: exit_code}
  end
end
