defmodule Vagus.Addon.BootStarter do
  @moduledoc """
  Boot-time reconciliation for `Vagus.Addon.State`'s persisted entries
  (M4-P8-T1): restarts `boot: auto` add-ons that were `:started` before the
  last reboot, and demotes anything else back to an honest `:stopped` — the
  same job real Supervisor does against `sys_apps.data` on every HAOS boot.

  ## Why polling, not an event

  `Vagus.Engine.Manager` starts the balena-engine daemon asynchronously,
  once VintageNet reaches `:internet` — there is no "daemon ready" event to
  subscribe to, and the daemon's control socket
  (`Vagus.Runtime.Docker.socket_path/0`) simply doesn't exist until then.
  So this polls `opts[:ping]` (default `Vagus.Runtime.Docker.ping/0`) on a
  timer, exactly as if watching for the socket to appear, rather than
  wiring a second, parallel signal into `Vagus.Engine.Manager` for a
  one-shot boot task.

  ## Gate + lifecycle

  Gated by `config :vagus, :addon_boot_start`, read at `start_link/1` time
  (not compile time) so this module can sit unconditionally in
  `Vagus.Application`'s children list on both `:host` and target — `:host`
  and `mix test` (`config/test.exs`) simply never enable it, and
  `start_link/1` returns `:ignore` rather than starting a GenServer that
  would have nothing to do.

  Once enabled, `init/1` schedules the first poll via `{:continue, :poll}`
  (never blocking `Vagus.Application`'s boot on the engine); every
  `opts[:interval]` (default #{5_000}ms) it retries, up to
  `opts[:max_attempts]` (default 60) before giving up and logging. Once the
  ping succeeds it first ensures the `hassio` bridge and binds the host-served
  `.2`/`.3` anchors (`opts[:ensure_network]`, default `Vagus.Network.ensure/0`
  + `ensure_supervisor_ip/0`) — those anchors are ephemeral (lost on reboot)
  and were previously only re-bound as a side effect of a **container** add-on's
  network setup, so a native-only device (e.g. the native MQTT broker with
  Mosquitto uninstalled) had nothing standing the bridge up and Core could not
  reach the Supervisor at `172.30.32.2:80`. Binding here, engine-gated and
  independent of any add-on, closes that gap. The same step then asserts
  `Vagus.Network.Nat`'s DNAT — since the listener vacated port 80 for Core,
  `172.30.32.2:80` is a destination rewrite rather than a socket, and it has
  to be (re-)installed on every boot for the same reason the anchors do.
  Both are best-effort: a failure is logged and reconciliation still proceeds.

  ## Why reconciliation also waits for the API

  The HA base image runs bashio against `/addons/self/info` during s6 init,
  before the add-on's own service: a refused connection is fatal there, s6
  tears the service down and the container exits 1, and nothing retries it.
  An add-on started while `Vagus.API.Listener` is not yet accepting is
  therefore not merely early, it is down for the rest of the boot.

  Supervision order cannot fix that, and reordering to "listener first"
  would invert a real dependency: the listener binds `172.30.32.2`
  (`config :vagus, :api_bind_ip`), an address that exists only *because* of
  the `ensure_network` step above, and it re-attempts that bind on its own
  timer — so it can only start accepting some time after this module has
  bound the anchors, never before. Hence the second gate,
  `opts[:api_ready]` (default `Vagus.API.Listener.accepting?/0`), polled on
  the same timer: anchors as soon as the engine is up, because that is what
  lets the listener bind at all; add-ons only once the API answers.

  The two waits each get a full `opts[:max_attempts]` budget (the counter
  resets at the hand-off) so a slow engine cannot spend the API's retries,
  and each logs its own warning on giving up — a board that boots with no
  add-ons running has to be able to say which gate it died on.

  It then walks `Vagus.Addon.State.list/0` (server ref
  `opts[:state]`, default `Vagus.Addon.State`) exactly once:

    * `state: :started`, effective boot `"auto"` → `Vagus.Addon.Manager.start_slug/2`,
      serially. A `{:error, reason}` demotes the entry to `:stopped` (via
      the same `opts[:state]` ref) rather than leaving a stale `:started`
      record for an add-on that isn't actually running.
    * `state: :started`, effective boot `"manual"` → demoted to `:stopped`
      without starting — real Supervisor does not auto-start manual-boot
      add-ons either.
    * `state: :stopped` → left alone.

  "Effective boot" (`Vagus.Addon.Config.effective_boot/2`) is the entry's
  persisted `:boot` override (`nil | "auto" | "manual"`, phase 6 chunk A) if
  one was ever saved via `POST /addons/{slug}/options`, else `config.boot`
  itself — with a config declaring `"manual_only"` always winning as
  `"manual"` regardless of any override. Before this addition, reconciliation
  read `config.boot` directly, so a user who'd explicitly set `boot: manual`
  on an `auto`-configured add-on (or vice versa) had that choice silently
  ignored on every reboot.

  After that single pass the GenServer is idle; it does no further polling
  or reconciliation for the rest of this boot.

  `opts[:state]` only redirects *this module's* `list/0`/`put/3` calls.
  `Vagus.Addon.Manager.start_slug/2` itself always resolves the add-on's
  config via the real, globally-named `Vagus.Addon.State` (it has no
  server-ref option) — so a test that wants `start_slug/2` to actually see
  the seeded entries must seed the real global `Vagus.Addon.State` (as
  `test/vagus/addon/manager_test.exs`'s lifecycle tests already do), not a
  private instance passed via `opts[:state]`.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.{Config, Manager, State}
  alias Vagus.Network
  alias Vagus.Network.Nat

  @default_interval 5_000
  @default_max_attempts 60

  @doc """
  Starts the reconciliation GenServer — `:ignore` (no process) unless
  `config :vagus, :addon_boot_start` is truthy.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :addon_boot_start, false) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      ping: Keyword.get(opts, :ping, &default_ping/0),
      api_ready: Keyword.get(opts, :api_ready, &default_api_ready/0),
      ensure_network: Keyword.get(opts, :ensure_network, &default_ensure_network/0),
      interval: Keyword.get(opts, :interval, @default_interval),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      state_server: Keyword.get(opts, :state, State),
      phase: :engine,
      attempt: 0
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl GenServer
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  defp poll(%{phase: :engine, ping: ping, attempt: attempt, max_attempts: max_attempts} = state) do
    case ping.() do
      :ok ->
        state.ensure_network.()
        # The address the listener binds exists as of the line above, so hurry
        # its next attempt rather than lose up to its own retry interval of
        # boot. Optimisation only: if the nudge is lost or nothing is
        # listening for it, the :api gate below still decides when add-ons may
        # start, and it must stay the thing that does.
        Vagus.API.Listener.retry_now()
        # Straight into the API wait on a fresh budget — the anchors this
        # just bound are the listener's precondition, so its bind is still
        # pending at best.
        poll(%{state | phase: :api, attempt: 0})

      {:error, reason} when attempt + 1 >= max_attempts ->
        Logger.warning(
          "Vagus.Addon.BootStarter: engine not ready after #{max_attempts} attempts " <>
            "(last error #{inspect(reason)}), giving up"
        )

        state

      {:error, _reason} ->
        Process.send_after(self(), :poll, state.interval)
        %{state | attempt: attempt + 1}
    end
  end

  defp poll(
         %{phase: :api, api_ready: ready?, attempt: attempt, max_attempts: max_attempts} = state
       ) do
    cond do
      ready?.() ->
        reconcile(state)
        state

      attempt + 1 >= max_attempts ->
        Logger.warning(
          "Vagus.Addon.BootStarter: Supervisor API not accepting connections after " <>
            "#{max_attempts} attempts, giving up — no add-ons started (one that started " <>
            "now would exit 1 in s6 init, on a refused /addons/self/info)"
        )

        state

      true ->
        Process.send_after(self(), :poll, state.interval)
        %{state | attempt: attempt + 1}
    end
  end

  defp reconcile(%{state_server: server}) do
    server
    |> State.list()
    |> Enum.each(&reconcile_entry(&1, server))
  end

  defp reconcile_entry(%{state: :started, config: config} = entry, server) do
    if Config.effective_boot(config, entry[:boot]) == "auto" do
      case Manager.start_slug(config.slug) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Vagus.Addon.BootStarter: start_slug(#{config.slug}) failed " <>
              "(#{inspect(reason)}), demoting to :stopped"
          )

          State.put(config, :stopped, server: server)
      end
    else
      # Effective boot is "manual" (persisted override, or config default/
      # manual_only) — demoted without starting, same as real Supervisor.
      State.put(config, :stopped, server: server)
    end
  end

  defp reconcile_entry(%{state: :stopped}, _server), do: :ok

  defp default_ping, do: Vagus.Runtime.Docker.ping()

  defp default_api_ready, do: Vagus.API.Listener.accepting?()

  # Stand up the hassio bridge, bind the host-served .2/.3 anchors, and
  # assert the DNAT that serves port 80 on .2 — so a native-only device (no
  # container add-on to do it as a side effect) still lets Core and add-ons
  # reach the Supervisor at 172.30.32.2:80, which is now a rewrite onto the
  # listener's real port rather than a listener (`Vagus.Network.Nat`).
  # Best-effort — a failure is logged and boot reconciliation continues.
  defp default_ensure_network do
    case Network.ensure() do
      {:ok, _id} ->
        Network.ensure_supervisor_ip()
        ensure_nat()

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.BootStarter: hassio bridge ensure failed (#{inspect(reason)}); " <>
            "supervisor/dns anchors not bound — Core/bridged add-ons may not reach the Supervisor"
        )

        :ok
    end
  end

  defp ensure_nat do
    case Nat.ensure() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.BootStarter: supervisor DNAT ensure failed (#{inspect(reason)}); " <>
            "add-ons may not reach http://supervisor/"
        )

        :ok
    end
  end
end
