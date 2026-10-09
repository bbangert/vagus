defmodule Vagus.App.CoreUnit do
  @moduledoc """
  Home Assistant Core as one step of the boot and shutdown sequence.

  Boot never creates Core: an absent container is left to an explicit
  `POST /core/start` or `/core/update`, or to `Vagus.Provisioner` on a first
  boot. An adopted one is started whether or not it already runs: a running
  container whose spec fingerprint matches costs one inspect, and one that
  the engine revived from an older spec is how a spec change reaches a
  device at all. A stopped one is the normal case after a graceful reboot,
  which leaves it manually stopped, so `unless-stopped` never revives it.
  """

  require Logger

  alias Vagus.Core.{Health, Lifecycle}

  @busy_retry_budget_ms 60_000
  @busy_backoff_ms 1_000
  @busy_backoff_cap_ms 8_000

  @doc """
  `:ok` also when Core is absent, so a device without Core boots its apps.
  `opts[:deadline]` bounds the wait for Core to answer once started.
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []) do
    case Keyword.get(opts, :adopt, &Lifecycle.adopt/0).() do
      {:adopted, info} ->
        Logger.info("Boot: starting Core container #{short_id(info)} against the current spec")

        with :ok <- Keyword.get(opts, :start, &Lifecycle.start/0).() do
          await_healthy(opts)
        end

      :absent ->
        Logger.warning("Boot: no Core container; create it with POST /core/start or /core/update")
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp await_healthy(opts) do
    health = Keyword.get(opts, :health, &Health.await_healthy/1)

    case health.(deadline: Keyword.get(opts, :deadline, 120_000)) do
      :healthy -> :ok
      :timeout -> {:error, :health_timeout}
    end
  end

  @doc """
  Retries while an update or rebuild holds Core's lifecycle lock, backing
  off from 1 s and doubling to 8 s, for up to 60 s or `opts[:deadline]` ms,
  whichever is sooner: long enough to ride out one, short enough not to hold
  back the reboot the caller asked for.
  """
  @spec stop(keyword()) :: :ok | {:error, term()}
  def stop(opts \\ []) do
    stop = Keyword.get(opts, :stop, &Lifecycle.stop/0)

    budget_ms =
      min(
        Keyword.get(opts, :busy_retry_budget_ms, @busy_retry_budget_ms),
        Keyword.get(opts, :deadline, :infinity)
      )

    clock = %{
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1)
    }

    deadline = clock.now.() + budget_ms
    backoff_ms = Keyword.get(opts, :busy_backoff_ms, @busy_backoff_ms)
    stop_with_retry(stop, deadline, backoff_ms, clock)
  end

  # The sleep is capped to the time left and the deadline re-checked after it,
  # so no attempt starts past the deadline the caller was promised.
  defp stop_with_retry(stop, deadline, backoff_ms, clock) do
    case safe(stop) do
      {:error, :busy} = busy ->
        remaining = deadline - clock.now.()

        if remaining > 0 do
          clock.sleep.(min(backoff_ms, remaining))

          if clock.now.() < deadline do
            stop_with_retry(stop, deadline, min(backoff_ms * 2, @busy_backoff_cap_ms), clock)
          else
            give_up(busy)
          end
        else
          give_up(busy)
        end

      result ->
        result
    end
  end

  defp give_up(busy) do
    Logger.warning("Shutdown: Core stayed busy past the retry budget; proceeding")
    busy
  end

  # A Core stop that raises must not keep the stages after it from running.
  defp safe(stop) do
    stop.()
  rescue
    exception -> {:error, {:raised, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp short_id(%{"Id" => id}) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(_info), do: "unknown"
end
