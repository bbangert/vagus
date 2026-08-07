defmodule Vagus.API.Listener do
  @moduledoc """
  Owns the Supervisor-API's `Bandit` listener and the address race it has to
  survive.

  ## Why the listener is not a plain child

  On target the listener binds the hassio bridge anchor `172.30.32.2`
  (`config :vagus, :api_bind_ip`) instead of the wildcard, so the API exists
  on the bridge and nowhere else — Core is then free to take `0.0.0.0:80`
  for itself, and add-ons still reach `http://supervisor/` through
  `Vagus.Network.Nat`'s DNAT.

  That address does not exist at boot. It is added with `ip addr add` onto
  the `hassio` bridge interface (`Vagus.Network.ensure_supervisor_ip/0`),
  which cannot happen before balena-engine is up and has created the
  network — `Vagus.Addon.BootStarter` does it after its engine poll
  succeeds, tens of seconds into a boot, long after `Vagus.Application`
  starts this subtree. Binding a not-yet-configured address fails
  `:eaddrnotavail`, and a `Bandit` child that fails at `init` would take
  `Vagus.API.Supervisor` — and then, once its restart budget is spent, the
  whole `:vagus` app — down with it, in a tight loop with no backoff.

  `Vagus.Mqtt.Broker` hit the same race and answered it by binding
  `0.0.0.0` instead (see its `default_ip/0`); that is not available here,
  because vacating port 80 for Core is the entire point.

  So the listener is started *into* `Vagus.API.ListenerSupervisor` (a
  `DynamicSupervisor`) by this `GenServer`, which retries every
  `:retry_ms` until the bind succeeds and monitors it afterwards — the same
  shape `Vagus.Engine.Manager` uses for the balena-engine daemon, for the
  same reason: a failure that will resolve on its own must back off, not
  crash. Consequence to know: on target the API answers nothing at all
  until the bridge is up. Nothing can reach it before then anyway — the
  address it would answer on is precisely what is missing.

  A `:api_bind_ip` that is unset (`:host`, `mix test`) means no `ip:`
  option, i.e. Bandit's wildcard default, and the first attempt succeeds.
  """

  use GenServer

  require Logger

  alias Vagus.API.Dispatcher
  alias Vagus.Network

  @default_port 8888
  @retry_ms 5_000

  # A bind that keeps failing logs once, then once a minute (@retry_ms *
  # @loud_every) — enough to diagnose a device whose bridge never came up,
  # without a warning every 5s for the rest of uptime.
  @loud_every 12

  @doc """
  Starts the listener manager.

  ## Options

    * `:name` — GenServer name (default `#{inspect(__MODULE__)}`)
    * `:supervisor` — the `DynamicSupervisor` the Bandit child is started
      into (default `Vagus.API.ListenerSupervisor`)
    * `:starter` — 2-arity `(supervisor, bandit_opts) -> DynamicSupervisor.on_start_child()`
      seam, so the retry/monitor logic is testable without a socket
    * `:retry_ms` — delay between attempts (default `#{@retry_ms}`)
    * `:port`, `:ip`, `:plug` — override the values `bandit_options/1`
      otherwise reads from config
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The `Bandit` options this manager starts the listener with.

  Pure and exposed so the bind (address + port) can be asserted without
  binding anything.

  `ip:` is present only when `config :vagus, :api_bind_ip` is set — an unset
  key keeps Bandit's wildcard default, which is what `:host` and `mix test`
  want. An unparseable one degrades to the wildcard with a warning rather
  than leaving the device with no API at all; `Vagus.API.SourceGuard` is
  still in front of it, and that is the same "log and degrade" answer
  `Vagus.Network.source_bind_opts/0` gives a bad `:ingress_source_ip`.
  """
  @spec bandit_options(keyword()) :: keyword()
  def bandit_options(opts \\ []) do
    options = [
      # Upstream's aiohttp server never negotiates response compression, and
      # Bandit's compressor injects `vary: accept-encoding` into every
      # response at the adapter layer — below `conn.resp_headers`, so
      # `Vagus.API.IngressProxy`'s D8 header hygiene can't remove it.
      # Disabling compression is therefore both upstream parity and the only
      # complete fix for the vary half of audit finding D8 (F5).
      plug: Keyword.get(opts, :plug, Dispatcher),
      port: Keyword.get_lazy(opts, :port, &configured_port/0),
      http_options: [compress: false],
      # RAM discipline: no per-request processes or Registry/ETS are needed
      # for this surface. The 15-minute `read_timeout` (Thousand Island's
      # default is 60s) is deliberate: it mirrors the ingress session's own
      # 15-minute sliding idle window (`Vagus.Ingress` §B1.2), so a
      # legitimately idle-but-open ingress connection (a long-polling panel
      # asset, a slow log tail) is never killed by the transport layer
      # before the session itself would time the client out.
      thousand_island_options: [num_acceptors: 2, read_timeout: 900_000]
    ]

    case bind_ip(opts) do
      nil -> options
      ip -> Keyword.put(options, :ip, ip)
    end
  end

  defp configured_port, do: Application.get_env(:vagus, :api_port, @default_port)

  defp bind_ip(opts) do
    case Keyword.get_lazy(opts, :ip, fn -> Application.get_env(:vagus, :api_bind_ip) end) do
      nil ->
        nil

      value ->
        case Network.parse_ip(value) do
          {:ok, ip} ->
            ip

          :error ->
            Logger.warning(
              "Vagus.API.Listener: ignoring invalid :api_bind_ip #{inspect(value)} — " <>
                "binding the wildcard address instead"
            )

            nil
        end
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      supervisor: Keyword.get(opts, :supervisor, Vagus.API.ListenerSupervisor),
      starter: Keyword.get(opts, :starter, &default_start/2),
      bandit_options: bandit_options(opts),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      listener_pid: nil,
      listener_ref: nil,
      attempt: 0
    }

    {:ok, state, {:continue, :listen}}
  end

  @impl GenServer
  def handle_continue(:listen, state), do: {:noreply, listen(state)}

  @impl GenServer
  def handle_info(:retry_listen, %{listener_pid: nil} = state), do: {:noreply, listen(state)}

  # Already listening — a stray retry from a raced :DOWN is a no-op.
  def handle_info(:retry_listen, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{listener_ref: ref} = state) do
    Logger.warning(
      "Vagus.API.Listener: the HTTP listener is down (#{inspect(reason)}), " <>
        "retrying in #{state.retry_ms}ms"
    )

    Process.send_after(self(), :retry_listen, state.retry_ms)
    {:noreply, %{state | listener_pid: nil, listener_ref: nil, attempt: 0}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp listen(state) do
    case state.starter.(state.supervisor, state.bandit_options) do
      {:ok, pid} ->
        listening(state, pid)

      # A fixed child name means this is a real, non-fatal outcome: something
      # already started the listener, so adopt and monitor it rather than
      # retrying forever against a port that is already served.
      {:error, {:already_started, pid}} ->
        listening(state, pid)

      {:error, reason} ->
        retry(state, reason)
    end
  end

  defp listening(state, pid) do
    Logger.info("Vagus.API.Listener: listening on #{describe(state.bandit_options)}")
    %{state | listener_pid: pid, listener_ref: Process.monitor(pid), attempt: 0}
  end

  defp retry(state, reason) do
    attempt = state.attempt + 1

    message =
      "Vagus.API.Listener: could not bind #{describe(state.bandit_options)} " <>
        "(#{inspect(reason)}), attempt #{attempt}, retrying in #{state.retry_ms}ms"

    # The expected cause is `:eaddrnotavail` — the hassio bridge anchor is
    # not up yet — so the first failures are normal boot, not an incident.
    if rem(attempt - 1, @loud_every) == 0 do
      Logger.warning(message)
    else
      Logger.debug(message)
    end

    Process.send_after(self(), :retry_listen, state.retry_ms)
    %{state | attempt: attempt}
  end

  defp describe(options) do
    address =
      case Keyword.get(options, :ip) do
        nil -> "0.0.0.0"
        ip -> Network.format_ip(ip)
      end

    "#{address}:#{Keyword.get(options, :port)}"
  end

  # `restart: :temporary` makes this GenServer the sole restart owner. Under
  # Bandit's default (`:permanent`) the DynamicSupervisor would put its own
  # replacement on the port the moment the listener crashed, while this
  # process — which also sees the `:DOWN` — retried against a port that is
  # now taken, monitoring a dead pid and logging `:eaddrinuse` forever.
  defp default_start(supervisor, bandit_options) do
    DynamicSupervisor.start_child(
      supervisor,
      Supervisor.child_spec({Bandit, bandit_options}, restart: :temporary)
    )
  end
end
