defmodule Vagus.Core.Health do
  @moduledoc """
  Core's frontend health gate
  (`.claude/plans/vagus-core-lifecycle/research/supervisor-semantics.md`
  §5, mirroring upstream `_block_till_run`/`verify_frontend`) — a plain
  module, no process, since a single poll loop or one-shot check has no
  state worth supervising.

  Probes `/manifest.json` — Core's frontend, reachable unauthenticated, the
  same external-client analog upstream's `verify_frontend` uses — treating
  any 2xx status as healthy. The probe rides whatever
  `Vagus.Core.Transport` resolves: the Supervisor↔Core unix socket when it
  exists, `:core_base_url` otherwise. Nothing here knows Core's TCP port
  any more — that was the last hardcoded `:8123` on this path, which matters
  because a supervised Core binds 80 and only falls back to 8123.

  `await_healthy/1` polls every `opts[:interval]` (default `5_000`ms) until
  healthy or `opts[:deadline]` (default `600_000`ms = 10min, upstream's
  `STARTUP_API_RESPONSE_TIMEOUT`) elapses, using a monotonic-time bound —
  `Process.sleep/1` between attempts is fine here (unlike a GenServer, there
  is no message queue this would starve). `check/1` is a single immediate
  probe, used as the Core watchdog's liveness check
  (`Vagus.Core.Watchdog.Probe`). NOT what `POST /core/check` runs — that
  route is a config validity check (`Vagus.Core.ConfigCheck`, audit G3), a
  different question this module's plain up/down probe can't answer.

  Both accept an injectable `opts[:probe]` — a zero-arity function returning
  `:ok | {:error, term()}` — so tests never make a real HTTP call unless
  they explicitly want to exercise the default Finch wiring (in which case
  `opts[:url]` pins the probe to one absolute TCP URL, e.g. a local stub
  server, bypassing transport resolution entirely). The default probe
  issues a Finch GET through the `Vagus.Core.Finch` pool (`opts[:finch]`
  overrides it) with a 5s receive timeout.
  """

  alias Vagus.Core.Transport

  @default_interval 5_000
  @default_deadline 600_000
  @default_probe_timeout 5_000
  @probe_path "/manifest.json"
  @default_finch Vagus.Core.Finch

  @doc """
  Polls until healthy or `opts[:deadline]` elapses.

  Options:

    * `:interval` - ms between probe attempts, default `5_000`.
    * `:deadline` - ms total budget, default `600_000` (10min).
    * `:probe` - zero-arity `-> :ok | {:error, term()}`, default the Finch
      probe.
    * `:url` - absolute URL pinning the default probe to one TCP endpoint,
      bypassing `Vagus.Core.Transport`. Default: `/manifest.json` on the
      resolved transport. Ignored if `:probe` is given.
    * `:finch` - the Finch pool the default probe uses, default
      `#{inspect(@default_finch)}`. Ignored if `:probe` is given.
  """
  @spec await_healthy(keyword()) :: :healthy | :timeout
  def await_healthy(opts \\ []) do
    interval = Keyword.get(opts, :interval, @default_interval)
    deadline_ms = Keyword.get(opts, :deadline, @default_deadline)
    probe = probe_fun(opts)
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    poll(probe, interval, deadline)
  end

  @doc """
  A single immediate probe — `:healthy` | `:unhealthy`. Same `:probe`/`:url`
  options as `await_healthy/1` (`:interval`/`:deadline` are irrelevant here).
  """
  @spec check(keyword()) :: :healthy | :unhealthy
  def check(opts \\ []) do
    case probe_fun(opts).() do
      :ok -> :healthy
      {:error, _reason} -> :unhealthy
    end
  end

  ## Internals

  defp poll(probe, interval, deadline) do
    case probe.() do
      :ok ->
        :healthy

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(interval)
          poll(probe, interval, deadline)
        end
    end
  end

  defp probe_fun(opts) do
    case Keyword.get(opts, :probe) do
      nil ->
        url = Keyword.get(opts, :url)
        finch = Keyword.get(opts, :finch, @default_finch)
        fn -> default_probe(url, finch) end

      probe when is_function(probe, 0) ->
        probe
    end
  end

  # Resolved per probe, never cached: this runs on the Core watchdog's timer
  # and per proxied request, so it is also the fastest path to notice the
  # socket Core creates when it (re)starts.
  defp default_probe(url, finch) do
    request =
      if url do
        Finch.build(:get, url)
      else
        Transport.build(Transport.current(), :internal, :get, @probe_path)
      end

    case Finch.request(request, finch, receive_timeout: @default_probe_timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # `Finch.request/3` raises (rather than returning an error) when its pool
    # isn't running — reachable in the window where the `:rest_for_one` Core
    # subtree is restarting, which is exactly when this probe runs most. Same
    # rescue `Vagus.Core.HttpConfig.fetch/2` carries: an unhealthy answer (and
    # the proxy's documented 502) rather than a crashed request worker or a
    # watchdog probe that dies instead of recovering Core.
    e in ArgumentError -> {:error, {:finch_unavailable, Exception.message(e)}}
  end
end
