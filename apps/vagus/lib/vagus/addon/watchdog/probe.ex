defmodule Vagus.Addon.Watchdog.Probe do
  @moduledoc """
  The application-probe half of the add-on watchdog
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B7) — real Supervisor's
  periodic `_watchdog_app_application()` scheduler task
  (`supervisor/misc/tasks.py`, `RUN_WATCHDOG_APP_APPLICATION = 120`).

  ## Why this is a sibling of `Vagus.Addon.Watchdog`, not merged into it (§B6.5)

  §B6.5 is explicit the container-event watchdog and this application probe
  are **entirely separate code paths** in real Supervisor, and stay that way
  here:

    * **Trigger** — `Vagus.Addon.Watchdog` reacts to docker `die`/
      `health_status: unhealthy` bus events; this module polls on a fixed
      120s cadence regardless of any event.
    * **Failure-counter state** — `Vagus.Addon.Watchdog`'s in-flight-task map
      and global restart throttle window are unrelated to this module's own
      per-slug consecutive-failure counter (real Supervisor: `Tasks._cache`
      dict vs. the per-app Job's throttle bucket). A slug can be mid-backoff
      in one watchdog and freshly-reset in the other; neither ever reads the
      other's counters.
    * **Restart/backoff model** — `Vagus.Addon.Watchdog` runs up to 5
      exponential-backoff attempts per triggering event (§B6.4); this module
      is **two-strikes-then-restart, no backoff, no attempt cap** (§B7.4):
      every 120s tick either resets the counter to 0 (healthy, or a restart
      just fired) or increments it by 1 (unhealthy) — there is no "give up
      after N tries" ladder here, because a fresh probe 120s later gets its
      own fair shot regardless of how the last restart went.

  Both watchdogs can be — and normally are — active simultaneously for the
  same add-on: the container-event watchdog catches a crash/OOM-kill almost
  instantly; this probe is the only thing that notices a container that's
  still `RUNNING` (so the event watchdog has nothing to react to) but has
  hung and stopped actually answering requests.

  ## Eligibility + no-template skip (§B7.3)

  Each tick considers a `Vagus.Addon.State` entry only if its lifecycle
  `state == :started`, its persisted `watchdog == true` (the same §B8
  boolean the container-event watchdog and `GET .../info`'s `"watchdog"`
  field read), **and** `config.watchdog` is a non-`nil` template string. An
  add-on with no `watchdog:` template configured is, per §B7.3, "always
  healthy" — this is realized here as *never probed at all* (no counter ever
  created for it), which has the identical observable effect (never
  restarted by this module) without pretending a probe ran.

  ## Host-IP resolution failure is a skip, not a strike

  `:host_ip_fun` failing to resolve a slug's container IP (the container
  disappeared, the bridge network lookup came back empty, ...) is treated as
  a skip for that tick — logged at `:debug`, no counter change. Real
  Supervisor can always read `self.ip_address` because the App object itself
  owns that field; the closest emulator equivalent to "the container is
  gone" is a job for `Vagus.Addon.Watchdog` (the container-event half), not
  this probe piling a failure onto a counter for a container that may
  already be mid-restart via the other path.

  ## Restart dispatch

  Two consecutive `:unhealthy` probe results for a slug fire exactly one
  `manager.restart(slug, [])`, resetting that slug's counter to 0 either way
  (a `:healthy` result also resets to 0). The restart itself runs in a
  monitored `Task` (never blocking this GenServer's tick loop for other
  slugs) with an internal `rescue`/`catch` so a crashing restart never
  reaches this process's `Task.async/1` link — mirrors
  `Vagus.Addon.Watchdog`'s own restart-task pattern (see that module's
  moduledoc). A slug whose restart task is still in flight is skipped
  entirely on the next tick (not just "no restart" — no probe is even
  attempted, since a restart already in progress makes the previous probe
  moot).

  Counters for a slug that has left `Vagus.Addon.State` entirely (uninstalled
  mid-flight) are pruned every tick so nothing lingers or misfires against a
  slug that no longer exists.

  ## Cadence (§B7.4)

  Every `:interval` ms (default `120_000` = `RUN_WATCHDOG_APP_APPLICATION`).
  The **first** tick fires only after one full interval has elapsed, not at
  boot — a container is very likely still starting up right after Vagus
  itself boots, and probing it immediately would just record spurious
  failures against something that hasn't finished its own startup yet.

  ## Options (all injectable — tests never touch a real engine/state/clock)

    * `:name` — GenServer name, default `#{inspect(__MODULE__)}`.
    * `:state` — the `Vagus.Addon.State` server, default
      `Vagus.Addon.State`.
    * `:manager` — a module implementing `restart/2`, default
      `Vagus.Addon.Manager`.
    * `:interval` — tick period in ms, default `120_000`.
    * `:probe_fun` — arity-1 `spec -> :healthy | :unhealthy`, where `spec` is
      `Vagus.Addon.ProbeURL.watchdog_spec/4`'s return shape. Default: `tcp`
      does a raw `:gen_tcp.connect/4` (closing the socket on success, §B7.3);
      `http`/`https` does a one-shot hand-rolled `Mint.HTTP` GET with a 10s
      total budget and, for `https`, `transport_opts: [verify: :verify_none]`
      (§B7.3's `ssl=False` — deliberately accepts self-signed certs, since
      add-ons commonly self-sign). Healthy iff the response status is `< 300`
      — **3xx redirects count as unhealthy** (§B7.3 fact, easy to miss since
      3xx usually means "fine" everywhere else). Any timeout/connect
      error/exception is `:unhealthy`.
    * `:host_ip_fun` — arity-1 `slug -> {:ok, ip} | :error`. Default: for a
      `host_network: true` add-on, `{:ok, "127.0.0.1"}` — this emulator
      process is itself host-networked, so `localhost` reaches a
      host-networked add-on's published ports the same way real
      Supervisor's `self.ip_address` resolves to the host/gateway for such
      add-ons. For a bridge-mode add-on, inspects `"addon_" <> slug` via
      `Vagus.Runtime.Docker.inspect_container/1` and reads its
      `NetworkSettings.Networks[Vagus.Network.name()].IPAddress` — the same
      lookup `Vagus.Addon.Manager.register_dns/3` already does for DNS
      registration.
    * `:attempt_timeout_ms` — bounds the single `manager.restart/2` call a
      restart dispatch makes (review W1), default `120_000` — same default
      and rationale as `Vagus.Addon.Watchdog`'s identical option.
    * `:sequence_deadline_ms` — GenServer-side failsafe: force-clears a
      wedged restart task's `st.tasks` entry after this many ms regardless
      of what's hanging inside it (review W1), default `1_800_000` (30
      min) — mirrors `Vagus.Addon.Watchdog`'s identical failsafe.

  Gated in `Vagus.Application` by the same `config :vagus, :watchdog_enabled`
  flag as `Vagus.Addon.Watchdog` — both watchdog halves turn on/off together.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.{ProbeURL, State}
  alias Vagus.Network
  alias Vagus.Runtime.Docker

  @default_interval 120_000
  @strike_threshold 2
  @tcp_connect_timeout_ms 10_000
  @probe_timeout_ms 10_000
  # review W1: mirrors Vagus.Addon.Watchdog's identical pair of defaults —
  # see moduledoc Options for the rationale.
  @default_attempt_timeout_ms 120_000
  @default_sequence_deadline_ms 30 * 60 * 1_000

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    state_server = Keyword.get(opts, :state, State)
    interval = Keyword.get(opts, :interval, @default_interval)

    st = %{
      state_server: state_server,
      manager: Keyword.get(opts, :manager, Vagus.Addon.Manager),
      interval: interval,
      probe_fun: Keyword.get(opts, :probe_fun, &default_probe_fun/1),
      host_ip_fun:
        Keyword.get(opts, :host_ip_fun, fn slug -> default_host_ip_fun(slug, state_server) end),
      attempt_timeout_ms: Keyword.get(opts, :attempt_timeout_ms, @default_attempt_timeout_ms),
      sequence_deadline_ms:
        Keyword.get(opts, :sequence_deadline_ms, @default_sequence_deadline_ms),
      # slug -> consecutive-unhealthy-tick count. Entirely separate in-memory
      # state from Vagus.Addon.Watchdog's own counters (§B6.5).
      failures: %{},
      # slug -> %Task{}, one in-flight restart task per slug (the whole
      # struct, not just its ref, so the review-W1 sequence-deadline
      # failsafe below can `Task.shutdown/2` it directly).
      tasks: %{}
    }

    # First probe only after one full interval — don't probe at boot while
    # containers are still starting.
    Process.send_after(self(), :tick, interval)
    {:ok, st}
  end

  @impl GenServer
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, st.interval)
    {:noreply, run_tick(st)}
  end

  # A completed Task.async/1 reply — see Vagus.Addon.Watchdog's identical
  # pair of clauses for why both this and the :DOWN clause below exist.
  def handle_info({ref, _result}, %{tasks: tasks} = st) when is_reference(ref) do
    case slug_for_ref(tasks, ref) do
      nil ->
        {:noreply, st}

      slug ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{st | tasks: Map.delete(tasks, slug)}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = st) do
    case slug_for_ref(tasks, ref) do
      nil ->
        {:noreply, st}

      slug ->
        if reason != :normal do
          Logger.warning(
            "Vagus.Addon.Watchdog.Probe: restart task for #{slug} went down unexpectedly " <>
              "(#{inspect(reason)})"
          )
        end

        {:noreply, %{st | tasks: Map.delete(tasks, slug)}}
    end
  end

  # review W1 failsafe — mirrors Vagus.Addon.Watchdog's identical clause:
  # force-clears a wedged restart task's tracking entry so a slug can never
  # be stuck skipped (`maybe_probe/2`'s in-flight check) forever. Ignored if
  # this exact ref is no longer the one tracked for `slug` (the task already
  # finished normally before the deadline fired).
  def handle_info({:sequence_deadline, slug, ref}, %{tasks: tasks} = st) do
    case Map.get(tasks, slug) do
      %Task{ref: ^ref} = task ->
        Logger.error(
          "Vagus.Addon.Watchdog.Probe: restart task for #{slug} exceeded its " <>
            "#{st.sequence_deadline_ms}ms deadline; force-killing (watchdog wedge recovered)"
        )

        Task.shutdown(task, :brutal_kill)
        {:noreply, %{st | tasks: Map.delete(tasks, slug)}}

      _other ->
        {:noreply, st}
    end
  end

  def handle_info(_other, st), do: {:noreply, st}

  ## Tick

  defp run_tick(st) do
    entries = State.list(st.state_server)
    live_slugs = MapSet.new(entries, & &1.config.slug)

    st = %{st | failures: prune_failures(st.failures, live_slugs)}

    Enum.reduce(entries, st, &maybe_probe/2)
  end

  defp prune_failures(failures, live_slugs) do
    Map.filter(failures, fn {slug, _count} -> MapSet.member?(live_slugs, slug) end)
  end

  # §B7.3: no `watchdog:` template -> unconditionally healthy, realized here
  # as "never probed" rather than a probe that always trivially passes.
  defp maybe_probe(
         %{
           config: %{slug: slug} = config,
           state: :started,
           watchdog: true,
           user_options: user_options
         },
         st
       )
       when is_binary(config.watchdog) do
    if Map.has_key?(st.tasks, slug) do
      # A restart is already in flight for this slug — skip the probe
      # entirely rather than pile another counter change on top of it.
      st
    else
      probe_slug(slug, config, user_options, st)
    end
  end

  defp maybe_probe(_entry, st), do: st

  defp probe_slug(slug, config, user_options, st) do
    case st.host_ip_fun.(slug) do
      {:ok, ip} ->
        case ProbeURL.watchdog_spec(config.watchdog, config, user_options, ip) do
          {:ok, spec} ->
            apply_result(slug, st.probe_fun.(spec), st)

          :error ->
            Logger.debug(
              "Vagus.Addon.Watchdog.Probe: unparseable watchdog template for #{slug}; skipping"
            )

            st
        end

      :error ->
        # A container the watchdog can't inspect is the container-event
        # watchdog's problem, not this probe's — see moduledoc.
        Logger.debug(
          "Vagus.Addon.Watchdog.Probe: could not resolve host IP for #{slug}; skipping tick"
        )

        st
    end
  end

  defp apply_result(slug, :healthy, st) do
    %{st | failures: Map.delete(st.failures, slug)}
  end

  defp apply_result(slug, :unhealthy, st) do
    count = Map.get(st.failures, slug, 0) + 1

    if count >= @strike_threshold do
      Logger.warning(
        "Vagus.Addon.Watchdog.Probe: #{slug} failed #{count} consecutive application " <>
          "probes; restarting"
      )

      %{start_restart_task(slug, st) | failures: Map.delete(st.failures, slug)}
    else
      Logger.warning(
        "Vagus.Addon.Watchdog.Probe: #{slug} failed application probe " <>
          "(#{count}/#{@strike_threshold})"
      )

      %{st | failures: Map.put(st.failures, slug, count)}
    end
  end

  defp start_restart_task(slug, st) do
    manager = st.manager
    attempt_timeout_ms = st.attempt_timeout_ms
    task = Task.async(fn -> run_restart(manager, slug, attempt_timeout_ms) end)

    # review W1 failsafe — see the `{:sequence_deadline, ...}` handle_info
    # clause above.
    Process.send_after(
      self(),
      {:sequence_deadline, slug, task.ref},
      st.sequence_deadline_ms
    )

    %{st | tasks: Map.put(st.tasks, slug, task)}
  end

  defp slug_for_ref(tasks, ref) do
    Enum.find_value(tasks, fn {slug, task} -> if task.ref == ref, do: slug end)
  end

  ## Restart task body (runs inside the Task, never touches GenServer state)

  @doc false
  def run_restart(manager, slug, attempt_timeout_ms) do
    bounded_call(attempt_timeout_ms, fn -> manager.restart(slug, []) end)
  rescue
    e ->
      Logger.error(
        "Vagus.Addon.Watchdog.Probe: restart task for #{slug} crashed " <>
          "(#{Exception.format(:error, e, __STACKTRACE__)})"
      )

      :error
  catch
    kind, reason ->
      Logger.error(
        "Vagus.Addon.Watchdog.Probe: restart task for #{slug} #{kind}ed (#{inspect(reason)})"
      )

      :error
  end

  # review W1: bounds the single `manager.restart/2` call the same way
  # `Vagus.Addon.Watchdog`'s `bounded_manager_call/2` does — see that
  # function's doc for why killing the inner Task cannot orphan a held
  # `:global.trans/3` lock. A timeout folds into the same untyped `:error`
  # shape any other manager failure already returns here (there's no
  # backoff/retry ladder in this module — see moduledoc — so nothing further
  # distinguishes "timed out" from "returned an error" downstream).
  defp bounded_call(timeout_ms, fun) do
    inner = Task.async(fun)

    case Task.yield(inner, timeout_ms) || Task.shutdown(inner, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :attempt_timeout}
    end
  end

  ## Default :host_ip_fun

  # host_network add-ons publish their ports on the host itself; this
  # emulator process is host-networked too, so localhost reaches them the
  # same way real Supervisor's ip_address resolves to the host/gateway for
  # such add-ons (§B7.2's watchdog host_network branch, applied one level
  # up — at IP resolution rather than port lookup — since there's no bridge
  # IP to speak of at all for these).
  defp default_host_ip_fun(slug, state_server) do
    case State.get(slug, state_server) do
      {:ok, %{config: %{host_network: true}}} ->
        {:ok, "127.0.0.1"}

      {:ok, _entry} ->
        bridge_ip(slug)

      :error ->
        :error
    end
  end

  # Mirrors Vagus.Addon.Manager.register_dns/3's container-IP lookup.
  defp bridge_ip(slug) do
    with {:ok, %{"NetworkSettings" => %{"Networks" => networks}}} <-
           Docker.inspect_container("addon_" <> slug),
         %{"IPAddress" => ip} when is_binary(ip) and ip != "" <- Map.get(networks, Network.name()) do
      {:ok, ip}
    else
      _ -> :error
    end
  end

  ## Default :probe_fun

  defp default_probe_fun(%{proto: "tcp", host: host, port: port}) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], @tcp_connect_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :healthy

      {:error, _reason} ->
        :unhealthy
    end
  end

  defp default_probe_fun(%{proto: proto, host: host, port: port, suffix: suffix})
       when proto in ["http", "https"] do
    path = if suffix == "", do: "/", else: suffix

    case one_shot_get(probe_scheme(proto), host, port, path) do
      {:ok, status} when is_integer(status) and status < 300 -> :healthy
      _ -> :unhealthy
    end
  rescue
    _ -> :unhealthy
  catch
    _kind, _reason -> :unhealthy
  end

  defp probe_scheme("http"), do: :http
  defp probe_scheme("https"), do: :https

  defp one_shot_get(scheme, host, port, path) do
    deadline = System.monotonic_time(:millisecond) + @probe_timeout_ms

    with {:ok, connect_timeout} <- remaining(deadline),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme, host, port, connect_opts(scheme, connect_timeout)) do
      try do
        with {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, [], ""),
             {:ok, status} <- await_status(conn, ref, deadline) do
          {:ok, status}
        else
          _ -> :error
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> :error
    end
  end

  # §B7.3 `ssl=False`: certificate verification is deliberately disabled even
  # for `https://` probes — self-signed add-on certs are common and this
  # probe's only job is "is something answering", not certificate trust.
  defp connect_opts(:https, timeout),
    do: [mode: :passive, timeout: timeout, transport_opts: [verify: :verify_none]]

  defp connect_opts(:http, timeout), do: [mode: :passive, timeout: timeout]

  defp await_status(conn, ref, deadline) do
    case remaining(deadline) do
      :error ->
        :error

      {:ok, timeout} ->
        case Mint.HTTP.recv(conn, 0, timeout) do
          {:ok, conn, responses} ->
            case find_status(responses, ref) do
              {:ok, status} -> {:ok, status}
              :none -> await_status(conn, ref, deadline)
            end

          {:error, _conn, _reason, _responses} ->
            :error
        end
    end
  end

  defp find_status(responses, ref) do
    Enum.find_value(responses, :none, fn
      {:status, ^ref, status} -> {:ok, status}
      _other -> nil
    end)
  end

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      ms when ms > 0 -> {:ok, ms}
      _ -> :error
    end
  end
end
