defmodule Vagus.Core.Health do
  @moduledoc """
  Core's frontend health gate
  (`.claude/plans/vagus-core-lifecycle/research/supervisor-semantics.md`
  §5, mirroring upstream `_block_till_run`/`verify_frontend`) — a plain
  module, no process, since a single poll loop or one-shot check has no
  state worth supervising.

  Probes `http://localhost:8123/manifest.json` — Core's frontend, reachable
  unauthenticated over host networking, the same external-client analog
  upstream's `verify_frontend` uses — treating any 2xx status as healthy.

  `await_healthy/1` polls every `opts[:interval]` (default `5_000`ms) until
  healthy or `opts[:deadline]` (default `600_000`ms = 10min, upstream's
  `STARTUP_API_RESPONSE_TIMEOUT`) elapses, using a monotonic-time bound —
  `Process.sleep/1` between attempts is fine here (unlike a GenServer, there
  is no message queue this would starve). `check/1` is a single immediate
  probe, for `POST /core/check`.

  Both accept an injectable `opts[:probe]` — a zero-arity function returning
  `:ok | {:error, term()}` — so tests never make a real HTTP call unless
  they explicitly want to exercise the default Finch wiring (in which case
  `opts[:url]` overrides the probed URL, e.g. to point at a local stub
  server). The default probe issues a Finch GET through the
  `Vagus.Core.Finch` pool with a 5s receive timeout.
  """

  @default_interval 5_000
  @default_deadline 600_000
  @default_probe_timeout 5_000
  @default_url "http://localhost:8123/manifest.json"
  @default_finch Vagus.Core.Finch

  @doc """
  Polls until healthy or `opts[:deadline]` elapses.

  Options:

    * `:interval` - ms between probe attempts, default `5_000`.
    * `:deadline` - ms total budget, default `600_000` (10min).
    * `:probe` - zero-arity `-> :ok | {:error, term()}`, default the Finch
      probe against `opts[:url]`.
    * `:url` - URL for the default probe, default
      `"http://localhost:8123/manifest.json"`. Ignored if `:probe` is given.
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
        url = Keyword.get(opts, :url, @default_url)
        fn -> default_probe(url) end

      probe when is_function(probe, 0) ->
        probe
    end
  end

  defp default_probe(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, @default_finch, receive_timeout: @default_probe_timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Finch.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
