defmodule Vagus.App.CoreUnit do
  @moduledoc """
  Home Assistant Core as one step of the boot and shutdown sequence.

  An absent container is created when a version is installed: under an
  engine with a transient store (podman) nothing survives a reboot, so this
  is every boot, and under Docker it repairs a recreate a shutdown cut
  short. With no version installed it is left to an explicit
  `POST /core/start` or `/core/update`, or to `Vagus.Provisioner` on a first
  boot. A create that fails is handed to the Provisioner's start retries,
  and an installed version whose image the engine lacks is the
  Provisioner's too: the pull needs the internet, which boot does not wait
  for, and the Provisioner waits and retries, then starts Core itself.

  An adopted container is started whether or not it already runs: a running
  container whose spec fingerprint matches costs only the adopt's and the
  start's inspects, and one that
  the engine revived from an older spec is how a spec change reaches a
  device at all. A stopped one is the normal case after a graceful reboot,
  which leaves it manually stopped, so `unless-stopped` never revives it.
  """

  require Logger

  alias Vagus.Core.{Health, Lifecycle, Versions}

  @busy_retry_budget_ms 60_000
  @busy_backoff_ms 1_000
  @busy_backoff_cap_ms 8_000

  @doc """
  `:ok` also when Core is absent and not created here, so a device without
  Core boots its apps. `opts[:deadline]` bounds the wait for Core to answer
  once started.
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
        start_absent(Keyword.get(opts, :installed, &Versions.installed/0).(), opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_absent(nil, _opts) do
    Logger.warning("Boot: no Core container; create it with POST /core/start or /core/update")
    :ok
  end

  # A presence check that errors leaves the start to report what is wrong.
  # The stops are read first: a stop that lands while the check waits on the
  # engine must still refuse the create.
  defp start_absent(version, opts) do
    stops_seen = Keyword.get(opts, :stops, &Lifecycle.stops/0).()

    case Keyword.get(opts, :image_present?, &Lifecycle.image_present?/1).(version) do
      false ->
        Logger.warning("Boot: Core #{version}'s image is absent; Vagus.Provisioner pulls it")
        :ok

      _present_or_unknown ->
        Logger.info("Boot: creating the Core #{version} container")

        case start_unattended(opts, stops_seen) do
          :ok ->
            await_healthy(opts)

          # Refused for a stop or a shutdown: nothing to retry.
          {:error, refusal} = error when refusal in [:stopped, :shutting_down] ->
            error

          {:error, reason} = error ->
            hand_off(reason, stops_seen, opts)
            error
        end
    end
  end

  # The create is boot's own, not the user's: a stop or a shutdown that lands
  # after the reading wins under the lifecycle lock.
  defp start_unattended(opts, stops_seen) do
    case Keyword.get(opts, :start, &Lifecycle.start(stops_seen: &1)) do
      start when is_function(start, 1) -> start.(stops_seen)
      start -> start.()
    end
  end

  # Nothing else brings an absent Core back once boot moves on: the
  # Provisioner retries the start on its backoff, until a stop since this
  # attempt says otherwise.
  defp hand_off(reason, stops_seen, opts) do
    Logger.warning("Boot: Core create failed (#{inspect(reason)}); Vagus.Provisioner retries it")

    Keyword.get(opts, :retry, &Vagus.Provisioner.retry_core_start/1).(stops_seen)
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

  defp short_id(%{id: id}) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(_info), do: "unknown"
end
