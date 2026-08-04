defmodule Vagus.Host.Shutdown do
  @moduledoc """
  The single facade every reboot/poweroff initiator in this codebase must
  call instead of `Nerves.Runtime.reboot/0`/`poweroff/0` directly (issue
  #39).

  ## The corruption problem

  HA Core and every add-on container keep their state in `.storage/*` JSON
  files that get written with a temp-file-then-rename dance, but that
  dance only protects against a crash *between* writes — it does nothing
  if the process is SIGKILLed mid-write. `erlinit`'s shutdown path sends
  every still-running container a hard kill (it doesn't know how to ask
  balena-engine to gracefully `docker stop` its containers, and doesn't
  wait around for it if it did) once the BEAM has exited, so a reboot or
  poweroff that races Core or an add-on mid-write to `.storage` truncates
  the file to zero bytes or leaves a lost rename — the exact bug this
  module exists to close. The fix is to stop every container (real
  `docker stop`, SIGTERM-then-grace-then-SIGKILL, *before* anything is
  mid-write) while the BEAM is still fully alive to run it.

  ## Why a call-site facade, not `prep_stop`/`terminate` hooks

  The obvious-looking alternative — hang this off `Vagus.Application`'s
  `prep_stop/1` or a `terminate/2` callback somewhere — doesn't work here,
  because by the time OTP's own shutdown machinery is running, several of
  the things this module depends on are no longer true:

    * `Nerves.Runtime.reboot/0` arms `nerves_heart`'s hardware watchdog
      reboot *before* it calls `:init.stop/0` — the countdown to a
      watchdog-forced power cycle starts immediately, independent of
      whatever OTP shutdown does afterward.
    * `erlinit`'s own graceful-shutdown budget for the whole BEAM teardown
      defaults to ~10 seconds — nowhere near enough for Core's worst-case
      stop (up to ~260s, budget rationale below).
    * Application supervision trees stop children in *reverse start
      order*. `Vagus.Engine.Manager` (the balena-engine daemon) is started
      early and would therefore stop late in a `prep_stop`-driven
      teardown — except a `terminate/2` hook trying to `docker stop`
      *other* containers needs the engine's API socket to still be up,
      and nothing guarantees it survives long enough into that teardown
      to be usable, or that heart is still being petted while `init.stop`
      unwinds the tree.

  Calling `reboot/1`/`poweroff/1` here instead — from the API route
  handler, the watchdog, the OTA success callback, wherever a shutdown is
  actually decided — runs all of this while the BEAM is fully alive, heart
  is still being petted on the normal schedule, and the engine daemon is
  definitely up. None of the above budgets or ordering constraints apply
  until *after* this module hands off to `Nerves.Runtime`.

  ## Availability over cleanliness

  The reboot or poweroff the caller asked for **always happens** — a
  wedged docker socket, a busy Core lock, a crashed stop task, or a
  blown budget degrade the *cleanliness* of the shutdown (containers may
  still get SIGKILLed) but never block it. Every stage below is bounded
  and rescue-wrapped for exactly this reason: a graceful shutdown that
  occasionally fails to be graceful is an acceptable regression from
  today; a reboot that hangs because this module got stuck is not.

  ## Reentrancy

  `reboot/1` and `poweroff/1` both funnel through a single non-blocking
  `:global.trans/4` lock (the same idiom `Vagus.Core.Lifecycle.with_lock/1`
  uses, `retries: 0`) keyed on this node — if a shutdown is already in
  flight (e.g. the watchdog and an API-triggered reboot race each other),
  the second caller's `:global.trans` call returns `:aborted` immediately,
  is logged, and returns `:ok` **without making any runtime call at all**.
  Exactly one `Nerves.Runtime.reboot/0`/`poweroff/0` call happens per
  invocation of this facade, owned by whichever caller acquired the lock
  first. The runtime delegate deliberately runs *inside* the locked
  closure, not after releasing it: the lock must stay held until the
  reboot/poweroff is irrevocably initiated, otherwise a second caller
  could slip in between "first caller finished its stop stages" and
  "first caller called `Nerves.Runtime.reboot/0`" and kick off a second,
  entirely redundant stop sequence for containers the first caller is
  already tearing down.

  ## The known gap

  A raw `Nerves.Runtime.reboot/0`/`poweroff/0` or an `:init.stop()` typed
  directly into an IEx console bypasses this facade completely — there is
  no interception at the `Nerves.Runtime` boundary itself. Closing that
  gap (e.g. wrapping/replacing the underlying calls project-wide) is
  deferred and tracked in the plan; this module is the call-site
  convention, not an unconditional guarantee.

  ## Watchdog stand-down

  `Vagus.Addon.Watchdog` restarts an add-on on ANY `die` event (exit code
  irrelevant — see that module's moduledoc "Triggering events") whenever
  `Vagus.Addon.State` still says `state: :started, watchdog: true`. Its
  only existing suppression is the W6 pattern: `Vagus.Addon.Manager.stop/2`
  records `:stopped` **before** touching the container, so a manual stop's
  `die` event finds `:stopped` and is ignored. This module's add-on stop
  stage deliberately does **not** record `:stopped` (see `stop_addons/1` —
  entries must stay `:started` so `Vagus.Addon.BootStarter`'s reconciliation
  restarts them on the next boot), which means the W6 mechanism cannot
  cover it: every `docker stop` this module issues would otherwise look to
  the watchdog exactly like an unexpected crash, triggering a restart
  sequence *during* the shutdown window — the restarted container then
  gets SIGKILLed by erlinit moments later, recreating exactly the
  `.storage` corruption this whole module exists to prevent.

  `in_flight?/0` closes that gap: `do_run/2` marks a shutdown in flight via
  `:persistent_term` **before** the stop stages begin, and
  `Vagus.Addon.Watchdog` checks it (its own `:shutdown_check` opt) ahead of
  starting any restart sequence. `:persistent_term` — not GenServer state on
  the watchdog, and not a suspend/pause call made against it — is used
  specifically because it survives a watchdog process restart under its
  `one_for_one` supervisor mid-shutdown-window: a crash-and-restart of the
  watchdog process during the stop stages must still see the flag, and a
  value living in the watchdog's own (about-to-be-replaced) process state
  couldn't guarantee that. The flag stays set once the stop stages finish —
  the reboot/poweroff this module was called to perform always follows
  them (see "Availability over cleanliness"), so there is no "shutdown
  aborted, resume normal watchdog behavior" state to return to in that
  case. The one exception is `call_runtime/2` itself failing: if the
  runtime delegate raises/exits/throws, the device is *not* going down, so
  `do_run/2` erases the flag and re-raises — the watchdogs must resume on
  a box that is still running.

  The Core lifecycle watchdog (paired event+probe checks on the HA Core
  container, not add-ons) needs no equivalent: its event half only counts
  **nonzero**-exit `die`s (an intentional `docker stop`, this module's
  own `stop_core/1` included, exits 0 and is never mistaken for a crash),
  and both its event and probe halves skip a container that isn't running
  in the first place — a stopped Core is simply outside what that watchdog
  reacts to. Only the add-on watchdog's any-exit-code `die` handling
  creates the race this section closes.

  ## Budgets

    * `30` s per add-on container `docker stop` timeout — generous enough
      for a well-behaved add-on's own graceful shutdown hook, small enough
      that four of them stopping serially still fits comfortably inside
      the total budget.
    * Core's stop retries on `{:error, :busy}` (its own non-blocking
      `:global.trans` lock, held by an in-flight `update`/`rebuild`) for
      up to `60_000` ms, backing off from `1_000` ms and doubling each
      attempt, capped at `8_000` ms — long enough to ride out a typical
      in-flight lifecycle op without indefinitely delaying the reboot the
      caller actually asked for.
    * `300_000` ms hard overall deadline wrapping the add-on and Core stop
      stages together — sized against `Vagus.Core.Lifecycle` stop's own
      worst-case fallback timeout (260 s, `@fallback_stop_timeout_s`
      there) plus margin for the add-on stage ahead of it, while staying
      safely under `nerves_runtime`'s own ~10-minute post-`:init.stop`
      halt backstop — this facade's stages must finish well before that
      outer backstop would fire.
  """

  require Logger

  @addon_stop_s 30
  @busy_retry_budget_ms 60_000
  @busy_backoff_ms 1_000
  @busy_backoff_cap_ms 8_000
  @total_budget_ms 300_000

  @doc """
  Stops every started add-on container and HA Core (best-effort, bounded),
  then calls `Nerves.Runtime.reboot/0`. Always returns `:ok` — see the
  moduledoc's "Availability over cleanliness" section. A shutdown already
  in flight makes this call a no-op (see "Reentrancy").
  """
  @spec reboot(keyword()) :: :ok
  def reboot(opts \\ []), do: run(:reboot, opts)

  @doc """
  Same contract as `reboot/1`, but calls `Nerves.Runtime.poweroff/0` as the
  terminal step.
  """
  @spec poweroff(keyword()) :: :ok
  def poweroff(opts \\ []), do: run(:poweroff, opts)

  @doc """
  Arity-0 wrapper for the `:ssh_subsystem_fwup` `success_callback` MFA (OTA
  firmware updates) — that callback is invoked as a `{Mod, fun, []}` triple,
  which needs an arity-0 entry point rather than `reboot/1`'s optional arg.
  """
  @spec ota_reboot() :: :ok
  def ota_reboot, do: reboot()

  @doc false
  @spec in_flight?() :: boolean()
  def in_flight?, do: :persistent_term.get({__MODULE__, :in_flight}, false)

  ## Reentrancy guard — see moduledoc "Reentrancy" section.

  defp run(kind, opts) do
    lock_id = {:host_shutdown, node()}

    case :global.trans(
           {lock_id, self()},
           fn -> do_run(kind, opts) end,
           [node()],
           0
         ) do
      :aborted ->
        Logger.warning(
          "Vagus.Host.Shutdown: a shutdown is already in flight — this call is a no-op; " <>
            "the in-flight sequence owns the reboot"
        )

        :ok

      :ok ->
        :ok
    end
  end

  # The runtime call lives inside the locked closure — see moduledoc
  # "Reentrancy" for why it must not run after the lock is released.
  defp do_run(kind, opts) do
    started_at = System.monotonic_time(:millisecond)
    # Set BEFORE the stop stages begin — see moduledoc "Watchdog stand-down".
    # Left set once the stop stages finish: the reboot/poweroff below always
    # follows them, so there is no "back to normal" state — UNLESS
    # call_runtime/2 itself fails below, in which case the device is not
    # going down and the flag must come back off.
    :persistent_term.put({__MODULE__, :in_flight}, true)
    {addon_result, core_result} = bounded_stop_stages(kind, opts)
    {ok_count, total} = addon_result
    elapsed = System.monotonic_time(:millisecond) - started_at

    Logger.warning(
      "Vagus.Host.Shutdown: #{kind} — add-ons stopped #{ok_count}/#{total}, " <>
        "core #{inspect(core_result)}, elapsed #{elapsed}ms"
    )

    try do
      call_runtime(kind, opts)
    rescue
      exception ->
        Logger.error(
          "Vagus.Host.Shutdown: runtime #{kind} call raised, device is NOT going down — " <>
            "clearing in-flight flag (#{Exception.format(:error, exception, __STACKTRACE__)})"
        )

        :persistent_term.erase({__MODULE__, :in_flight})
        reraise exception, __STACKTRACE__
    catch
      kind_caught, reason ->
        Logger.error(
          "Vagus.Host.Shutdown: runtime #{kind} call failed (caught #{kind_caught}: " <>
            "#{inspect(reason)}), device is NOT going down — clearing in-flight flag"
        )

        :persistent_term.erase({__MODULE__, :in_flight})
        :erlang.raise(kind_caught, reason, __STACKTRACE__)
    end

    :ok
  end

  defp call_runtime(:reboot, opts) do
    Keyword.get(opts, :runtime_reboot, &Nerves.Runtime.reboot/0).()
  end

  defp call_runtime(:poweroff, opts) do
    Keyword.get(opts, :runtime_poweroff, &Nerves.Runtime.poweroff/0).()
  end

  ## Bounded stop stages — see moduledoc "Availability over cleanliness".

  # Guards against a wedged engine call hanging the reboot indefinitely
  # (an unbounded task is a wedge — see
  # .claude/solutions/otp-issues/task-dedup-map-wedge). Wrapped in
  # try/rescue/catch too: `Vagus.Jobs.TaskSupervisor` not being available
  # (or any other setup failure before the task even starts) must still
  # fall through to the runtime call, never crash the caller out of the
  # reboot it asked for. `stop_addons/1` is called through `safe_stop_addons/1`
  # (mirroring `stop_core/1`'s own rescue/catch) so a crash in the add-on
  # stage degrades only that stage's result instead of killing the whole
  # task and skipping `stop_core/1` — the most corruption-sensitive stage —
  # entirely.
  defp bounded_stop_stages(kind, opts) do
    total_budget_ms = Keyword.get(opts, :total_budget_ms, @total_budget_ms)

    task =
      Task.Supervisor.async_nolink(Vagus.Jobs.TaskSupervisor, fn ->
        {safe_stop_addons(opts), stop_core(opts)}
      end)

    case Task.yield(task, total_budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("Vagus.Host.Shutdown: stop stages crashed (#{inspect(reason)})")
        degraded_result()

      nil ->
        Logger.error("Vagus.Host.Shutdown: total budget exceeded, proceeding with #{kind} anyway")

        degraded_result()
    end
  rescue
    exception ->
      Logger.error(
        "Vagus.Host.Shutdown: stop stages raised (#{Exception.format(:error, exception, __STACKTRACE__)})"
      )

      degraded_result()
  catch
    kind_caught, reason ->
      Logger.error(
        "Vagus.Host.Shutdown: stop stages failed (caught #{kind_caught}: #{inspect(reason)})"
      )

      degraded_result()
  end

  defp degraded_result, do: {{0, 0}, {:error, :not_run}}

  ## stop_addons/1

  # Rescue/catch wrapper around `stop_addons/1` — see `bounded_stop_stages/2`
  # for why: a crash there must degrade only the add-on result, not take
  # `stop_core/1` down with it inside the shared task.
  defp safe_stop_addons(opts) do
    stop_addons(opts)
  rescue
    exception ->
      Logger.warning(
        "Vagus.Host.Shutdown: add-on stop stage raised, proceeding: " <>
          "#{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      {0, 0}
  catch
    kind_caught, reason ->
      Logger.warning(
        "Vagus.Host.Shutdown: add-on stop stage failed (caught #{kind_caught}: " <>
          "#{inspect(reason)}), proceeding"
      )

      {0, 0}
  end

  # Deliberately NOT `Vagus.Addon.Manager.stop/2` — that REMOVES the
  # container (upstream parity for user-initiated stops); a reboot must
  # not churn add-on containers. `Docker.stop_container/2` stops without
  # removing. Also deliberately no `Vagus.Addon.State` writes: entries
  # stay `:started` so boot-time reconciliation restarts them.
  defp stop_addons(opts) do
    addons_fun = Keyword.get(opts, :addons, &Vagus.Addon.State.list/0)
    stop_addon_fun = Keyword.get(opts, :stop_addon, &default_stop_addon/2)
    addon_stop_s = Keyword.get(opts, :addon_stop_s, @addon_stop_s)

    entries =
      addons_fun.()
      |> Enum.filter(&(&1.state == :started))
      |> Enum.reject(&native_backend?/1)

    total = length(entries)
    addon_task_timeout_ms = Keyword.get(opts, :addon_task_timeout_ms, addon_stop_s * 1000 + 5_000)

    results =
      Task.Supervisor.async_stream_nolink(
        Vagus.Jobs.TaskSupervisor,
        entries,
        fn entry ->
          {entry.config.slug, stop_addon_fun.("addon_" <> entry.config.slug, addon_stop_s)}
        end,
        timeout: addon_task_timeout_ms,
        on_timeout: :kill_task,
        zip_input_on_exit: true,
        max_concurrency: 4,
        ordered: false
      )
      |> Enum.to_list()

    ok_count = Enum.count(results, &addon_stop_ok?/1)
    Enum.each(results, &log_addon_result/1)

    {ok_count, total}
  end

  defp default_stop_addon(name, timeout_s) do
    Vagus.Runtime.Docker.stop_container(name, timeout: timeout_s)
  end

  # Native-backend add-ons (the in-BEAM mqttx broker, `core_mqtt`) have no
  # container to stop — mirrors `Vagus.Addon.Manager.put_backend/2`'s
  # allowlist check exactly: a non-allowlisted `backend: :native` config
  # silently runs in a container (see that module), so the allowlist check
  # must be part of this filter, not just the raw `backend` tag, or a
  # spoofed/legacy config would wrongly get skipped here and leave its
  # very real container running unstopped.
  defp native_backend?(%{config: %{backend: :native, slug: slug}}) do
    Vagus.Addon.Manager.native_allowed?(slug)
  end

  defp native_backend?(_entry), do: false

  defp addon_stop_ok?({:ok, {_slug, :ok}}), do: true
  defp addon_stop_ok?(_other), do: false

  defp log_addon_result({:ok, {_slug, :ok}}), do: :ok

  defp log_addon_result({:ok, {slug, {:error, reason}}}) do
    Logger.warning(
      "Vagus.Host.Shutdown: add-on #{slug} stop failed, proceeding: #{inspect(reason)}"
    )
  end

  defp log_addon_result({:exit, {entry, reason}}) do
    Logger.warning(
      "Vagus.Host.Shutdown: add-on #{entry.config.slug} stop timed out/crashed, proceeding: " <>
        "#{inspect(reason)}"
    )
  end

  ## stop_core/1

  defp stop_core(opts) do
    stop_core_fun = Keyword.get(opts, :stop_core, &Vagus.Core.Lifecycle.stop/0)
    busy_retry_budget_ms = Keyword.get(opts, :busy_retry_budget_ms, @busy_retry_budget_ms)
    busy_backoff_ms = Keyword.get(opts, :busy_backoff_ms, @busy_backoff_ms)
    stage_started_at = System.monotonic_time(:millisecond)

    stop_core_with_retry(
      stop_core_fun,
      stage_started_at,
      busy_retry_budget_ms,
      busy_backoff_ms
    )
  rescue
    exception ->
      Logger.warning(
        "Vagus.Host.Shutdown: core stop raised (#{Exception.format(:error, exception, __STACKTRACE__)})"
      )

      {:error, {:raised, exception}}
  catch
    kind_caught, reason ->
      Logger.warning(
        "Vagus.Host.Shutdown: core stop failed (caught #{kind_caught}: #{inspect(reason)})"
      )

      {:error, {kind_caught, reason}}
  end

  defp stop_core_with_retry(stop_core_fun, stage_started_at, budget_ms, backoff_ms) do
    case stop_core_fun.() do
      :ok ->
        :ok

      {:error, :busy} ->
        elapsed = System.monotonic_time(:millisecond) - stage_started_at

        if elapsed < budget_ms do
          Process.sleep(backoff_ms)

          stop_core_with_retry(
            stop_core_fun,
            stage_started_at,
            budget_ms,
            min(backoff_ms * 2, @busy_backoff_cap_ms)
          )
        else
          Logger.warning(
            "Vagus.Host.Shutdown: core stop stayed busy for #{elapsed}ms, giving up — " <>
              "proceeding with shutdown anyway"
          )

          :busy_gave_up
        end

      {:error, reason} ->
        Logger.warning("Vagus.Host.Shutdown: core stop failed, proceeding: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
