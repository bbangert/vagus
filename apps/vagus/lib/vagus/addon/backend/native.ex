defmodule Vagus.Addon.Backend.Native do
  @moduledoc """
  The `:native` `Vagus.Addon.Backend` (M5) — "virtual add-ons" that run as a
  supervised BEAM subtree instead of a container, presented to Home Assistant
  Core as ordinary add-ons behind the same behaviour `Container` implements.

  The only native add-on today is the embedded mqttx broker
  (`Vagus.Mqtt.Broker`). Each native add-on's subtree is started as a child of
  the app-level `Vagus.Addon.Backend.Native.Supervisor` (`DynamicSupervisor`)
  under a **deterministic registered name** derived from the add-on id
  (`broker_name/1`), so `state/1`, `stop/2`, and `remove/2` re-derive the handle
  from the id alone — no pid table to keep. `Vagus.Addon.Backend.Native.Sentinel`
  watches those subtrees so `Vagus.Addon.State` stays honest if OTP supervision
  exhausts its restart budget (the crash-restart half of `Vagus.Addon.Watchdog`
  never fires for a BEAM process — there is no Docker `die` event).

  The manager builds the same runtime-neutral `Spec` for every backend; a native
  backend uses only `name` (→ id) and ignores the container-only fields.
  `create/1` returns `"addon_<slug>"` to match the id the manager independently
  re-derives at stop/remove (`manager.ex`).
  """

  @behaviour Vagus.Addon.Backend

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.Backend.Spec
  alias Vagus.Mqtt.Broker

  @impl Vagus.Addon.Backend
  def pull(%Spec{}), do: :ok

  @impl Vagus.Addon.Backend
  def create(%Spec{name: name}), do: {:ok, name}

  @impl Vagus.Addon.Backend
  def start(id) do
    slug = slug_from_id(id)

    case DynamicSupervisor.start_child(Native.Supervisor, broker_child_spec(id, slug)) do
      {:ok, _pid} ->
        Native.Sentinel.watch(id)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Vagus.Addon.Backend
  def stop(id, _opts \\ []) do
    # Manual stop — the Sentinel must not then demote State for this id.
    Native.Sentinel.unwatch(id)

    case Process.whereis(broker_name(id)) do
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

  @impl Vagus.Addon.Backend
  def state(id) do
    case Process.whereis(broker_name(id)) do
      pid when is_pid(pid) -> {:ok, :running}
      nil -> {:ok, :stopped}
    end
  end

  @doc "The registered name of the broker subtree for a native add-on `id`."
  @spec broker_name(Vagus.Addon.Backend.id()) :: atom()
  def broker_name(id), do: Module.concat(Broker, id)

  @doc "The add-on slug embedded in a native id: addon_<slug> becomes <slug>."
  @spec slug_from_id(Vagus.Addon.Backend.id()) :: String.t()
  def slug_from_id("addon_" <> slug), do: slug
  def slug_from_id(id), do: id

  defp broker_child_spec(id, slug) do
    Supervisor.child_spec(
      {Broker, name: broker_name(id), port: broker_port(), auth: [slug: slug]},
      id: broker_name(id)
    )
  end

  # Fixed 1883 in production; overridable so hermetic tests bind a free port.
  defp broker_port, do: Application.get_env(:vagus, :mqtt_broker_port, 1883)
end
