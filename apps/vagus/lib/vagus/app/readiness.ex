defmodule Vagus.App.Readiness do
  @moduledoc """
  Whether a running instance is ready, and whether one that was ready still
  answers.

  Readiness is the profile's (`c:Vagus.App.Profile.readiness/1`):

    * `:container`: running, and healthy where the image has a healthcheck.
      `starting` is not ready; an image without one is ready when it runs.
    * `{:http, path}`: a `GET` of `path` answered 2xx, which is what Core's
      own health check accepts. Asked until it has answered once.
    * `:process`: the instance exists.

  An app whose manifest has a `watchdog` URL is also asked, every
  `probe_interval_ms/0` once it is ready, whether it still answers there:
  the template and what counts as an answer are
  `Vagus.Addon.ProbeURL.watchdog_spec/4`'s and
  `Vagus.Addon.Watchdog.Probe`'s (a TCP connect, or an HTTP status below
  300). Two misses in a row are an
  unhealthy app. A probe that could not be aimed, the instance having no
  address, is neither a miss nor an answer.

  Everything here is a pure function of what was observed. Asking is
  `c:probe/2`, behind a behaviour so that a test answers for it.
  """

  alias Vagus.Addon.{Config, ProbeURL}
  alias Vagus.App.Backend
  alias Vagus.Resource.Stamp

  @typedoc "`proto` is `http`, `https` or `tcp`, as a string; `path` is unused for the last."
  @type target :: %{proto: String.t(), host: String.t(), port: pos_integer(), path: String.t()}

  @typedoc "Misses in a row, and when the app was last asked or began to be watched."
  @type probe :: %{misses: non_neg_integer(), at: Stamp.t() | nil}

  @doc "Asks `target` once, giving up after `timeout` milliseconds."
  @callback probe(target(), timeout :: pos_integer()) :: :ok | :error

  @probe_interval_ms 120_000
  @strikes 2

  @spec probe_interval_ms() :: pos_integer()
  def probe_interval_ms, do: @probe_interval_ms

  @doc """
  `answered?` is whether an `{:http, path}` app has answered, now or
  before; other kinds ignore it. The reason an instance is not ready is
  the condition's reason.
  """
  @spec decide(Vagus.App.Profile.readiness(), Backend.instance() | map(), boolean()) ::
          :ready | {:waiting, atom()}
  def decide(_readiness, %{state: state}, _answered?) when state != :running,
    do: {:waiting, :not_running}

  def decide(%{kind: :container}, %{health: health}, _answered?) do
    case health do
      :starting -> {:waiting, :health_starting}
      :unhealthy -> {:waiting, :unhealthy}
      _healthy_or_none -> :ready
    end
  end

  def decide(%{kind: {:http, _path}}, _instance, answered?),
    do: if(answered?, do: :ready, else: {:waiting, :not_answering})

  def decide(%{kind: :process}, _instance, _answered?), do: :ready

  @doc "Whether an instance running since `since` has had its time to become ready."
  @spec past_deadline?(Vagus.App.Profile.readiness(), Stamp.t() | nil, Stamp.t()) :: boolean()
  def past_deadline?(%{deadline_ms: :infinity}, _since, _now), do: false
  def past_deadline?(_readiness, nil, _now), do: false
  def past_deadline?(%{deadline_ms: ms}, since, now), do: Stamp.age(since, now) >= ms

  @doc "Where an `{:http, path}` app is asked: `address` is `{host, port}`."
  @spec http_target(Vagus.App.Profile.readiness(), {String.t(), pos_integer()}) :: target() | nil
  def http_target(%{kind: {:http, path}}, {host, port}),
    do: %{proto: "http", host: host, port: port, path: path}

  def http_target(_readiness, _address), do: nil

  @doc """
  Where the manifest's `watchdog` URL points for this instance, or `nil` for
  a manifest without one, a template that does not parse, or an instance
  with no address. An app on the host network has no address of its own:
  `host_address` is asked for the host's, given the port.
  """
  @spec watchdog_target(map(), map(), (pos_integer() -> String.t() | nil)) :: target() | nil
  def watchdog_target(
        %{config: %Config{watchdog: template} = config} = spec,
        instance,
        host_address
      )
      when is_binary(template) do
    options = Map.merge(config.options || %{}, Map.get(spec, :options, %{}))

    with {:ok, %{proto: proto, port: port, suffix: suffix}} <-
           ProbeURL.watchdog_spec(template, config, options, ""),
         host when is_binary(host) <- host(config, instance, port, host_address) do
      %{proto: proto, host: host, port: port, path: if(suffix == "", do: "/", else: suffix)}
    else
      _none -> nil
    end
  end

  def watchdog_target(_spec, _instance, _host_address), do: nil

  defp host(%Config{host_network: true}, _instance, port, host_address), do: host_address.(port)
  defp host(_config, instance, _port, _host_address), do: instance.address

  @doc "Whether an app watched since, or last asked at, `probe.at` is to be asked now."
  @spec probe_due?(probe(), Stamp.t()) :: boolean()
  def probe_due?(%{at: nil}, _now), do: false
  def probe_due?(%{at: at}, now), do: Stamp.age(at, now) >= @probe_interval_ms

  @doc "Milliseconds until `probe_due?/2`."
  @spec probe_due_in(probe(), Stamp.t()) :: non_neg_integer()
  def probe_due_in(%{at: nil}, _now), do: @probe_interval_ms
  def probe_due_in(%{at: at}, now), do: max(@probe_interval_ms - Stamp.age(at, now), 0)

  @doc "`probe` after an answer, a miss, or a probe that could not be aimed."
  @spec strike(probe(), :healthy | :unhealthy | :skipped, Stamp.t()) :: probe()
  def strike(_probe, :healthy, now), do: %{misses: 0, at: now}
  def strike(probe, :unhealthy, now), do: %{misses: probe.misses + 1, at: now}
  def strike(probe, :skipped, now), do: %{probe | at: now}

  @spec unhealthy?(probe()) :: boolean()
  def unhealthy?(%{misses: misses}), do: misses >= @strikes
end
