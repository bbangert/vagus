defmodule Vagus.Runtime.EventsSubscribersTest do
  @moduledoc """
  The subscribers that predate the gap notice get it like any other, through
  a real `Vagus.Runtime.Events`, and must be none the worse for it.
  """

  use ExUnit.Case, async: true

  alias Vagus.Runtime.Events
  alias Vagus.Test.FakeEngine
  alias Vagus.Test.FakeEngine.Model

  @moduletag :capture_log

  # The worker retries a socket nothing listens at yet, so that a watchdog
  # can subscribe, and be read, before it has been sent any notice.
  setup do
    socket = FakeEngine.socket_path()
    events = :"events_subscribers_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: events, socket: socket, backoff: {5, 20}})
    %{socket: socket, events: events}
  end

  # Returns the watchdog's state from before any notice, and after each of
  # two: the first stream's and a reconnect's. Each later state is read once
  # the notice has been seen arriving at the watchdog, so behind it.
  defp through_two_gaps(context, watchdog) do
    before = :sys.get_state(watchdog)
    assert before.events_ref != nil
    :erlang.trace(watchdog, true, [:receive])

    engine = FakeEngine.start_model(socket: context.socket)
    on_exit(fn -> FakeEngine.stop(engine) end)
    assert_receive {:trace, ^watchdog, :receive, {:docker_events, :gap}}, 2_000
    first = :sys.get_state(watchdog)

    Model.drop_event_streams(engine)
    assert_receive {:trace, ^watchdog, :receive, {:docker_events, :gap}}, 2_000
    {before, first, :sys.get_state(watchdog)}
  end

  # Renames of each kind, through a real worker, then a sentinel the test
  # sees too: once the watchdog has received that, it has received them all.
  defp through_renames(context, watchdog, names) do
    :erlang.trace(watchdog, true, [:receive])
    engine = FakeEngine.start_model(socket: context.socket)
    on_exit(fn -> FakeEngine.stop(engine) end)
    assert_receive {:trace, ^watchdog, :receive, {:docker_events, :gap}}, 2_000
    before = :sys.get_state(watchdog)

    for {from, to} <- names,
        do: Model.emit(engine, "rename", to, %{"oldName" => "/" <> from, "exitCode" => "1"})

    Model.emit(engine, "rename", "app_sentinel", %{"oldName" => "/sentinel"})

    assert_receive {:trace, ^watchdog, :receive,
                    {:docker_event, %{action: "rename", name: "app_sentinel"}}},
                   2_000

    :erlang.trace(watchdog, false, [:receive])
    delivered = :erlang.trace_delivered(watchdog)
    assert_receive {:trace_delivered, ^watchdog, ^delivered}, 2_000

    received =
      for {from, to} <- names do
        receive do
          {:trace, ^watchdog, :receive,
           {:docker_event, %{name: ^to, attributes: %{"oldName" => old}}}}
          when old == "/" <> from ->
            {from, to}
        after
          0 -> nil
        end
      end

    {before, :sys.get_state(watchdog), Enum.reject(received, &is_nil/1)}
  end

  test "the app watchdog does nothing for a rename, to or from an app it watches", context do
    {:ok, config} =
      Vagus.Addon.Config.parse(%{
        "name" => "w",
        "version" => "1",
        "slug" => "watched",
        "description" => "d",
        "arch" => ["aarch64"],
        "image" => "i"
      })

    state =
      start_supervised!({Vagus.Addon.State, name: :"#{context.events}_state", persist_path: nil})

    :ok = Vagus.Addon.State.put(config, :started, server: state)
    :ok = Vagus.Addon.State.put_setting("watched", :watchdog, true, state)

    watchdog =
      start_supervised!(
        {Vagus.Addon.Watchdog,
         name: :"#{context.events}_watchdog", events: context.events, state: state}
      )

    names = [
      {"addon_watched", "elsewhere"},
      {"elsewhere", "addon_watched"},
      {"addon_watched", "app_watched"}
    ]

    {before, later, received} = through_renames(context, watchdog, names)

    # It was sent each of them, the one it could not see before among them.
    assert received == names
    assert later == before
    assert later.tasks == %{}
  end

  test "the Core watchdog does nothing for a rename, to or from Core's name", context do
    test = self()
    path = Path.join(System.tmp_dir!(), "#{context.events}-rename-#{System.pid()}.json")
    on_exit(fn -> File.rm(path) end)
    store = :"#{context.events}_tokens"

    start_supervised!(%{
      id: store,
      start: {Vagus.Core.TokenStore, :start_link, [[name: store, path: path]]}
    })

    watchdog =
      start_supervised!(
        {Vagus.Core.Watchdog,
         name: :"#{context.events}_watchdog",
         events: context.events,
         token_store: store,
         rebuild: fn -> send(test, :rebuild_called) end}
      )

    core = Vagus.Core.Container.name()
    names = [{core, "elsewhere"}, {"elsewhere", core}, {core, "app_core"}]
    # Three of them, as many as the dies that would be a crash loop.
    {before, later, received} = through_renames(context, watchdog, names ++ names)

    assert Enum.uniq(received) == names
    assert later == before
    refute_received :rebuild_called
  end

  test "the app watchdog ignores a gap notice", context do
    state =
      start_supervised!({Vagus.Addon.State, name: :"#{context.events}_state", persist_path: nil})

    watchdog =
      start_supervised!(
        {Vagus.Addon.Watchdog,
         name: :"#{context.events}_watchdog", events: context.events, state: state}
      )

    {before, first, second} = through_two_gaps(context, watchdog)
    assert first == before
    assert second == before
  end

  test "the Core watchdog ignores a gap notice", context do
    test = self()
    path = Path.join(System.tmp_dir!(), "#{context.events}-#{System.pid()}.json")
    on_exit(fn -> File.rm(path) end)
    store = :"#{context.events}_tokens"

    start_supervised!(%{
      id: store,
      start: {Vagus.Core.TokenStore, :start_link, [[name: store, path: path]]}
    })

    watchdog =
      start_supervised!(
        {Vagus.Core.Watchdog,
         name: :"#{context.events}_watchdog",
         events: context.events,
         token_store: store,
         rebuild: fn -> send(test, :rebuild_called) end}
      )

    {before, first, second} = through_two_gaps(context, watchdog)
    assert first == before
    assert second == before
    # Read after the watchdog had handled both notices.
    refute_received :rebuild_called
  end
end
