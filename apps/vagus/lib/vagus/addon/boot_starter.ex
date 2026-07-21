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
  ping succeeds, it walks `Vagus.Addon.State.list/0` (server ref
  `opts[:state]`, default `Vagus.Addon.State`) exactly once:

    * `state: :started, config.boot == "auto"` → `Vagus.Addon.Manager.start_slug/2`,
      serially. A `{:error, reason}` demotes the entry to `:stopped` (via
      the same `opts[:state]` ref) rather than leaving a stale `:started`
      record for an add-on that isn't actually running.
    * `state: :started` with any other `boot` (`"manual"`/`"manual_only"`)
      → demoted to `:stopped` without starting — real Supervisor does not
      auto-start manual-boot add-ons either.
    * `state: :stopped` → left alone.

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

  alias Vagus.Addon.{Manager, State}

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
      interval: Keyword.get(opts, :interval, @default_interval),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      state_server: Keyword.get(opts, :state, State),
      attempt: 0
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl GenServer
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  defp poll(%{ping: ping, attempt: attempt, max_attempts: max_attempts} = state) do
    case ping.() do
      :ok ->
        reconcile(state)
        state

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

  defp reconcile(%{state_server: server}) do
    server
    |> State.list()
    |> Enum.each(&reconcile_entry(&1, server))
  end

  defp reconcile_entry(%{state: :started, config: %{boot: "auto"} = config}, server) do
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
  end

  # boot: manual/manual_only entries persisted as :started are demoted
  # without starting — real Supervisor doesn't auto-start those either.
  defp reconcile_entry(%{state: :started, config: config}, server) do
    State.put(config, :stopped, server: server)
  end

  defp reconcile_entry(%{state: :stopped}, _server), do: :ok

  defp default_ping, do: Vagus.Runtime.Docker.ping()
end
