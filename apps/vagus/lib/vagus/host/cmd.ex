defmodule Vagus.Host.Cmd do
  @moduledoc """
  `System.cmd/3` with a missing-binary rescue, for the host-shellout callers
  that treat a failed command as a degraded path rather than a crash.

  `System.cmd/3` does not return a nonzero-status tuple when the binary is
  absent or unusable — it *raises* `ErlangError`, which bypasses every
  `{output, status}` clause a caller has written. That cost the app its life
  on a first boot once (issue #45: rpi3_64 ships no `resize2fs`), so the
  rescue lives here, in one place, rather than being re-derived at each new
  call site.

  Nothing is logged here: the reason travels in the returned message, so
  each caller's existing nonzero-status log stays the single logging point.
  """

  @doc """
  Runs `bin` with `args`, stderr merged into stdout. A missing or unusable
  binary yields `{message, 127}` ("command not found") instead of raising.
  """
  @spec run(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  # bin/args are hardcoded invocations from callers, never request input
  # sobelow_skip ["CI.System"]
  def run(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  rescue
    # Rescuing the shape rather than enumerating reasons (`:enoent`,
    # `:eacces`, ...) — any of them means "this command didn't run".
    exception in [ErlangError] ->
      reason = exception.original
      {"#{bin}: #{inspect(reason)}", 127}
  end
end
