defmodule Vagus.App.Backend.Native do
  @moduledoc """
  `Vagus.App.Backend` for an app that runs inside the VM: the MQTT broker,
  as a subtree under the supervisor that holds such apps. The instance is
  addressed by the app's slug.

  There is nothing to create and no image. `create/3` and `remove_image/2`
  do nothing, `image_present?/2` is always true, `start/2` starts the
  subtree and `stop/3` and `remove/2` both end it, so an instance is either
  `:absent` or `:running`. Its `id` names the subtree's process and so
  differs for every start.

  The subtree is a `:temporary` child: the broker's own supervisor absorbs
  its children's crashes, and one that gives up stays down and is observed
  as `:absent`. Whether to start it again is the controller's decision.

  With the holding supervisor away, `observe/2` is `{:unavailable,
  :native_supervisor_down}` and the actions exit.

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
  def create(slug, _config, _opts \\ []), do: {:ok, slug}

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
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:other, reason}}
    end
  end

  @impl true
  def stop(slug, _grace, opts \\ []) do
    case Process.whereis(broker_name(slug)) do
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

  # The registered name gives a pid; whether that pid is the running
  # instance is the supervisor's to say, so it is asked for its children.
  defp child(slug, opts) do
    pid = Process.whereis(broker_name(slug))

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
      address: nil
    }
  end

  defp supervisor(opts), do: Keyword.get(opts, :supervisor, @supervisor)
  defp default_port, do: Application.get_env(:vagus, :mqtt_broker_port, 1883)
end
