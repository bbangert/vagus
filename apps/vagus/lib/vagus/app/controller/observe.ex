defmodule Vagus.App.Controller.Observe do
  @moduledoc """
  What a pass of the App controller sees, read and never written: the
  app's instance, a container the other firmware slot left under
  `addon_<slug>`, its image and the pull of it, whether the token table has
  the instance's token, which earlier waves are still starting, and whether
  the app answers.

  The instance comes back from the backend with its environment, and the
  environment holds the token. It is taken apart in `instance/3`, the first
  thing done with it: the token becomes a state (`Vagus.App.Token.state/4`)
  and the instance that goes on has no environment. Nothing below that
  function, no observation and no crash report, can carry a token. The
  read and the taking apart run under `Vagus.App.Token.guard/1`: whatever
  either raises would be reported with the environment it held, so what
  leaves is that the engine's read failed.

  Every read has a bound: the engine's are given `:observe_timeout` as the
  silence they accept, and a probe its own. A read the engine fails or does
  not finish is `{:unavailable, :engine_error}`, like an engine that is
  away: the pass says so, counts nothing and looks again.
  """

  alias Vagus.Addon.Config
  alias Vagus.App.{Container, EngineObserver, Prepare, Profile, Pulls, Readiness, Token}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.Store

  @kind :app
  @leftover_prefix "addon_"
  @fallback_grace_s 260
  @readiness_timeout_ms 5_000
  @probe_timeout_ms 10_000

  @doc "The name of the container the other firmware slot runs the app in."
  @spec leftover_name(Resource.name()) :: String.t()
  def leftover_name(app), do: @leftover_prefix <> app

  @spec observe(Resource.t(), map(), module()) :: map() | {:unavailable, atom()}
  def observe(%Resource{name: app, spec: spec} = resource, context, controller) do
    profile = Profile.of(spec)
    {backend, opts} = profile |> backend(context) |> bounded(context)
    i = [instance: context.instance]

    with {:ok, {token, instance}} <- seen(backend, {profile, spec, app}, opts, context),
         {:ok, leftover} <- leftover(profile, app, instance, context),
         image = image(spec, context),
         # Before the image is asked after: a pull that ends in between has
         # put the image there, and one read the other way round would be
         # an image that is missing and no pull, to be asked for again.
         pull = pull(image, {controller, app}, i),
         {:ok, present?} <- image_present?(backend, image, instance, resource, opts) do
      if is_map(instance) and instance.process,
        do: EngineObserver.watch(app, instance.process, i)

      status = resource.status
      known = if is_map(instance), do: known(status[:instance], instance)
      probes? = known != nil and known.ready? and probed?(spec, profile)

      %{
        now: context.now,
        instance: instance,
        leftover: leftover,
        image: image,
        image_present?: present?,
        pull: pull,
        stale_pull: stale_pull(status[:pull], image, {controller, app}, i),
        api?: Map.get(context, :api_ready, fn -> true end).(),
        token: token,
        waiting_on: waiting_on(resource, instance, profile, i),
        gates: Map.get(context, :gates, []),
        ready: ready(profile.readiness(spec), instance, known, context),
        probes?: probes?,
        probe: probe(probes?, spec, instance, status[:probe], context),
        data?: resource.deleting? and data?(spec, context),
        failed_action: failed(context.failed_action)
      }
    end
  end

  @doc "The profile's backend with its options from `context.backends`."
  @spec backend(module(), map()) :: {module(), keyword()}
  def backend(profile, context) do
    module = profile.backend()
    {module, Map.get(Map.get(context, :backends, %{}), module, [])}
  end

  defp bounded({module, opts}, context) do
    timeout = Map.get(context, :observe_timeout, 10_000)
    bound = &Keyword.put_new(&1, :recv_timeout, timeout)
    {module, Keyword.update(opts, :engine, bound.([]), bound)}
  end

  defp seen(backend, {profile, _spec, app} = whose, opts, context) do
    read(
      Token.guard(fn ->
        with {:ok, seen} <- backend.observe(profile.container_name(app) || app, opts),
             do: {:ok, instance(seen, whose, context)}
      end)
    )
  end

  defp read({:ok, seen}), do: {:ok, seen}
  defp read({:unavailable, reason}), do: {:unavailable, reason}
  defp read({:error, _failure}), do: {:unavailable, :engine_error}

  # The one place an instance has its environment. What leaves is the
  # token's state and an instance without one.
  defp instance(:absent, {profile, _spec, app}, context),
    do: {Token.state(source(profile, context), app, nil, instance: context.instance), :absent}

  defp instance(%{env: env} = seen, {profile, spec, app}, context) do
    source = source(profile, context)
    token = Token.of(source, env)

    {Token.state(source, app, token, instance: context.instance),
     seen
     |> Map.delete(:env)
     |> Map.merge(%{token?: token != nil, grace: grace(profile.stop_grace(spec), env)})}
  end

  defp source(profile, context) do
    case profile.token() do
      :supervisor -> {:supervisor, Map.get(context, :supervisor_token, &Vagus.API.Token.get/0)}
      other -> other
    end
  end

  # Seconds; `nil` is the engine's own default.
  defp grace(:default, _env), do: nil

  defp grace({:image_env, name, extra_s}, env) do
    case Integer.parse(Map.get(env, name, "")) do
      {ms, ""} when ms >= 0 -> extra_s + div(ms, 1000)
      _absent_or_unreadable -> @fallback_grace_s
    end
  end

  # Looked for while the app's own container does not run, which is when
  # one could be in the way of it. Core is `homeassistant` to both firmware
  # slots, and a native app has no container: neither leaves one under
  # another name.
  defp leftover(_profile, _app, %{state: state}, _context)
       when state in [:running, :paused, :restarting],
       do: {:ok, :absent}

  defp leftover(profile, app, _instance, context) do
    if profile.container_name(app) == "app_" <> app do
      {backend, opts} = profile |> backend(context) |> bounded(context)

      # Its environment holds the token the other slot gave it.
      read(
        Token.guard(fn ->
          with {:ok, seen} <- backend.observe(leftover_name(app), opts) do
            {:ok,
             case seen do
               :absent -> :absent
               %{state: state} when state in [:running, :paused, :restarting] -> :running
               _stopped -> :stopped
             end}
          end
        end)
      )
    else
      {:ok, :absent}
    end
  end

  defp image(spec, context) do
    case Container.Config.image(spec, context.facts) do
      {:ok, image} -> image
      {:error, :no_image} -> nil
    end
  end

  # Asked only when the answer decides something: with no instance, whether
  # to pull; of an app being removed, whether an image is left.
  defp image_present?(backend, image, instance, resource, opts)
       when is_binary(image) and (instance == :absent or resource.deleting?),
       do: read(backend.image_present?(image, opts))

  defp image_present?(_backend, _image, _instance, _resource, _opts), do: {:ok, true}

  defp pull(nil, _waiter, _i), do: :idle

  defp pull(image, waiter, i) do
    with {:pulling, _progress} <- Pulls.state(image, i) do
      case waiters(image, i) do
        # It ended between the two reads, and the table says how. Read as
        # a pull this app does not wait for, it would be asked for again.
        nil -> with {:pulling, _progress} <- Pulls.state(image, i), do: {:pulling, false}
        waiters -> {:pulling, waiter in waiters}
      end
    end
  end

  # The image this app asked for before the one it wants, if it still waits
  # for that pull: the lane has one slot, and the image wanted waits behind it.
  defp stale_pull(%{image: asked}, image, waiter, i) when is_binary(asked) and asked != image do
    if waiter in (waiters(asked, i) || []), do: asked
  end

  defp stale_pull(_recorded, _image, _waiter, _i), do: nil

  # The worker answers at once whatever a pull is doing. Without it there
  # is no pull to wait for.
  defp waiters(image, i) do
    case Pulls.info(i) do
      %{^image => %{waiters: waiters}} -> waiters
      _ended -> nil
    end
  catch
    :exit, _absent -> nil
  end

  # The apps of an earlier wave that should run and have neither become
  # ready nor given up, an app nothing was observed of among them. Only an
  # app that has yet to make its instance waits for anyone.
  defp waiting_on(%Resource{spec: spec, name: name} = resource, :absent, profile, i) do
    if Schema.wanted?(spec) and not resource.deleting? do
      wave = profile.wave(spec)

      for %Resource{name: other, spec: other_spec} = app <- Store.list(@kind, i),
          other != name,
          Profile.of(other_spec).wave(other_spec) < wave,
          Schema.wanted?(other_spec) and not app.deleting?,
          not settled?(app),
          do: other
    else
      []
    end
  end

  defp waiting_on(_resource, _instance, _profile, _i), do: []

  defp settled?(app) do
    Enum.any?([:ready, :failed], &match?(%{status: true}, Resource.get_condition(app, &1))) or
      app.status[:state] == :succeeded
  end

  # What is recorded of this run of the instance: the engine starts a
  # container again under the same id.
  defp known(%{id: id, started_at: at} = recorded, %{id: id, started_at: at}), do: recorded
  defp known(_recorded, _instance), do: nil

  # An app that answered once is not asked again: that it still answers is
  # its probe's to say, or its health's.
  defp ready(%{kind: {:http, _path}} = readiness, %{state: :running} = instance, known, context) do
    if known != nil and known.ready? do
      :ready
    else
      {host, port} = Map.get(context, :http_address, {"127.0.0.1", 8123})
      target = Readiness.http_target(readiness, {instance.address || host, port})
      if asked(target, @readiness_timeout_ms, context) == :ok, do: :ready, else: :not_ready
    end
  end

  defp ready(_readiness, _instance, _known, _context), do: :none

  defp probed?(%{config: %Config{watchdog: template}} = spec, profile) when is_binary(template),
    do: match?({:restart, _budget}, profile.restart_policy(spec))

  defp probed?(_spec, _profile), do: false

  defp probe(true, spec, instance, %{} = recorded, context) do
    if Readiness.probe_due?(recorded, context.now) do
      host = Map.get(context, :host_address, &Vagus.Network.host_network_ip/1)

      case Readiness.watchdog_target(spec, instance, host) do
        nil ->
          :skipped

        target ->
          if asked(target, @probe_timeout_ms, context) == :ok, do: :healthy, else: :unhealthy
      end
    else
      :none
    end
  end

  defp probe(_probes?, _spec, _instance, _recorded, _context), do: :none

  defp asked(target, timeout, context) do
    case Map.get(context, :prober, Readiness.Http) do
      probe when is_function(probe, 2) -> probe.(target, timeout)
      prober -> prober.probe(target, timeout)
    end
  end

  defp data?(%{config: %Config{slug: slug}}, context), do: Prepare.data?(slug, context.facts)
  defp data?(_spec, _context), do: false

  # Of its arguments only the generation the action was decided for.
  defp failed(nil), do: nil

  defp failed(%{name: name, args: args, reason: reason, at: at}),
    do: %{name: name, reason: reason, at: at, generation: is_map(args) && args[:generation]}
end
