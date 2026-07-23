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
      and adopted as-is.
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

  defp adopt_once(%{adopt: adopt}) do
    case adopt.() do
      {:adopted, info} ->
        Logger.info("Vagus.Core.Boot: adopted Core container #{short_id(info)}")

      :absent ->
        Logger.warning(
          "Vagus.Core.Boot: Core container absent — NOT auto-creating in v1 — " <>
            "create via POST /core/start or /core/update"
        )

      {:error, reason} ->
        Logger.warning("Vagus.Core.Boot: adopt failed (#{inspect(reason)})")
    end
  end

  defp short_id(%{"Id" => id}) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(_info), do: "unknown"

  defp default_ping, do: Vagus.Runtime.Docker.ping()

  defp default_adopt, do: Vagus.Core.Lifecycle.adopt()
end
