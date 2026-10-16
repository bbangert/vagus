defmodule Vagus.App.Gates do
  @moduledoc """
  The conditions boot waits on before it starts apps, each a check that
  answers `:ok` or why not. None has an event to subscribe to, so the
  orchestrator polls them.
  """

  require Logger

  alias Vagus.Network
  alias Vagus.Network.Nat

  @spec all() :: %{atom() => (-> :ok | {:error, term()})}
  def all, do: %{tree: &tree/0, engine: &engine/0, network: &network/0, api: &api/0}

  @doc """
  The rest of the application tree is up. The app tree starts before DNS,
  the app watchdog, the API and Core's subtree, and an app start needs all
  of them.
  """
  @spec tree() :: :ok | {:error, :starting}
  def tree do
    if List.keymember?(Application.started_applications(), :vagus, 0),
      do: :ok,
      else: {:error, :starting}
  end

  @doc """
  The engine answers. Under Docker that waits for the internet as well:
  `Vagus.Engine.Manager` starts balena-engine only once the network reaches
  it. Under podman it is `Vagus.Runtime.Host`'s preparation alone, since only
  a pull needs the network.
  """
  @spec engine(keyword()) :: :ok | {:error, term()}
  def engine(opts \\ []), do: Vagus.Runtime.Engine.ready(opts)

  @doc """
  Stands up the `hassio` bridge, binds the `.2`/`.3` anchors and asserts the
  DNAT that serves port 80 on `.2`. All of it is lost on reboot, and only a
  container app's start would redo it otherwise, so a device running only
  native apps would leave Core unable to reach the Supervisor. Under podman
  the bridge is the host's own (`Vagus.Network.host_bridge?/1`), so the
  anchors and the DNAT go on even when the engine could not make its
  network. Best effort: always `:ok`, so a failure here never holds the apps
  back. `opts` reach every step (tests).
  """
  @spec network(keyword()) :: :ok
  def network(opts \\ []) do
    case Network.ensure(opts) do
      :ok ->
        anchors_and_nat(opts)

      {:error, reason} ->
        warn_unless_ok(
          {:error, reason},
          "hassio bridge; Core and bridged apps may not reach the Supervisor"
        )

        if Network.host_bridge?(opts), do: anchors_and_nat(opts)
    end

    # The listener's bind address exists only from here, so its next bind
    # attempt is hurried. An optimisation only: the `api` gate still decides.
    Vagus.API.Listener.retry_now()
    :ok
  end

  defp anchors_and_nat(opts) do
    Network.ensure_supervisor_ip(opts)
    warn_unless_ok(Nat.ensure(opts), "supervisor DNAT; apps may not reach http://supervisor/")
  end

  @doc """
  An app's s6 init asks `/addons/self/info` before its own service starts,
  and a refused connection there exits the container for good, so no app
  may start before the API accepts.
  """
  @spec api() :: :ok | {:error, :not_accepting}
  def api, do: if(Vagus.API.Listener.accepting?(), do: :ok, else: {:error, :not_accepting})

  defp warn_unless_ok(:ok, _what), do: :ok

  defp warn_unless_ok({:error, reason}, what),
    do: Logger.warning("Boot could not ensure the #{what} (#{inspect(reason)})")
end
