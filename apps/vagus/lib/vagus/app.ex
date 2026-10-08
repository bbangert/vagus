defmodule Vagus.App do
  @moduledoc """
  The App kind as the application runs it: `wiring/1` is what
  `Vagus.Resource.Supervisor` is started with to have apps reconciled.
  """

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
    * `:facts`, overrides for `Vagus.App.Facts.read/1`
    * `:engine`, options for every engine call (`:socket`)
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
          gates: Keyword.get(opts, :gates, [])
        },
        Keyword.get(opts, :context, %{})
      )

    boot =
      [instance: instance] ++
        if(Keyword.has_key?(opts, :boot_marker), do: [marker: opts[:boot_marker]], else: [])

    [
      controllers: [
        {Controller, resync: Keyword.get(opts, :resync, :timer.hours(1)), context: context}
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
