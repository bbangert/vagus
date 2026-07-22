defmodule Vagus.Mqtt.Broker do
  @moduledoc """
  The native MQTT broker subtree (M5, `.claude/plans/vagus-mqtt/`) — an embedded
  `mqttx` MQTT 3.1.1 broker presented to Home Assistant Core as a "virtual
  add-on" (no container) behind the `Vagus.Addon.Backend.Native` seam.

  This supervisor is the unit `Vagus.Addon.Backend.Native.Supervisor` starts and
  stops per the add-on lifecycle. It holds three children under `:rest_for_one`
  (each started before the ones that depend on it, so a crash restarts its
  dependents but never its dependencies):

    1. `Vagus.Mqtt.Broker.AuthCache` — the short-TTL negative-auth cache table
       (reconnect-storm mitigation). First, so the table always exists while the
       listener is accepting connections.
    2. `Vagus.Mqtt.Broker.Subscriptions` — the subscription registry / routing
       core (mqttx does no inter-client routing itself). Before the listener so
       that if it crashes, the listener is restarted with it, dropping
       connections so clients reconnect and re-subscribe into a fresh registry
       rather than silently losing messages against stale routing state.
    3. the `MqttX.Server` TCP listener (ThousandIsland transport) on port 1883,
       dispatching to `Vagus.Mqtt.Broker.Handler`, with a coarse connection-rate
       cap (`max_connections`).

  `supported_versions: [4]` restricts negotiation to MQTT 3.1.1, the v1
  conformance target (mqttx's 5.0 codec paths stay available but v1 is not gated
  on full 5.0 semantics). Note the mqttx API split: listener binding (`:port`,
  `:ip`) goes in the 3rd `start_link` arg, but protocol options like
  `supported_versions` are read from `handler_opts[:transport_opts]` (the 2nd
  arg, as a map) — the 3rd arg is only consulted by the transport adapter.

  On target the listener binds the supervisor bridge IP
  (`Vagus.Network.supervisor_ip/0`) so add-on containers and Core can both reach
  it; on `:host`/test it binds loopback. Both are overridable via `:ip`/`:port`
  opts (the hermetic test picks a free port).
  """

  use Supervisor

  alias Vagus.Mqtt.Broker.{AuthCache, Handler, Logs, Provider, Subscriptions}

  @default_port 1883

  # New connections accepted per second before mqttx's transport rate limiter
  # closes the excess — a coarse reconnect-storm cap (a home setup never
  # legitimately opens this many new MQTT connections/second; a storm does).
  @default_max_connections 200

  @doc """
  Starts the broker subtree.

  ## Options

    * `:name` — supervisor name (default `#{inspect(__MODULE__)}`)
    * `:subscriptions_name` — registry name (default `<name>.Subscriptions`)
    * `:port` — TCP listen port (default `#{@default_port}`)
    * `:ip` — bind address tuple (default: loopback on host/test, supervisor
      bridge IP on target)
    * `:auth` — keyword opts for `Vagus.Mqtt.Broker.Auth.config/1` (slug,
      services server, `check_login` opts, option logins, allow_anonymous). The
      negative-cache table is injected automatically.
    * `:max_connections` — new connections/second before excess CONNECTs are
      rate-limited (default `#{@default_max_connections}`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    subs_name = Keyword.get(opts, :subscriptions_name, Module.concat(name, Subscriptions))
    authcache_name = Keyword.get(opts, :auth_cache_name, Module.concat(name, AuthCache))
    # String segment (not the `Logs` alias) so `Vagus.Addon.Backend.Native.logs/2`
    # re-derives the identical name — `Module.concat(name, Logs)` would append the
    # alias's full path, `Module.concat(name, "Logs")` appends just the segment.
    logs_name = Keyword.get(opts, :logs_name, Module.concat(name, "Logs"))
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, default_ip())
    max_connections = Keyword.get(opts, :max_connections, @default_max_connections)

    # Inject the negative-cache table into the handler's auth config so the
    # broker's reconnect-storm mitigation is wired without the caller knowing.
    auth = Keyword.put(Keyword.get(opts, :auth, []), :neg_cache, authcache_name)

    children =
      [
        # Ordered first under :rest_for_one so the cache table always exists while
        # the listener is up, and a Subscriptions/listener crash never drops it.
        {AuthCache, name: authcache_name},
        {Subscriptions, name: subs_name},
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
                 subscriptions: subs_name,
                 auth: auth,
                 transport_opts: %{supported_versions: [4]}
               ],
               [
                 transport: MqttX.Transport.ThousandIsland,
                 port: port,
                 ip: ip,
                 rate_limit: [max_connections: max_connections, interval: 1000]
               ]
             ]}
        },
        # Last: the telemetry-fed log buffer (MQ-P3-T2). After the listener so a
        # buffer crash restarts only itself, never drops connections.
        {Logs, name: logs_name}
      ] ++ provider_child(name, port, Keyword.get(opts, :provider))

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end

  # The `mqtt` service/discovery provider (MQ-P4-T1) — added only when the broker
  # is the real native add-on (`Backend.Native` passes `:provider`); bare
  # instances (routing/auth unit tests) omit it and never touch the global
  # service/discovery registries. Last child so it publishes with the listener up.
  defp provider_child(_name, _port, nil), do: []

  defp provider_child(name, port, provider_opts) do
    opts =
      [name: Module.concat(name, "Provider"), host: advertised_host(), port: port] ++
        Keyword.take(provider_opts, [:slug, :services, :discovery, :data_dir])

    [{Provider, opts}]
  end

  if Mix.target() == :host do
    defp default_ip, do: {127, 0, 0, 1}
    defp advertised_host, do: "127.0.0.1"
  else
    defp default_ip do
      {:ok, ip} = :inet.parse_address(String.to_charlist(Vagus.Network.supervisor_ip()))
      ip
    end

    defp advertised_host, do: Vagus.Network.supervisor_ip()
  end
end
