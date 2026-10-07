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

  setup do
    engine = FakeEngine.start_model()
    on_exit(fn -> FakeEngine.stop(engine) end)

    events = :"events_subscribers_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: events, socket: engine.socket, backoff: {5, 20}})
    # This process's own notice: the stream is up before a watchdog subscribes.
    :ok = Events.subscribe(events)
    assert_receive {:docker_events, :gap}, 2_000

    %{engine: engine, events: events}
  end

  # The watchdog was sent a gap notice when it subscribed to the running
  # stream, and another for the reconnect. Its state is read after both.
  defp after_gaps(engine, watchdog) do
    before = :sys.get_state(watchdog)
    Model.drop_event_streams(engine)
    assert_receive {:docker_events, :gap}, 2_000
    {before, :sys.get_state(watchdog)}
  end

  test "the app watchdog ignores a gap notice", %{engine: engine, events: events} do
    state = start_supervised!({Vagus.Addon.State, name: :"#{events}_state", persist_path: nil})

    watchdog =
      start_supervised!(
        {Vagus.Addon.Watchdog, name: :"#{events}_watchdog", events: events, state: state}
      )

    {before, later} = after_gaps(engine, watchdog)
    assert later == before
    assert later.events_ref != nil
  end

  test "the Core watchdog ignores a gap notice", %{engine: engine, events: events} do
    path = Path.join(System.tmp_dir!(), "#{events}.json")
    on_exit(fn -> File.rm(path) end)
    store = :"#{events}_tokens"

    start_supervised!(%{
      id: store,
      start: {Vagus.Core.TokenStore, :start_link, [[name: store, path: path]]}
    })

    watchdog =
      start_supervised!(
        {Vagus.Core.Watchdog,
         name: :"#{events}_watchdog", events: events, token_store: store, rebuild: fn -> :ok end}
      )

    {before, later} = after_gaps(engine, watchdog)
    assert later == before
    assert later.events_ref != nil
  end
end
