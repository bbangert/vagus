defmodule Vagus.Engine do
  @moduledoc """
  Thin `System.cmd/3`-based wrappers around the `balena-engine` CLI, talking
  to the daemon that `Vagus.Engine.Manager` supervises over its Unix socket.

  Shelling out is the deliberate spike choice (matching the nerves-containers
  prior art in `research/balena-packaging-scan.md`) instead of an Engine-API
  client over the socket; a real client is post-spike work.

  Argument construction (`build_args/1`) is kept pure and separate from
  execution so it can be unit tested on `:host` without a real
  `balena-engine` binary or daemon present.
  """

  @binary "balena-engine"
  @socket "unix:///run/balena-engine.sock"

  @typedoc "The subcommand + arguments to run, matching `MuonTrap.Daemon`'s --host flags."
  @type invocation :: :info | :ps | {:pull, String.t()} | {:run, [String.t()]}

  @doc "The daemon's control socket (matches `--host` in `Vagus.Engine.Manager`)."
  @spec socket() :: String.t()
  def socket, do: @socket

  @doc """
  Builds the argv for `invocation`, always addressing the daemon's Unix
  socket explicitly via `--host` (pure, unit-tested).
  """
  @spec build_args(invocation()) :: [String.t()]
  def build_args(:info), do: base_args() ++ ["info"]
  def build_args(:ps), do: base_args() ++ ["ps", "-a"]
  def build_args({:pull, image}) when is_binary(image), do: base_args() ++ ["pull", image]
  def build_args({:run, args}) when is_list(args), do: base_args() ++ ["run" | args]

  defp base_args, do: ["--host", @socket]

  @doc "Runs `balena-engine info`. Returns `{output, exit_status}`."
  @spec info() :: {String.t(), non_neg_integer()}
  def info, do: run_cli(:info)

  @doc "Runs `balena-engine pull <image>`. Returns `{output, exit_status}`."
  @spec pull(String.t()) :: {String.t(), non_neg_integer()}
  def pull(image) when is_binary(image), do: run_cli({:pull, image})

  @doc """
  Runs `balena-engine run` with `args` appended verbatim, e.g.
  `run(["-d", "--name", "homeassistant", "--network=host", "some/image"])`.
  Returns `{output, exit_status}`.
  """
  @spec run([String.t()]) :: {String.t(), non_neg_integer()}
  def run(args) when is_list(args), do: run_cli({:run, args})

  @doc "Runs `balena-engine ps -a`. Returns `{output, exit_status}`."
  @spec ps() :: {String.t(), non_neg_integer()}
  def ps, do: run_cli(:ps)

  @doc """
  Polls `balena-engine info` every 2 seconds until it exits `0` (daemon
  socket up and answering) or `timeout_ms` elapses (default 60s).
  """
  @spec wait_ready(timeout_ms :: non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_ready(timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until_ready(deadline)
  end

  defp poll_until_ready(deadline) do
    case info() do
      {_output, 0} ->
        :ok

      _not_ready ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(2_000)
          poll_until_ready(deadline)
        end
    end
  end

  defp run_cli(invocation) do
    System.cmd(@binary, build_args(invocation), stderr_to_stdout: true)
  rescue
    # System.cmd/3 raises ErlangError (wrapping :enoent) when @binary isn't
    # on PATH — expected on host/dev, not just a target-only concern. Keep
    # the same {out, exit_status} shape callers already handle rather than
    # letting this blow up with an opaque erlang-level error.
    ErlangError -> {"balena-engine binary not found", 127}
  end
end
