defmodule Vagus.BoundedCall do
  @moduledoc """
  Runs a function in a task with a deadline — the shared shape behind the
  watchdogs' per-attempt timeouts (`Vagus.Addon.Watchdog`,
  `Vagus.Addon.Watchdog.Probe`, `Vagus.Core.Watchdog`,
  `Vagus.Core.Watchdog.Probe`).

  The task is linked (`Task.async/1`) on purpose: callers run inside their
  own watchdog sequence task, and the watchdog's deadline failsafe
  brutal-kills that task — the link takes this inner call down with it
  rather than leaving it running orphaned. Killing it cannot orphan a
  `:global.trans/3` lock it was still *waiting* on: `:global` only grants
  (and releases on death) a lock held by a process inside the critical
  section.

  The function's own failures are caught **inside** the task and handed
  back as a value, so a crash never travels over the link and kills the
  caller before `Task.yield/2` could report it: a raise, throw or exit
  comes back as `{:error, {:exit, reason}}` with the same `reason` a
  crashed task's `{:exit, reason}` would carry.
  """

  @doc """
  `fun.()`'s value, `{:error, {:exit, reason}}` if it raised, threw or
  exited, or `{:error, :attempt_timeout}` after `timeout_ms` (the task is
  then brutal-killed).
  """
  @spec run((-> result), timeout()) :: result | {:error, {:exit, term()} | :attempt_timeout}
        when result: term()
  def run(fun, timeout_ms) do
    task = Task.async(fn -> capture(fun) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> result
      {:ok, {:caught, reason}} -> {:error, {:exit, reason}}
      # Only reachable if the task is killed from outside between the yield
      # timing out and the shutdown landing.
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :attempt_timeout}
    end
  end

  defp capture(fun) do
    {:ok, fun.()}
  catch
    :error, error ->
      {:caught, {Exception.normalize(:error, error, __STACKTRACE__), __STACKTRACE__}}

    :throw, value ->
      {:caught, {{:nocatch, value}, __STACKTRACE__}}

    :exit, reason ->
      {:caught, reason}
  end
end
