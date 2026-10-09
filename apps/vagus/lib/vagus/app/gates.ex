defmodule Vagus.App.Gates do
  @moduledoc """
  The conditions boot waits on before it starts apps, each a check that
  answers `:ok` or why not. None has an event to subscribe to, so the
  orchestrator polls them.
  """

  require Logger

  alias Vagus.Network
  alias Vagus.Network.Nat

  @spec all() :: [{atom(), (-> :ok | {:error, term()})}]
  def all, do: [tree: &tree/0, engine: &engine/0, network: &network/0, api: &api/0]

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

  @doc "The engine starts only once the network reaches the internet."
  @spec engine() :: :ok | {:error, term()}
  def engine, do: Vagus.Runtime.Docker.ping()

  @doc """
  Stands up the `hassio` bridge, binds the `.2`/`.3` anchors and asserts the
  DNAT that serves port 80 on `.2`. All of it is lost on reboot, and only a
  container app's start would redo it otherwise, so a device running only
  native apps would leave Core unable to reach the Supervisor. Best effort:
  always `:ok`, so a failure here never holds the apps back.
  """
  @spec network() :: :ok
  def network do
    case Network.ensure() do
      {:ok, _id} ->
        Network.ensure_supervisor_ip()
        warn_unless_ok(Nat.ensure(), "supervisor DNAT; apps may not reach http://supervisor/")

      {:error, reason} ->
        warn_unless_ok(
          {:error, reason},
          "hassio bridge; Core and bridged apps may not reach the Supervisor"
        )
    end

    # The listener's bind address exists only from here, so its next bind
    # attempt is hurried. An optimisation only: the `api` gate still decides.
    Vagus.API.Listener.retry_now()
    :ok
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
