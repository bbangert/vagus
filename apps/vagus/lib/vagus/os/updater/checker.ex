defmodule Vagus.OS.Updater.Checker do
  @moduledoc """
  The check cadence `nerves_github_updater` deliberately doesn't ship: a
  DAILY feed check, plus one first check ~5 minutes after boot — never at
  t=0, so a fleet power-cycling together doesn't stampede the GitHub API
  (and boot-critical work isn't competing with a TLS handshake). Both
  delays carry random jitter for the same reason.

  After each check settles, a NEW `last_release.tag_name` (different from
  the previously observed one, including the nil→first-tag transition)
  pushes `Vagus.Core.Events.supervisor_update("os", %{})` through
  `Vagus.Core.EventPusher` — Core refetches `/os/info` on that event, so
  the OS update entity flips to "update available" within the same UI
  cycle instead of at Core's next scheduled poll. An unchanged tag pushes
  nothing (no daily nagging).

  Checks are matched to the user's release reality: infrequent,
  deliberate, tag-driven. The user-facing "Check for updates" button
  bypasses this timer entirely via `Vagus.OS.Updater.check_now/1`.

  Runs only under `Vagus.OS.Updater`'s supervisor (so it inherits the
  `config :vagus, :os_updater` gate); tests start it standalone with the
  seams injected (`:updater`, `:notify`, the interval/jitter opts).
  """

  use GenServer

  require Logger

  @first_check_ms 5 * 60 * 1000
  @first_check_jitter_ms 5 * 60 * 1000
  @interval_ms 24 * 60 * 60 * 1000
  @interval_jitter_ms 60 * 60 * 1000

  # The post-check settle poll (the check is a cast; its result lands in
  # state/1 asynchronously). Generous — a slow check only delays the
  # event push, nothing else queues behind this process.
  @settle_timeout_ms 60_000
  @settle_poll_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      updater:
        Keyword.get(
          opts,
          :updater,
          Application.get_env(:vagus, :os_updater_mod, NervesGithubUpdater.Updater)
        ),
      notify: Keyword.get(opts, :notify, &default_notify/0),
      first_check_ms: Keyword.get(opts, :first_check_ms, @first_check_ms),
      first_check_jitter_ms: Keyword.get(opts, :first_check_jitter_ms, @first_check_jitter_ms),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      interval_jitter_ms: Keyword.get(opts, :interval_jitter_ms, @interval_jitter_ms),
      settle_timeout_ms: Keyword.get(opts, :settle_timeout_ms, @settle_timeout_ms),
      settle_poll_ms: Keyword.get(opts, :settle_poll_ms, @settle_poll_ms),
      last_tag: nil
    }

    schedule_check(state.first_check_ms, state.first_check_jitter_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    new_state = run_check(state)
    schedule_check(new_state.interval_ms, new_state.interval_jitter_ms)
    {:noreply, new_state}
  end

  defp schedule_check(base_ms, jitter_ms) do
    Process.send_after(self(), :check, base_ms + jitter(jitter_ms))
  end

  defp jitter(0), do: 0
  defp jitter(max_ms), do: :rand.uniform(max_ms)

  # Blocking is fine here: this process owns nothing else, and every
  # state() poll is itself bounded by the library's caught 5s call
  # timeout (which surfaces as the synthetic :installing busy phase).
  defp run_check(state) do
    :ok = state.updater.check()

    case settle(state, System.monotonic_time(:millisecond) + state.settle_timeout_ms) do
      {:ok, tag} when is_binary(tag) and tag != state.last_tag ->
        Logger.info("Vagus.OS.Updater.Checker: new firmware release advertised: #{tag}")
        state.notify.()
        %{state | last_tag: tag}

      {:ok, _unchanged_or_nil} ->
        state

      {:error, reason} ->
        Logger.warning("Vagus.OS.Updater.Checker: check did not settle: #{inspect(reason)}")
        state
    end
  end

  defp settle(state, deadline) do
    snapshot = state.updater.state()

    cond do
      snapshot.phase in [:checking, :installing] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(state.settle_poll_ms)
          settle(state, deadline)
        end

      snapshot.phase == :error ->
        {:error, snapshot.last_error}

      true ->
        {:ok, snapshot.last_release && snapshot.last_release.tag_name}
    end
  end

  defp default_notify do
    "os"
    |> Vagus.Core.Events.supervisor_update(%{})
    |> Vagus.Core.EventPusher.push()
  end
end
