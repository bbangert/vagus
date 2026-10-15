defmodule Vagus.Core.ConfigCheck do
  @moduledoc """
  `POST /core/check` (audit G3) — runs Core's own config validator inside
  the running Core container, mirroring upstream `supervisor/
  homeassistant/module.py::check_config`: `python3 -m homeassistant -c
  /config --script check_config`, exit code `0` AND no
  `homeassistant.util.yaml` in the (color-stripped) log == valid. Before
  this module, `POST /core/check` ran `Vagus.Core.Health`'s liveness probe
  instead — a GET to Core's `/manifest.json` — which is wrong in both
  directions: a broken `configuration.yaml` still answers 200 (Core is up,
  just running on its last-good config), and a stopped Core 400s where
  upstream's config check can still run. Neither carries a log either way.

  ## Deviation from upstream

  Upstream's check runs in a throwaway, freshly-created container, so it
  works even while the real Core container is stopped. Vagus v1 has no
  landingpage/scratch-container machinery (`Vagus.Core.Container`
  moduledoc, "Deliberate v1 omissions" — the same gap that keeps
  `Vagus.Core.Lifecycle.start/1` from pulling a missing image) to spin one
  up for a single command, so this execs into the RUNNING Core container
  instead (`Vagus.Runtime.Engine.exec/3`). A stopped Core degrades
  honestly to `{:not_running, message}` rather than either of the old
  bug's two wrong answers.
  """

  alias Vagus.Core.Container
  alias Vagus.Runtime.{Engine, Logs}

  # Exec'd directly: the command has no shell syntax, and the engine
  # resolves `python3` on the container's PATH as the shell did.
  @check_argv ~w(python3 -m homeassistant -c /config --script check_config)
  @invalid_marker ~r/homeassistant\.util\.yaml/
  @deadline_ms 300_000

  @type result ::
          :valid
          | {:invalid, String.t()}
          | {:not_running, String.t()}
          | {:error, term()}

  @doc """
  Runs the check. `opts[:engine_opts]` threads into every
  `Vagus.Runtime.Engine` call; its `:timeout_ms` overrides the check's
  deadline.

    * `:valid` — exit code 0, no yaml-error marker in the log.
    * `{:invalid, log}` — nonzero exit code or the marker matched; `log`
      is the ANSI-stripped, demuxed combined stdout/stderr, meant to be
      surfaced verbatim as the error response's message (upstream does
      the same — the log IS the error detail).
    * `{:not_running, message}` — Core's container is absent or stopped
      (the documented deviation above).
    * `{:error, reason}` — a `Vagus.Runtime.Engine.error()` running the
      check, `:timeout` when the whole check outlasted its deadline.
  """
  @spec check(keyword()) :: result()
  def check(opts \\ []) do
    # The check's output is a stream whose pace Core's container sets, so
    # only a deadline bounds it; past it the command is left to exit in the
    # container.
    engine_opts =
      opts |> Keyword.get(:engine_opts, []) |> Keyword.put_new(:timeout_ms, @deadline_ms)

    case Engine.inspect(Container.name(), engine_opts) do
      {:ok, container} ->
        if Engine.Container.alive?(container), do: run_check(engine_opts), else: not_running()

      {:error, :not_found} ->
        not_running()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp not_running, do: {:not_running, "cannot run config check while Core is not running"}

  defp run_check(engine_opts) do
    case Engine.exec(Container.name(), @check_argv, engine_opts) do
      {:ok, %{exit_code: code, output: output}} ->
        log = Logs.strip_ansi(output)
        if code == 0 and not Regex.match?(@invalid_marker, log), do: :valid, else: {:invalid, log}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
