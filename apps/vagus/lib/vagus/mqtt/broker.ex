defmodule Vagus.Mqtt.Broker do
  @moduledoc """
  The native MQTT broker subtree: an embedded `mqttx` MQTT 5.0 / 3.1.1 broker
  presented to Home Assistant Core as an app with no container, behind the
  `Vagus.Addon.Backend.Native` seam.

  This supervisor is the unit `Vagus.Addon.Backend.Native.Supervisor` starts and
  stops per the app lifecycle. Its children run under `:rest_for_one` (each
  started before the ones that depend on it, so a crash restarts its
  dependents but never its dependencies):

    1. `Vagus.Mqtt.Broker.AuthCache` — the short-TTL negative-auth cache table
       (reconnect-storm mitigation). First, so the table always exists while the
       listener is accepting connections.
    2. the `MqttX.Server` TCP listener (ThousandIsland transport) on port 1883,
       dispatching to `Vagus.Mqtt.Broker.Handler`, with a coarse connection-rate
       cap (`max_connections`).
    3. `Vagus.Mqtt.Broker.Logs`, and with `:provider` the
       `Vagus.Mqtt.Broker.Provider` that publishes the `mqtt` service.

  `supported_versions: [3, 4, 5]` accepts MQTT 3.1 / 3.1.1 / 5.0 CONNECTs; Home
  Assistant Core connects with 5.0. mqttx routes, and keeps sessions, retained
  messages, Subscription Identifiers and shared subscriptions. Its session and
  retained tables are created by the process that starts the listener, this
  supervisor, so they outlive a listener restart and end with the broker app.
  Listener binding (`:port`, `:ip`, `:name`) goes in the 3rd `start_link` arg;
  protocol options are read from `handler_opts[:transport_opts]` (the 2nd arg,
  as a map).

  On target the listener binds the supervisor bridge IP
  (`Vagus.Network.supervisor_ip/0`) so add-on containers and Core can both reach
  it; on `:host`/test it binds loopback. Both are overridable via `:ip`/`:port`
  opts (the hermetic test picks a free port).
  """

  use Supervisor

  alias Vagus.Mqtt.Broker.{AuthCache, Handler, Logs, Provider}

  @default_port 1883

  # New connections accepted per second before mqttx's transport rate limiter
  # closes the excess — a coarse reconnect-storm cap (a home setup never
  # legitimately opens this many new MQTT connections/second; a storm does).
  @default_max_connections 200

  # Bounds on what clients that went away can make the broker keep: a session
  # lives at most a day after its connection, the listener keeps at most this
  # many, and each queues at most this many QoS 1/2 messages (the newest past
  # it are dropped). The queue default matches Mosquitto's max_queued_messages.
  @max_session_expiry_s 86_400
  @default_max_sessions 1_000
  @default_max_queued 1_000

  @doc """
  Starts the broker subtree.

  ## Options

    * `:name` — supervisor name (default `#{inspect(__MODULE__)}`)
    * `:port` — TCP listen port (default `#{@default_port}`)
    * `:ip` — bind address tuple (default: loopback on host/test, supervisor
      bridge IP on target)
    * `:auth` — keyword opts for `Vagus.Mqtt.Broker.Auth.config/1` (slug,
      `check_login` opts, option logins, allow_anonymous). The negative-cache
      table, and with `:provider` the published service login, are injected.
    * `:max_connections` — new connections/second before excess CONNECTs are
      rate-limited (default `#{@default_max_connections}`)
    * `:max_sessions` — sessions the listener keeps, connected or not, before a
      CONNECT that needs a new one is refused (default `#{@default_max_sessions}`)
    * `:max_queued` — QoS 1/2 messages queued per session
      (default `#{@default_max_queued}`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  # Child names derive from the start-up :name option, not request input.
  # sobelow_skip ["DOS.ModuleConcat"]
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    authcache_name = Keyword.get(opts, :auth_cache_name, Module.concat(name, AuthCache))
    # String segment (not the `Logs` alias) so `Vagus.Addon.Backend.Native.logs/2`
    # re-derives the identical name — `Module.concat(name, Logs)` would append the
    # alias's full path, `Module.concat(name, "Logs")` appends just the segment.
    logs_name = Keyword.get(opts, :logs_name, Module.concat(name, "Logs"))
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, default_ip())
    max_connections = Keyword.get(opts, :max_connections, @default_max_connections)
    max_sessions = Keyword.get(opts, :max_sessions, @default_max_sessions)
    max_queued = Keyword.get(opts, :max_queued, @default_max_queued)

    provider = provider_opts(Keyword.get(opts, :provider))

    # Inject the negative-cache table into the handler's auth config so the
    # broker's reconnect-storm mitigation is wired without the caller knowing.
    auth =
      opts
      |> Keyword.get(:auth, [])
      |> Keyword.put(:neg_cache, authcache_name)
      |> put_service_login(provider)

    children =
      [
        # Ordered first under :rest_for_one so the cache table always exists while
        # the listener is up, and a listener crash never drops it.
        {AuthCache, name: authcache_name},
        %{
          id: :listener,
          # MqttX.Server.start_link returns ThousandIsland's own supervisor pid,
          # which holds every live connection process — mark it :supervisor with an
          # :infinity shutdown so TI's graceful connection drain isn't brutal-killed.
          type: :supervisor,
          shutdown: :infinity,
          start:
            {MqttX.Server, :start_link,
             [
               Handler,
               [
                 auth: auth,
                 transport_opts: %{
                   supported_versions: [3, 4, 5],
                   max_session_expiry_interval: @max_session_expiry_s,
                   max_sessions: max_sessions,
                   max_outbound_queue: max_queued,
                   # Home Assistant subscribes to each entity's topics one by
                   # one, a few per device; this leaves a large install ample
                   # room while one client cannot grow the index without
                   # bound. Past it a SUBSCRIBE is refused per filter.
                   max_subscriptions: 10_000,
                   # No cap, as before and as Mosquitto: payloads such as
                   # camera snapshots can exceed mqttx's 1 MiB default, and
                   # an over-size PUBLISH closes the connection, so its client
                   # reconnects and sends it again. CONNACK then carries no
                   # Maximum Packet Size.
                   max_packet_size: :infinity,
                   # Saves nothing on a loopback/LAN link; keeps the PUBLISHes
                   # Home Assistant receives byte-for-byte as before.
                   outbound_topic_aliases: false
                 }
               ],
               [
                 transport: MqttX.Transport.ThousandIsland,
                 # Listeners sharing a name across connected nodes merge into
                 # one broker (mqttx clustering over `:pg`); the default name
                 # is the port, which every board shares.
                 name: listener_name(port),
                 port: port,
                 ip: ip,
                 # MQTT keepalive governs liveness, not ThousandIsland's 60 s
                 # socket read timeout, which would drop an idle Home
                 # Assistant (keep-alive 60 s) every ~130 s. mqttx defaults
                 # to this too; explicit so a default change cannot bring
                 # the drop back.
                 read_timeout: :infinity,
                 rate_limit: [max_connections: max_connections, interval: 1000]
               ]
             ]}
        },
        # Last: the telemetry-fed log buffer (MQ-P3-T2). After the listener so a
        # buffer crash restarts only itself, never drops connections.
        {Logs, name: logs_name}
      ] ++ provider_child(name, port, provider)

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end

  # Unique to this VM, so no other node can share it, and stable across
  # restarts within it: mqttx keeps a cluster member per listener name for the
  # life of the VM, so a fresh name per start would leak one each time.
  @doc false
  @spec listener_name(:inet.port_number()) :: {module(), binary(), :inet.port_number()}
  def listener_name(port) do
    key = {__MODULE__, :vm_token}

    token =
      case :persistent_term.get(key, nil) do
        nil ->
          token = :crypto.strong_rand_bytes(16)
          :persistent_term.put(key, token)
          token

        token ->
          token
      end

    {__MODULE__, token, port}
  end

  # The password is read here, before the listener starts, so the first
  # CONNECT already knows the login the Provider publishes; a start after a
  # restore reads the restored one. A closure, so it is in no child spec and
  # no supervisor report.
  defp provider_opts(nil), do: nil

  defp provider_opts(opts) do
    opts =
      Keyword.take(opts, [
        :slug,
        :data_dir,
        :publish_retry,
        :publish_backoff_ms,
        :withdraw_timeout
      ])

    login = Provider.service_login(opts)
    Keyword.put(opts, :service_login, fn -> login end)
  end

  defp put_service_login(auth, nil), do: auth

  defp put_service_login(auth, provider),
    do: Keyword.put(auth, :service_login, Keyword.fetch!(provider, :service_login))

  # The `mqtt` service/discovery provider (MQ-P4-T1) — added only when the broker
  # is the real native app (`Backend.Native` passes `:provider`); bare
  # instances (routing/auth unit tests) omit it and never publish. Last child
  # so it publishes with the listener up.
  defp provider_child(_name, _port, nil), do: []

  # name is the start-up :name option, not request input.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp provider_child(name, port, provider) do
    [
      {Provider,
       [name: Module.concat(name, "Provider"), host: advertised_host(), port: port] ++ provider}
    ]
  end

  if Mix.target() == :host do
    defp default_ip, do: {127, 0, 0, 1}
    defp advertised_host, do: "127.0.0.1"
  else
    # Bind all interfaces, NOT the supervisor anchor (172.30.32.2): the broker
    # is started early (engine-independent, ahead of boot's engine gate), before
    # the hassio bridge's `.2` anchor is bound, so binding `.2` fails with
    # `:eaddrnotavail` on a fresh boot (P6 finding). `0.0.0.0` always succeeds and
    # is reachable at `.2` once the bridge comes up + on host-net localhost for
    # Core — the service still *advertises* `.2`. (HAOS's Mosquitto also exposes
    # 1883 on the host.)
    defp default_ip, do: {0, 0, 0, 0}

    defp advertised_host, do: Vagus.Network.supervisor_ip()
  end
end
