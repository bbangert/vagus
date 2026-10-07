defmodule Vagus.Resource.Controllers.Supervisor do
  @moduledoc """
  One subtree per controller: its `Vagus.Resource.Runtime` and the
  `Task.Supervisor` its steps run under.

  `:one_for_one` between controllers: a runtime that dies is replaced with
  its task supervisor and no other controller notices. Five such deaths in
  thirty seconds end that controller's subtree, which this supervisor
  restarts; five of those in thirty seconds end this supervisor, and every
  controller with it, and the failure goes to `Vagus.Resource.Supervisor`.
  A controller's own code cannot bring a runtime down, since all of it runs
  in step tasks, so each of these is a defect in the runtime itself.

  There is no process per resource and nothing is started later: the
  children are the configured controllers.
  """

  use Supervisor

  alias Vagus.Resource.Runtime

  @doc """
  Options: `:instance`, `:controllers` (their
  `t:Vagus.Resource.Controller.declaration/0`s), and `:runtime`, options
  given to every runtime.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: name(Keyword.fetch!(opts, :instance)))
  end

  @spec name(atom()) :: atom()
  def name(instance), do: Module.concat(instance, Controllers)

  @doc "The name of one controller's subtree."
  @spec pair(atom(), module()) :: atom()
  def pair(instance, controller), do: Module.concat([instance, Controllers, controller])

  @impl true
  def init(opts) do
    instance = Keyword.fetch!(opts, :instance)
    runtime = Keyword.get(opts, :runtime, [])

    children =
      for %{controller: controller} = declaration <- Keyword.get(opts, :controllers, []) do
        tasks = Runtime.tasks(instance, controller)

        pair = [
          # No `:max_children`: the runtime starts one step per resource of
          # the kind at most.
          {Task.Supervisor, name: tasks},
          {Runtime, [instance: instance, declaration: declaration, tasks: tasks] ++ runtime}
        ]

        # `:one_for_all` because a step is an `async_nolink` task, and such a
        # task outlives the runtime that started it. Replaced alone, the new
        # runtime knows nothing of a step still running and starts a second
        # one for the same resource: two actions on one container at once.
        # Stopping the task supervisor with the runtime ends the orphan.
        options = [
          strategy: :one_for_all,
          name: pair(instance, controller),
          max_restarts: 5,
          max_seconds: 30
        ]

        # `:infinity` as for any supervisor: killed after a timeout, the pair
        # would leave its task supervisor, and the steps under it, running.
        %{
          id: controller,
          type: :supervisor,
          shutdown: :infinity,
          start: {Supervisor, :start_link, [pair, options]}
        }
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end
end
