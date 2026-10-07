defmodule Vagus.App.Backend.Container do
  @moduledoc """
  `Vagus.App.Backend` for a container on the engine, addressed by container
  name.

  Options: `:client` (default `Vagus.Runtime.Docker`) and `:engine`, a
  keyword given to every call of it (`:socket`, `:recv_timeout`).
  """

  @behaviour Vagus.App.Backend

  alias Vagus.App.Backend
  alias Vagus.Runtime.{Docker, Events}

  # Past the grace the engine kills the container and waits about twelve
  # seconds more for it to be gone before it answers.
  @stop_margin_s 15

  @impl true
  def observe(name, opts \\ []) do
    case client(opts).inspect_container(name, engine(opts)) do
      {:ok, inspect} -> {:ok, project(inspect)}
      {:error, reason} -> unobserved(reason, {:ok, :absent})
    end
  end

  @impl true
  def image_present?(image, opts \\ []) do
    case client(opts).inspect_image(image, engine(opts)) do
      {:ok, _image} -> {:ok, true}
      {:error, reason} -> unobserved(reason, {:ok, false})
    end
  end

  @doc """
  The containers that are ours (`Vagus.Runtime.Events.managed?/2`), running
  or not, in one engine call: what a controller compares its resources with
  when it cannot trust the events it has seen.
  """
  @spec list(keyword()) ::
          {:ok, [Docker.summary()]} | Backend.unavailable() | Backend.error()
  def list(opts \\ []) do
    # The engine ANDs filter keys, and Core's container may carry no label
    # of ours, so only names can be asked for. They are matched again here:
    # an engine that ignores the filter answers with every container.
    names = ["^app_", "^addon_", "^#{Regex.escape(Vagus.Core.Container.name())}$"]

    case client(opts).list_containers([all: true, filters: %{name: names}] ++ engine(opts)) do
      {:ok, containers} ->
        {:ok,
         for(
           summary <- Enum.map(containers, &Docker.summary/1),
           Enum.any?(summary.names, &Events.managed?(&1, summary.labels)),
           do: summary
         )}

      {:error, reason} ->
        unobserved(reason, nil)
    end
  end

  @impl true
  def create(name, config, opts \\ []) when is_map(config) do
    case client(opts).create_container(config, [name: name] ++ engine(opts)) do
      {:ok, id} -> {:ok, id}
      {:error, {:create_failed, 409, _message}} -> {:error, :already_exists}
      {:error, reason} -> {:error, Docker.failure(reason)}
    end
  end

  @impl true
  def start(name, opts \\ []) do
    result(client(opts).start_container(name, [detail: true] ++ engine(opts)), [])
  end

  @impl true
  def stop(name, grace, opts \\ []) do
    # The engine answers when the container has exited, so the call has to
    # outwait the grace it asked for. Without one the engine's default
    # applies, well inside the client's.
    call =
      if grace,
        do: [timeout: grace, recv_timeout: :timer.seconds(grace + @stop_margin_s)],
        else: []

    result(client(opts).stop_container(name, [detail: true] ++ call ++ engine(opts)), [404])
  end

  @impl true
  def remove(name, opts \\ []) do
    result(client(opts).remove_container(name, [force: true] ++ engine(opts)), [])
  end

  @impl true
  def remove_image(image, opts \\ []) do
    result(client(opts).remove_image(image, engine(opts)), [])
  end

  @impl true
  def lane(_action), do: :engine

  @doc "An engine inspect map as a `t:Vagus.App.Backend.instance/0`."
  @spec project(map()) :: Backend.instance()
  def project(%{"Id" => id} = inspect) do
    state = inspect["State"] || %{}
    config = inspect["Config"] || %{}
    health = state["Health"] || %{}

    %{
      id: id,
      state: state(state),
      exit_code: state["ExitCode"],
      started_at: started_at(state["StartedAt"]),
      restart_count: inspect["RestartCount"] || 0,
      health: health(health["Status"]),
      health_failing_streak: health["FailingStreak"] || 0,
      image: config["Image"],
      image_id: inspect["Image"],
      labels: config["Labels"] || %{},
      env: env(config["Env"] || []),
      address: address(get_in(inspect, ["NetworkSettings", "Networks"]) || %{})
    }
  end

  # `Status` first: a container waiting out its restart back-off reports
  # `Running: true` as well.
  defp state(%{"Status" => "created"}), do: :created
  defp state(%{"Status" => "running"}), do: :running
  defp state(%{"Status" => "paused"}), do: :paused
  defp state(%{"Status" => "restarting"}), do: :restarting
  defp state(%{"Status" => "removing"}), do: :removing
  defp state(%{"Status" => "exited"}), do: :exited
  defp state(%{"Status" => "dead"}), do: :dead
  defp state(%{"Restarting" => true}), do: :restarting
  defp state(%{"Paused" => true}), do: :paused
  defp state(%{"Running" => true}), do: :running
  defp state(%{"Dead" => true}), do: :dead
  defp state(_stopped), do: :exited

  defp health("starting"), do: :starting
  defp health("healthy"), do: :healthy
  defp health("unhealthy"), do: :unhealthy
  defp health(_none), do: :none

  # The engine's zero time, which is what a container never started carries.
  defp started_at("0001-01-01T00:00:00Z"), do: nil
  defp started_at(at), do: at

  defp env(list) do
    Map.new(list, fn entry ->
      case String.split(entry, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  # The app network's address when the container is on it; otherwise the
  # first it has, which for the host network is none.
  defp address(networks) do
    ips =
      for {network, %{"IPAddress" => ip}} <- networks,
          is_binary(ip) and ip != "",
          do: {network, ip}

    ips = Enum.sort(ips)

    case List.keyfind(ips, Vagus.Network.name(), 0, List.first(ips)) do
      {_network, ip} -> ip
      nil -> nil
    end
  end

  defp unobserved(reason, missing) do
    case Docker.failure(reason) do
      {:unreachable, _reason} -> {:unavailable, :engine_unavailable}
      {:status, 404, _message} when missing != nil -> missing
      failure -> {:error, failure}
    end
  end

  defp result(:ok, _fine), do: :ok

  defp result({:error, reason}, fine) do
    case Docker.failure(reason) do
      {:status, status, _message} = failure ->
        if status in fine, do: :ok, else: {:error, failure}

      failure ->
        {:error, failure}
    end
  end

  defp client(opts), do: Keyword.get(opts, :client, Docker)
  defp engine(opts), do: Keyword.get(opts, :engine, [])
end
