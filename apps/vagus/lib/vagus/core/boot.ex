defmodule Vagus.Core.Boot do
  @moduledoc """
  Boot-time Core adoption (CL-P1-T2) — mirrors `Vagus.Addon.BootStarter`'s
  poll-for-engine convention exactly, for the same reason: there is no
  "daemon ready" event to subscribe to, so this polls `opts[:ping]`
  (default `Vagus.Runtime.Docker.ping/0`) on a timer until the engine
  answers, then does its one-shot work and goes idle.

  ## Gate + lifecycle

  Gated by `config :vagus, :core_boot`, read at `start_link/1` time (not
  compile time) so this can sit unconditionally in `Vagus.Application`'s
  children list on both `:host` and target, same as `BootStarter` — `:host`
  and `mix test` never enable it, and `start_link/1` returns `:ignore`
  rather than starting a GenServer with nothing to do.

  Once enabled, `init/1` schedules the first poll via `{:continue, :poll}`;
  every `opts[:interval]` (default #{5_000}ms) it retries, up to
  `opts[:max_attempts]` (default 60) before giving up and logging a
  warning. Once the ping succeeds it calls `opts[:adopt]` (default
  `fn -> Vagus.Core.Lifecycle.adopt() end`) exactly once:

    * `{:adopted, info}` → info log, including the container id (short
      form) — the hand-made/previously-running Core container was found
      and adopted. `opts[:start]` (default
      `fn -> Vagus.Core.Lifecycle.start() end`) is then called
      **unconditionally**, running or not — a warning is logged if it
      returns anything other than `:ok` (no retry loop in v1). A stopped
      container is what issue #46 is about: since #44's graceful-shutdown
      facade (`Vagus.Host.Shutdown`) `docker stop`s Core before reboot,
      the engine marks it manually-stopped, and its `unless-stopped`
      restart policy deliberately never revives a manually-stopped
      container — without this, every graceful reboot would leave Core
      `exited` forever.

      **Deviation from upstream `attach()` parity, deliberate**: upstream
      never reconciles a container it found already running, and until
      this change neither did this module. But `Vagus.Core.Lifecycle`'s
      spec fingerprint (Phase A1 of the core-socket-port80 plan) is what
      makes an env/mount change — the Supervisor socket mount, say —
      actually reach a device, and the engine's own restart policy revives
      the OLD-spec container before this module ever runs. Gating the
      reconcile on "stopped" therefore meant a fleet on OTA would never
      heal spec drift at all. `Lifecycle.start/1` on a running,
      fingerprint-matching container is one `inspect` and `:ok`, so the
      unconditional call costs a single Engine-API round trip per boot.
    * `:absent` → **warning** log. This module NEVER creates the Core
      container itself — v1 deliberately leaves that to an explicit
      `POST /core/start` or `POST /core/update` call (Phase 3), so an
      absent Core on boot is a loud "nothing is running" signal, not a
      silent auto-create.
    * `{:error, reason}` → warning log.

  After that single adopt attempt, the GenServer is idle for the rest of
  this boot — no retry loop, no periodic re-adoption.
  """

  use GenServer

  require Logger

  @default_interval 5_000
  @default_max_attempts 60

  @doc """
  Starts the boot-adoption GenServer — `:ignore` (no process) unless
  `config :vagus, :core_boot` is truthy.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :core_boot, false) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      ping: Keyword.get(opts, :ping, &default_ping/0),
      adopt: Keyword.get(opts, :adopt, &default_adopt/0),
      start: Keyword.get(opts, :start, &default_start/0),
      interval: Keyword.get(opts, :interval, @default_interval),
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
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
        adopt_once(state)
        state

      {:error, reason} when attempt + 1 >= max_attempts ->
        Logger.warning(
          "Vagus.Core.Boot: engine not ready after #{max_attempts} attempts " <>
            "(last error #{inspect(reason)}), giving up"
        )

        state

      {:error, _reason} ->
        Process.send_after(self(), :poll, state.interval)
        %{state | attempt: attempt + 1}
    end
  end

  defp adopt_once(%{adopt: adopt, start: start}) do
    case adopt.() do
      {:adopted, info} ->
        Logger.info("Vagus.Core.Boot: adopted Core container #{short_id(info)}")
        start_adopted(info, start)

      :absent ->
        Logger.warning(
          "Vagus.Core.Boot: Core container absent — NOT auto-creating in v1 — " <>
            "create via POST /core/start or /core/update"
        )

      {:error, reason} ->
        Logger.warning("Vagus.Core.Boot: adopt failed (#{inspect(reason)})")
    end
  end

  # Runs for a running container too — see the moduledoc's "Deviation from
  # upstream `attach()` parity" note.
  defp start_adopted(info, start) do
    Logger.info(start_message(info))

    case start.() do
      :ok ->
        :ok

      other ->
        Logger.warning("Vagus.Core.Boot: start failed for #{short_id(info)} (#{inspect(other)})")
    end
  end

  defp start_message(info) do
    if adopted_running?(info) do
      "Vagus.Core.Boot: reconciling running Core container #{short_id(info)} against " <>
        "the current container spec"
    else
      "Vagus.Core.Boot: adopted stopped Core container #{short_id(info)} — starting " <>
        "(left stopped by the pre-reboot graceful shutdown, issue #46)"
    end
  end

  defp adopted_running?(%{"State" => %{"Running" => true}}), do: true
  defp adopted_running?(_info), do: false

  defp short_id(%{"Id" => id}) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(_info), do: "unknown"

  defp default_ping, do: Vagus.Runtime.Docker.ping()

  defp default_adopt, do: Vagus.Core.Lifecycle.adopt()

  defp default_start, do: Vagus.Core.Lifecycle.start()
end
