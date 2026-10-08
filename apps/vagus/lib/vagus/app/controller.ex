defmodule Vagus.App.Controller do
  @moduledoc """
  The owner of kind `:app`: what makes an app's instance what its spec
  wants. See "The App kind" in `docs/app-lifecycle.md`.

  The three parts are apart. `Vagus.App.Controller.Observe` reads,
  `Vagus.App.Controller.Reconcile` decides, from the facts
  `Vagus.App.Controller.View` works out, and `act/3` here performs the
  one action a pass may have, each a single call to the backend, the pull
  worker, the token table or `Vagus.App.Prepare`.

  ## Conditions

  `:ready`, `:progressing` and `:failed`, all three in every verdict and
  with the same reason. Ready: the instance runs, is ready as its profile
  defines it, and every gate is open. Progressing: the controller is on its
  way to what is wanted, or waits for something that comes by itself.
  Failed: it has given up until the spec changes; or, as
  `readiness_timeout`, the instance has not become ready within its
  deadline, is still asked, and is Ready when it answers. None of the
  three: the app is where it should be and that is not running.

  ## Context

  What the runtime's `:context` has to carry (`Vagus.App.wiring/1`):

    * `:facts`, a `Vagus.App.Facts`, which admission in the store reads
      as well
    * `:backends`, `%{backend_module => options}`
    * `:gates`, the condition types of other controllers that must be true,
      naming the instance, before the app is Ready (default none)
    * `:prober`, a `Vagus.App.Readiness` module or a function like its
      `c:Vagus.App.Readiness.probe/2` (default
      `Vagus.App.Readiness.Http`), `:http_address`,
      `{host, port}` an `{:http, path}` app without an address of its own
      is asked at, and `:host_address`, `(port -> host)` for the probe of
      an app on the host network
    * `:supervisor_token`, `(-> token | nil)`
    * `:api_ready`, `(-> boolean)`: whether the API an app calls as it
      starts is accepting. No instance is created or started while it
      is not (default: always)
    * `:prepare`, options for `Vagus.App.Prepare.run/3`. Its `:engine` is
      the container backend's unless given
    * `:observe_timeout`, milliseconds

  ## Lanes

  An action that asks the engine for something runs in the `:engine` lane.
  The rest run in none: a pull request and its cancel return at once, the
  token table answers from memory, and a native app's start and stop
  (`:start_process`, `:stop_process`) are calls within this VM. Removing an
  app's data is file work that no lane counts.

  A lane bounds actions, not passes. A pass holds one of its runtime's
  steps from its observation to the end of its action, the wait for a lane
  included, so a runtime with as many steps as the engine lane has slots
  would observe nothing while that many slow engine actions run.
  `Vagus.App.wiring/1` therefore gives the App runtime more steps than the
  lane has slots.
  """

  @behaviour Vagus.Resource.Controller

  alias Vagus.App.{AuthIndex, Backend, Container, Prepare, Profile, Pulls, Token}
  alias Vagus.App.Controller.{Observe, Reconcile}
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource

  @engine_actions [
    :create,
    :start,
    :stop,
    :remove,
    :stop_leftover,
    :remove_leftover,
    :remove_image,
    :put_token
  ]

  @impl true
  def kind, do: Schema.kind()

  @impl true
  def condition_types, do: [:ready, :progressing, :failed]

  @impl true
  def finalizer, do: Reconcile.finalizer()

  @impl true
  def writer_entries, do: Schema.writer_entries()

  # By the facts the passes read: a spec made for the machine this
  # controller is wired for is admitted by its store, and no other is.
  @impl true
  def validate(spec, context), do: Schema.validate(spec, Map.fetch!(context, :facts))

  @impl true
  def encode_spec(spec), do: Schema.encode_spec(spec)

  @impl true
  def decode_spec(raw), do: Schema.decode_spec(raw)

  # While it waits for a wave, the apps it waits for: a change to one of
  # them is this app's next pass. Nobody else is referred to, so an app
  # that has started is woken by no other.
  @impl true
  def references(%Resource{status: status}),
    do: for(name <- Map.get(status, :waiting_on, []), do: {kind(), name})

  @impl true
  def action_class(action) when action in @engine_actions, do: :engine
  def action_class(_action), do: nil

  @impl true
  def observe(resource, context), do: Observe.observe(resource, context, __MODULE__)

  @impl true
  defdelegate reconcile(resource, observation), to: Reconcile

  # Whatever an action raises, throws or exits with is its failure, to be
  # recorded and judged like one it returned: left to end the step's task,
  # it would be a crashed step, tried again for ever with nothing in status
  # to say so. Two of the actions hold a token, and what they raise would
  # carry it: the guard passes on the kind of failure and where it
  # happened, nothing else. See `Vagus.App.Token.guard/1` for which
  # failures are worth trying again.
  @impl true
  def act(action, args, context), do: Token.guard(fn -> perform(action, args, context) end)

  # The token is made here and nowhere kept: it goes into the container's
  # environment and is read back from there.
  defp perform(:create, _args, %{resource: %{name: app, spec: spec}} = context) do
    profile = Profile.of(spec)
    {backend, opts} = Observe.backend(profile, context)

    with {:ok, prepared} <- prepare(spec, context),
         {:ok, config} <- build(spec, context.facts, Map.put(prepared, :token, Token.mint())) do
      backend.create(profile.container_name(app), config, opts)
    end
  end

  defp perform(:start, _args, context), do: instance(context, & &1.start(&2, &3))

  # A native app has nothing to create, so what a create prepares is
  # prepared here.
  defp perform(:start_process, _args, %{resource: %{spec: spec}} = context) do
    with {:ok, _prepared} <- prepare(spec, context),
         do: instance(context, & &1.start(&2, &3))
  end

  defp perform(stop, %{grace: grace}, context) when stop in [:stop, :stop_process],
    do: instance(context, & &1.stop(&2, grace, &3))

  defp perform(:remove, _args, context), do: instance(context, & &1.remove(&2, &3))

  defp perform(:stop_leftover, _args, context),
    do: leftover(context, &Backend.Container.stop(&1, nil, &2))

  defp perform(:remove_leftover, _args, context),
    do: leftover(context, &Backend.Container.remove/2)

  defp perform(:request_pull, %{image: image, priority: priority}, context) do
    Pulls.request(image, {__MODULE__, context.resource.name},
      instance: context.instance,
      platform: Container.Config.platform(context.facts),
      priority: priority
    )
  end

  defp perform(:cancel_pull, %{image: image}, context),
    do: Pulls.cancel(image, {__MODULE__, context.resource.name}, instance: context.instance)

  # The token is read here, from the instance, and not handed in: an
  # action's arguments are kept by the runtime and shown with a failure.
  defp perform(:put_token, %{instance: id}, %{resource: %{name: app, spec: spec}} = context) do
    profile = Profile.of(spec)
    {backend, opts} = Observe.backend(profile, context)

    with {:ok, %{id: ^id, env: env}} <- backend.observe(profile.container_name(app), opts),
         token when is_binary(token) <- Token.of(source(profile, context), env) do
      AuthIndex.put(app, token, instance: context.instance)
    else
      {:unavailable, reason} -> {:error, {:unreachable, reason}}
      {:error, failure} -> {:error, failure}
      _another_instance_or_none -> {:error, {:other, :instance_changed}}
    end
  end

  defp perform(:remove_token, _args, context),
    do: AuthIndex.remove(context.resource.name, instance: context.instance)

  # An image another container still uses is refused by the engine. The
  # error is what tells the next pass to leave the image: it would be there
  # to see either way.
  defp perform(:remove_image, %{image: image}, %{resource: %{spec: spec}} = context) do
    {backend, opts} = Observe.backend(Profile.of(spec), context)
    backend.remove_image(image, opts)
  end

  # By the manifest's slug, as the directory was made and is looked for.
  defp perform(:remove_data, _args, %{resource: %{spec: %{config: %{slug: slug}}}} = context),
    do: Prepare.remove_data(slug, context.facts)

  defp instance(%{resource: %{name: app, spec: spec}} = context, call) do
    profile = Profile.of(spec)
    {backend, opts} = Observe.backend(profile, context)
    call.(backend, profile.container_name(app) || app, opts)
  end

  defp leftover(%{resource: %{name: app}} = context, call) do
    opts = Map.get(Map.get(context, :backends, %{}), Backend.Container, [])
    call.(Observe.leftover_name(app), opts)
  end

  # On the engine the container is made on: the backend's options name it.
  defp prepare(spec, context) do
    {_backend, opts} = Observe.backend(Profile.of(spec), context)
    engine = Keyword.get(opts, :engine, [])

    Prepare.run(
      spec,
      context.facts,
      Keyword.put_new(Map.get(context, :prepare, []), :engine, engine)
    )
  end

  # A config this build cannot make is refused before the engine is asked,
  # and will be refused again.
  defp build(spec, facts, creation) do
    with {:error, refusal} <- Container.Config.build(spec, facts, creation),
         do: {:error, {:invalid, refusal}}
  end

  defp source(profile, context) do
    case profile.token() do
      :supervisor -> {:supervisor, Map.get(context, :supervisor_token, &Vagus.API.Token.get/0)}
      other -> other
    end
  end

  @typedoc "The `state` Core is told an app is in."
  @type wire_state :: :started | :startup | :error | :stopped | :unknown

  @doc """
  An app's state on the wire, from its status alone: `:unknown` until a
  pass has observed it.

  Ready and Failed count only as said of the spec as it is. After a write
  and until the next pass has committed, they are of the generation before
  and are taken as not said: the app reads `:startup` if an instance is
  recorded as running and `:stopped` if not. The recorded instance and
  `state` are what the last pass saw, not a verdict on any spec, and are
  read as they are.
  """
  @spec wire_state(Resource.t()) :: wire_state()
  def wire_state(%Resource{status: status, generation: generation} = app) do
    true? =
      &match?(
        %{status: true, observed_generation: ^generation},
        Resource.get_condition(app, &1)
      )

    cond do
      not is_map_key(status, :state) -> :unknown
      true?.(:failed) -> :error
      true?.(:ready) -> :started
      match?(%{instance: %{running?: true}}, status) -> :startup
      true -> :stopped
    end
  end
end
