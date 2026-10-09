defmodule Vagus.Host.Shutdown do
  @moduledoc """
  The single facade every reboot/poweroff initiator in this codebase must
  call instead of `Nerves.Runtime.reboot/0`/`poweroff/0` directly (issue
  #39).

  ## The corruption problem

  HA Core and every app container keep their state in `.storage/*` JSON
  files that get written with a temp-file-then-rename dance, but that
  dance only protects against a crash *between* writes — it does nothing
  if the process is SIGKILLed mid-write. `erlinit`'s shutdown path sends
  every still-running container a hard kill (it doesn't know how to ask
  balena-engine to gracefully `docker stop` its containers, and doesn't
  wait around for it if it did) once the BEAM has exited, so a reboot or
  poweroff that races Core or an app mid-write to `.storage` truncates
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

  `Vagus.Addon.Watchdog` restarts an app on any `die` event while
  `Vagus.Addon.State` says `state: :started, watchdog: true`. A user's stop
  records `:stopped` first, so its `die` is ignored; the shutdown's stops
  deliberately do not (`Vagus.App.Orchestrator.shutdown/2`), so the next boot
  starts the same apps, and every `docker stop` would otherwise look like a
  crash and restart an app that erlinit then SIGKILLs moments later.

  `in_flight?/0` closes that gap: `do_run/2` sets a `:persistent_term` flag
  before the stop stages and the watchdog checks it before any restart. A
  `:persistent_term`, not watchdog state, because it must survive the
  watchdog restarting mid-shutdown. It stays set once the stages finish: the
  reboot always follows. The exception is the runtime call itself failing:
  the device is not going down, so the flag is erased, the orchestrator
  boots the apps again, and the failure propagates.

  The Core watchdog needs no flag: it counts only nonzero-exit `die`s, and a
  `docker stop` exits 0.

  ## Budgets

  `300_000` ms bounds the whole stop sequence, well under `nerves_runtime`'s
  own ~10-minute halt backstop after `:init.stop/0`. It is split three
  ways: the `application` apps stopped ahead of Core (35 s per app, all at
  once), then Core until a deadline that keeps the same 35 s plus a 5 s
  margin back for the `initialize`, `system` and `services` apps stopped
  after it. Those run Core's dependencies, MQTT among them, so they must
  always get their stop. Core's worst-case stop (260 s,
  `@fallback_stop_timeout_s` in `Vagus.Core.Lifecycle`) is cut short by
  however long the apps ahead of it took; past its deadline Core is left
  stopping. The per-app and Core busy budgets are the orchestrator's
  and `Vagus.App.CoreUnit`'s.
  """

  require Logger

  @total_budget_ms 300_000

  @doc """
  Stops every started app container and HA Core (best-effort, bounded),
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
    {app_result, core_result} = bounded_stop_stages(kind, opts)
    {ok_count, total} = app_result
    elapsed = System.monotonic_time(:millisecond) - started_at

    Logger.warning(
      "Vagus.Host.Shutdown: #{kind} — apps stopped #{ok_count}/#{total}, " <>
        "core #{inspect(core_result)}, elapsed #{elapsed}ms"
    )

    try do
      call_runtime(kind, opts)
    rescue
      exception ->
        Logger.error(
          "Vagus.Host.Shutdown: runtime #{kind} call raised, device is NOT going down — " <>
            "clearing in-flight flag and booting the apps again (#{Exception.format(:error, exception, __STACKTRACE__)})"
        )

        resume(opts)
        reraise exception, __STACKTRACE__
    catch
      kind_caught, reason ->
        Logger.error(
          "Vagus.Host.Shutdown: runtime #{kind} call failed (caught #{kind_caught}: " <>
            "#{inspect(reason)}), device is NOT going down — clearing in-flight flag and booting the apps again"
        )

        resume(opts)
        :erlang.raise(kind_caught, reason, __STACKTRACE__)
    end

    :ok
  end

  defp resume(opts) do
    :persistent_term.erase({__MODULE__, :in_flight})
    Keyword.get(opts, :resume, &Vagus.App.Orchestrator.resume/0).()
  end

  defp call_runtime(:reboot, opts) do
    Keyword.get(opts, :runtime_reboot, &Nerves.Runtime.reboot/0).()
  end

  defp call_runtime(:poweroff, opts) do
    Keyword.get(opts, :runtime_poweroff, &Nerves.Runtime.poweroff/0).()
  end

  ## Bounded stop stages — see moduledoc "Availability over cleanliness".

  # An unbounded call is a wedge, and a failure to even start the task must
  # still fall through to the runtime call.
  defp bounded_stop_stages(kind, opts) do
    total_budget_ms = Keyword.get(opts, :total_budget_ms, @total_budget_ms)

    stop =
      Keyword.get(
        opts,
        :orchestrator,
        &Vagus.App.Orchestrator.shutdown(Vagus.App.Orchestrator, &1)
      )

    task =
      Task.Supervisor.async_nolink(Vagus.Jobs.TaskSupervisor, fn -> stop.(total_budget_ms) end)

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
end
