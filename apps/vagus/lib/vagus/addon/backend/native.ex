defmodule Vagus.Addon.Backend.Native do
  @moduledoc """
  The `:native` `Vagus.Addon.Backend` (M5) — "virtual add-ons" that run as a
  supervised BEAM subtree instead of a container, presented to Home Assistant
  Core as ordinary add-ons behind the same behaviour `Container` implements.

  The native apps are the embedded mqttx broker (`Vagus.Mqtt.Broker`,
  `core_mqtt`), the admin panel (`Vagus.API.AdminPanel`, `vagus`, whose
  subtree is its log buffer alone: the panel itself is served in the API's
  request processes) and, on the agent flavor, the memory server
  (`Vagus.Memory`, `vagus_memory`). Each native add-on's subtree is started as a child of
  the app-level `Vagus.Addon.Backend.Native.Supervisor` (`DynamicSupervisor`)
  under a **deterministic registered name** derived from the add-on id
  (`subtree_name/1`), so `state/1`, `stop/2`, and `remove/2` re-derive the handle
  from the id alone — no pid table to keep. A BEAM subtree has no Docker
  `die` event, so the app's process monitors the subtree's root and revives
  it when OTP supervision gives up.

  `Vagus.App.Steps` builds the same runtime-neutral `Spec` for every backend;
  a native backend uses only `name` (→ id) and ignores the container-only
  fields. `create/1` returns `"addon_<slug>"`, the id the steps re-derive at
  stop and remove.
  """

  @behaviour Vagus.Addon.Backend

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.Backend.Spec
  alias Vagus.API.AdminPanel
  alias Vagus.Mqtt.Broker

  @impl Vagus.Addon.Backend
  def pull(%Spec{}), do: :ok

  @impl Vagus.Addon.Backend
  def create(%Spec{name: name}), do: {:ok, name}

  @impl Vagus.Addon.Backend
  def start(id) do
    slug = slug_from_id(id)

    case DynamicSupervisor.start_child(Native.Supervisor, child_spec(id, slug)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Vagus.Addon.Backend
  def stop(id, _opts \\ []) do
    case Process.whereis(subtree_name(id)) do
      nil ->
        :ok

      pid ->
        # :ok | {:error, :not_found} — both mean "the subtree is gone", which is
        # success for the idempotent stop/remove contract.
        _ = DynamicSupervisor.terminate_child(Native.Supervisor, pid)
        :ok
    end
  end

  @impl Vagus.Addon.Backend
  def remove(id, opts \\ []), do: stop(id, opts)

  @impl true
  # Native add-ons run in-VM; there is no image to reclaim.
  def remove_image(_image, _opts \\ []), do: :ok

  @impl Vagus.Addon.Backend
  def state(id) do
    case Process.whereis(subtree_name(id)) do
      pid when is_pid(pid) -> {:ok, :running}
      nil -> {:ok, :stopped}
    end
  end

  @doc "True if a native broker subtree is currently running for `id`."
  @spec running?(Vagus.Addon.Backend.id()) :: boolean()
  def running?(id), do: match?({:ok, :running}, state(id))

  @doc """
  Process-derived stats for a native add-on, in `Vagus.Runtime.Stats` shape
  (MQ-P3-T1): `memory_usage` is the summed memory of the app's subtree
  processes; cpu/network/block are best-effort zero (an in-BEAM app has no
  cgroup accounting). All-zeros when the app isn't running.
  """
  @spec stats(Vagus.Addon.Backend.id()) :: map()
  def stats(id) do
    case Process.whereis(subtree_name(id)) do
      pid when is_pid(pid) ->
        %{Vagus.Runtime.Stats.zero() | memory_usage: subtree_memory(id, pid)}

      nil ->
        Vagus.Runtime.Stats.zero()
    end
  end

  @doc """
  The native app's recent log lines (MQ-P3-T2), newest last. `opts[:lines]`
  bounds the count (default 100). `[]` when the app (hence its log buffer)
  isn't running, or keeps none.
  """
  @spec logs(Vagus.Addon.Backend.id(), keyword()) :: [String.t()]
  def logs(id, opts \\ []) do
    case logs_server(id) do
      pid when is_pid(pid) -> Native.Logs.tail(pid, Keyword.get(opts, :lines, 100))
      nil -> []
    end
  end

  @doc """
  The app's `Native.Logs` buffer process, or `nil` when it isn't running —
  the subscribe target for `/logs/follow`.
  """
  @spec logs_server(Vagus.Addon.Backend.id()) :: pid() | nil
  def logs_server("addon_vagus" = id), do: Process.whereis(subtree_name(id))

  # Same slug-derived id as broker_name/1; callers gate on running?/1 first.
  # sobelow_skip ["DOS.ModuleConcat"]
  def logs_server(id) do
    # "Logs" string segment matches how `Vagus.Mqtt.Broker` names the child.
    Process.whereis(Module.concat(broker_name(id), "Logs"))
  end

  @doc "The registered name of the broker subtree for a native add-on `id`."
  @spec broker_name(Vagus.Addon.Backend.id()) :: atom()
  # ids are app ids; only Core's own token can name an arbitrary slug here.
  # sobelow_skip ["DOS.ModuleConcat"]
  def broker_name(id), do: Module.concat(Broker, id)

  @doc "The registered name of the subtree a native add-on `id` runs."
  @spec subtree_name(Vagus.Addon.Backend.id()) :: atom()
  # Fixed id; the other clause delegates to broker_name/1.
  # sobelow_skip ["DOS.ModuleConcat"]
  def subtree_name("addon_vagus_memory" = id), do: Module.concat(Vagus.Memory, id)
  def subtree_name("addon_vagus"), do: AdminPanel.Logs
  def subtree_name(id), do: broker_name(id)

  @doc "The add-on slug embedded in a native id: addon_<slug> becomes <slug>."
  @spec slug_from_id(Vagus.Addon.Backend.id()) :: String.t()
  def slug_from_id("addon_" <> slug), do: slug
  def slug_from_id(id), do: id

  # `restart: :temporary` bounds the blast radius: the subtree's OWN supervisor
  # (`Vagus.Mqtt.Broker` 5/30, `Vagus.Memory`) absorbs transient child crashes, and if IT
  # exhausts its budget and terminates, the shared `Native.Supervisor` neither
  # restarts it nor counts it against its own budget — so one crash-looping
  # native app can't take its siblings down with it. The app's process then
  # sees the permanent death and revives it.
  defp child_spec("addon_vagus_memory" = id, _slug) do
    Supervisor.child_spec({Vagus.Memory, name: subtree_name(id)},
      id: subtree_name(id),
      restart: :temporary
    )
  end

  defp child_spec("addon_vagus" = id, _slug) do
    Supervisor.child_spec(
      {Native.Logs,
       name: subtree_name(id), events: [AdminPanel.log_event()], format: &AdminPanel.log_line/3},
      id: subtree_name(id),
      restart: :temporary
    )
  end

  defp child_spec(id, slug) do
    Supervisor.child_spec(
      {
        Broker,
        # Publish the mqtt service + discovery on start (MQ-P4-T1). Bare broker
        # instances (unit tests) omit this and stay isolated.
        name: broker_name(id), port: broker_port(), auth: [slug: slug], provider: [slug: slug]
      },
      id: broker_name(id),
      restart: :temporary
    )
  end

  # Fixed 1883 in production; overridable so hermetic tests bind a free port.
  defp broker_port, do: Application.get_env(:vagus, :mqtt_broker_port, 1883)

  # Sum `:memory` across the subtree's root and every process below it
  # (for the broker: Subscriptions, AuthCache, the ThousandIsland listener
  # tree + its live connections, the log buffer). Only recurses into
  # supervisors, since `which_children` on a worker is a call it does not
  # answer and crashes on; the panel's root is its worker.
  defp subtree_memory(id, root) do
    if(id == "addon_vagus", do: [root], else: [root | descendants(root)])
    |> Enum.reduce(0, fn pid, acc ->
      case Process.info(pid, :memory) do
        {:memory, bytes} -> acc + bytes
        nil -> acc
      end
    end)
  end

  defp descendants(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, :supervisor, _mods} when is_pid(pid) -> [pid | descendants(pid)]
      {_id, pid, :worker, _mods} when is_pid(pid) -> [pid]
      _ -> []
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
