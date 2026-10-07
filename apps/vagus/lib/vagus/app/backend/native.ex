defmodule Vagus.App.Backend.Native do
  @moduledoc """
  `Vagus.App.Backend` for an app that runs inside the VM: the MQTT broker,
  as a subtree under the supervisor that holds such apps. The instance is
  addressed by the app's slug.

  There is nothing to create and no image. `create/3` and `remove_image/2`
  do nothing, `image_present?/2` is always true, `start/2` starts the
  subtree and `stop/3` and `remove/2` both end it, so an instance is either
  `:absent` or `:running`: after `create/3` there is still no instance and
  no id. Its `id` names the subtree's process and so differs for every
  start.

  The subtree is a `:temporary` child. A crash inside the broker is
  supervision's to recover from: the broker's own supervisor restarts its
  children. The subtree itself ending is not: it stays down, is observed as
  `:absent`, and whether to start it again is the controller's decision,
  with its back-off. What ends a subtree abnormally is a kill, and a
  restart by the holding supervisor would then race the killed subtree's
  own children, which still hold their names and the port for a moment;
  each failed try counts, and enough of them end the supervisor every
  native app shares. That the subtree went is to be noticed at once by
  whoever monitors it and wakes the app, not waited for.

  `stop/3` ends the subtree through the holding supervisor. A `start/2`
  that follows a kill closely can fail for the reason above; it is an error
  like any other, and tried again.

  `start/2` of a running instance is `:ok`. When the name the subtree
  registers is held by a process the supervisor does not hold, nothing can
  be started under it and `start/2` is `{:error, {:other, {:name_taken,
  name}}}`.

  With the holding supervisor away, `observe/2` is `{:unavailable,
  :native_supervisor_down}`, `start/2` exits, and `stop/3` and `remove/2`
  exit when there is a subtree to end.

  The subtree registers the name the backend this one replaces uses for the
  same app, so the two cannot each run a broker on the port; one started by
  either is the instance both see. `stop/3` does not tell that backend's
  sentinel. For a broker the old backend started and still records as
  started, the sentinel reads this stop as a death and starts it again some
  seconds later, so only one of the two may be given an app to run.

  Options: `:supervisor` (default the application's), `:port` (default
  `config :vagus, :mqtt_broker_port`, else 1883) and `:provider`, the
  broker's service announcement (default on; `nil` for a broker that
  announces nothing).
  """

  @behaviour Vagus.App.Backend

  alias Vagus.Mqtt.Broker

  @supervisor Vagus.Addon.Backend.Native.Supervisor

  @impl true
  def observe(slug, opts \\ []) do
    case child(slug, opts) do
      {:ok, nil} -> {:ok, :absent}
      {:ok, pid} -> {:ok, instance(slug, pid)}
      :down -> {:unavailable, :native_supervisor_down}
    end
  end

  @impl true
  def image_present?(_image, _opts \\ []), do: {:ok, true}

  @impl true
  def create(_slug, _config, _opts \\ []), do: :ok

  @impl true
  def start(slug, opts \\ []) do
    spec =
      Supervisor.child_spec(
        {Broker,
         name: broker_name(slug),
         port: Keyword.get_lazy(opts, :port, &default_port/0),
         auth: [slug: slug],
         provider: Keyword.get(opts, :provider, slug: slug)},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(supervisor(opts), spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> running(slug, pid, opts)
      {:error, reason} -> {:error, {:other, reason}}
    end
  end

  # The name being taken says a process has it, not that the instance runs:
  # only a child of the supervisor is one `observe/2` will report, and a
  # start answered `:ok` for anything else would be asked for again forever.
  defp running(slug, pid, opts) do
    case child(slug, opts) do
      {:ok, ^pid} -> :ok
      _held_by_another -> {:error, {:other, {:name_taken, broker_name(slug)}}}
    end
  end

  @impl true
  def stop(slug, _grace, opts \\ []) do
    case registered(slug) do
      nil ->
        :ok

      pid ->
        # The supervisor decides: `:ok` once the subtree has ended, and
        # `{:error, :not_found}` for a pid that is not, or no longer, its
        # child, which is the same end state.
        _ = DynamicSupervisor.terminate_child(supervisor(opts), pid)
        :ok
    end
  end

  @impl true
  def remove(slug, opts \\ []), do: stop(slug, nil, opts)

  @impl true
  def remove_image(_image, _opts \\ []), do: :ok

  # Nothing here asks the engine for anything.
  @impl true
  def lane(_action), do: nil

  @doc """
  The name the broker's subtree registers. The same rule as
  `Vagus.Addon.Backend.Native.broker_name/1` for the id `addon_<slug>`:
  the readers of its logs and statistics look it up by that name, and a
  broker already started that way is this app's instance, not a second
  claimant of the port.
  """
  @spec broker_name(String.t()) :: atom()
  def broker_name(slug), do: Module.concat(Broker, "addon_" <> slug)

  # A name nothing was ever started under is not an atom yet, and asking
  # after it must not make it one: atoms are never collected.
  defp registered(slug) do
    Process.whereis(String.to_existing_atom("#{Broker}.addon_#{slug}"))
  rescue
    ArgumentError -> nil
  end

  # The registered name gives a pid; whether that pid is the running
  # instance is the supervisor's to say, so it is asked for its children.
  # An entry that is `:restarting` is no pid and so nobody's instance.
  defp child(slug, opts) do
    pid = registered(slug)

    children =
      for {_id, child, _type, _modules} <- DynamicSupervisor.which_children(supervisor(opts)),
          do: child

    {:ok, if(pid in children, do: pid)}
  catch
    :exit, _supervisor_absent -> :down
  end

  defp instance(slug, pid) do
    %{
      id: "native:#{slug}:#{:erlang.pid_to_list(pid)}",
      state: :running,
      exit_code: nil,
      started_at: nil,
      restart_count: 0,
      health: :none,
      health_failing_streak: 0,
      image: nil,
      image_id: nil,
      labels: %{},
      env: %{},
      address: nil,
      process: pid
    }
  end

  defp supervisor(opts), do: Keyword.get(opts, :supervisor, @supervisor)
  defp default_port, do: Application.get_env(:vagus, :mqtt_broker_port, 1883)
end
