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
