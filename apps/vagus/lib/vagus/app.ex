defmodule Vagus.App do
  @moduledoc """
  The App kind as the application runs it: `wiring/1` is what
  `Vagus.Resource.Supervisor` is started with to have apps reconciled.

  That call is the switch. `config :vagus, :controllers` alone is not: a
  controller listed there gets no context, and the App controller cannot
  observe without its facts and backends.

  It must not be switched on beside the lifecycle code it replaces
  (`Vagus.Addon.Manager`, the watchdogs, the boot starter). This controller
  stops and removes every `addon_<slug>` container of an app it has a
  resource for, which that watchdog would start again; and the native
  broker registers one name whichever of the two started it, so each would
  take the other's broker for its own.
  """

  # Twice the engine lane's four slots. A pass holds a step through its
  # action and the wait for a lane, so with as many steps as slots four
  # slow engine calls would leave every other app unobserved, a native
  # app's restart and every token put among them.
  @steps 8

  alias Vagus.App.{AuthIndex, Backend, Boot, Controller, EngineObserver, Facts, Pulls}

  @doc """
  The options for `Vagus.Resource.Supervisor`: the controller with its
  runtime's own options, the services it stands on and the observer that
  wakes it.

  The services are in the order they must start: the token table, the pull
  worker with its tasks, and last `Vagus.App.Boot`, which needs only the
  store and must be done before the controller's first pass.

  The App runtime looks at everything once an hour. What changes in the
  engine without a word is the observer's to find, by one listing; a
  resync asks the engine about every app.

  Options:

    * `:instance`
    * `:gates`, the conditions the app waits for before it is Ready. The
      default is none: `:dns_ready` belongs here once a controller writes
      it, and listed before that it would keep every app in `startup`.
    * `:facts`, overrides for `Vagus.App.Facts.read/1`. The facts are the
      controller's context, which its passes and the kind's admission in
      the store both read
    * `:engine`, options for every engine call (`:socket`): the
      backend's, the pull worker's, the observer's listing, and the app
      network made before a create. The observer's events are the one
      thing of the engine they do not reach: those come from the worker
      its `:events` names, by default the application's
    * `:context`, merged over the controller's context
    * `:boot_marker`, as `Vagus.App.Boot`'s `:marker`
    * `:resync`, and `:observer`, options for `Vagus.App.EngineObserver`
  """
  @spec wiring(keyword()) :: keyword()
  def wiring(opts \\ []) do
    instance = Keyword.get(opts, :instance, Vagus.Resource)
    engine = Keyword.get(opts, :engine, [])

    context =
      Map.merge(
        %{
          facts: Facts.read(Keyword.get(opts, :facts, [])),
          backends: %{Backend.Container => [engine: engine], Backend.Native => []},
          gates: Keyword.get(opts, :gates, []),
          api_ready: &Vagus.API.Listener.accepting?/0
        },
        Keyword.get(opts, :context, %{})
      )

    boot =
      [instance: instance] ++
        if(Keyword.has_key?(opts, :boot_marker), do: [marker: opts[:boot_marker]], else: [])

    [
      controllers: [
        {Controller,
         resync: Keyword.get(opts, :resync, :timer.hours(1)),
         max_in_flight_steps: @steps,
         context: context}
      ],
      services:
        [{AuthIndex, instance: instance}] ++
          Pulls.child_specs(instance: instance, engine: engine) ++ [Boot.child_spec(boot)],
      observers: [
        {EngineObserver,
         [controller: Controller, instance: instance, backend_opts: [engine: engine]] ++
           Keyword.get(opts, :observer, [])}
      ]
    ]
  end
end
