defmodule Vagus.Mqtt.Broker.Subscriptions do
  @moduledoc """
  The broker's subscription registry — the routing core `MqttX.Server` does NOT
  provide (M5, `.claude/plans/vagus-mqtt/`).

  mqttx is an MQTT protocol *framework*, not a turnkey broker: it parses/encodes
  every packet type and runs the QoS/keepalive/LWT/retained state machines, but
  it performs **zero inter-client routing** — a PUBLISH from one connection never
  reaches another connection's subscriptions on its own (see the scratchpad
  dead-end note and `deps/mqttx` README §"Publishing from a server callback").
  This GenServer supplies that missing half.

  It owns an authoritative `MqttX.Server.Router` trie (mqttx's own, tested
  wildcard matcher — `+`/`#`, shared subscriptions, no-local) keyed by connection
  pid, and `Process.monitor`s each subscribing connection so entries are reaped
  automatically when a client disconnects or crashes (the one thing Elixir's
  exact-key pubsub primitives — `Registry`, `:pg`, `Phoenix.PubSub` — give for
  free, and the reason we keep mqttx's trie for the matching they *can't* do).

  `Vagus.Mqtt.Broker.Handler` calls `subscribe/4` from `handle_subscribe`,
  `unsubscribe/3` from `handle_unsubscribe`, and `match/3` from `handle_publish`
  to fan a message out to matching subscribers. One registry is started per
  broker instance under `Vagus.Mqtt.Broker`.

  Correctness-first: every publish is a `GenServer.call` here. Once the on-device
  conformance gate passes, the hot `match/3` path can move to an ETS/persistent
  -term snapshot read directly in the connection process — deferred.
  """

  use GenServer

  alias MqttX.Server.Router

  @type topic :: binary() | MqttX.Topic.normalized_topic()

  @doc "Starts the registry. `:name` (default `#{inspect(__MODULE__)}`) registers it."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register `pid`'s subscription to `filter`.

  `opts` is a keyword forwarded to `MqttX.Server.Router.subscribe/4` — `:qos`
  (max QoS) plus the MQTT 5.0 subscription options (`:no_local`,
  `:retain_as_published`, `:retain_handling`). Idempotent per pid via a monitor.
  """
  @spec subscribe(GenServer.server(), topic(), pid(), keyword()) :: :ok
  def subscribe(server, filter, pid, opts) do
    GenServer.call(server, {:subscribe, filter, pid, opts})
  end

  @doc "Remove `pid`'s subscription to `filter`."
  @spec unsubscribe(GenServer.server(), topic(), pid()) :: :ok
  def unsubscribe(server, filter, pid) do
    GenServer.call(server, {:unsubscribe, filter, pid})
  end

  @doc """
  All subscribers whose filter matches `topic`, as `[{pid, %{qos: q}}]`.

  `publisher` (the publishing connection's pid) is excluded from matches carrying
  the MQTT 5.0 `no_local` option; pass `nil` to skip that filtering. Advances the
  round-robin cursor for any matched shared-subscription groups.
  """
  @spec match(GenServer.server(), topic(), pid() | nil) :: [{pid(), map()}]
  def match(server, topic, publisher \\ nil) do
    GenServer.call(server, {:match, topic, publisher})
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{router: Router.new(), monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:subscribe, filter, pid, opts}, _from, state) do
    router = Router.subscribe(state.router, filter, pid, opts)
    {:reply, :ok, %{ensure_monitor(state, pid) | router: router}}
  end

  def handle_call({:unsubscribe, filter, pid}, _from, state) do
    router = Router.unsubscribe(state.router, filter, pid)
    {:reply, :ok, %{state | router: router}}
  end

  def handle_call({:match, topic, publisher}, _from, state) do
    {matches, router} = Router.match_and_advance(state.router, topic, publisher)
    {:reply, matches, %{state | router: router}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    router = Router.unsubscribe_all(state.router, pid)
    {:noreply, %{state | router: router, monitors: Map.delete(state.monitors, pid)}}
  end

  # One monitor per connection pid regardless of how many filters it subscribes
  # to — `unsubscribe_all/2` on DOWN clears every one of that pid's entries.
  defp ensure_monitor(%{monitors: monitors} = state, pid) do
    if Map.has_key?(monitors, pid) do
      state
    else
      %{state | monitors: Map.put(monitors, pid, Process.monitor(pid))}
    end
  end
end
