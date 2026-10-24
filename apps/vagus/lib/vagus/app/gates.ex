defmodule Vagus.App.Gates do
  @moduledoc """
  The conditions boot waits on before it starts apps, each a check that
  answers `:ok` or why not. None has an event to subscribe to, so the
  orchestrator polls them.
  """

  require Logger

  alias Vagus.Network
  alias Vagus.Network.Nat

  @spec all() :: %{atom() => (-> :ok | {:error, term()} | {:fatal, term()})}
  def all,
    do: %{
      tree: &tree/0,
      patches: &patches/0,
      engine: &engine/0,
      network: &network/0,
      dist: &dist/0,
      api: &api/0,
      primary: &primary/0
    }

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

  # After `:tree` so `Vagus` is started, and before `stage: :native` so
  # patched modules are in place before any app runs; in the agent plan only,
  # since the stock appliance never hot-patches. A failed patch is that
  # patch's result, never the boot's. Not a required gate: a stuck load is
  # logged and the boot carries on.
  @spec patches(keyword()) :: :ok | {:error, term()}
  def patches(opts \\ []) do
    # Both calls fit the orchestrator's 10 s gate bound, so its kill never
    # lands mid-call.
    opts = Keyword.put_new(opts, :timeout, 4_000)

    with {:ok, _started_or_skipped} <- Vagus.Patches.boot_load(opts) do
      case Vagus.Patches.boot_status(opts) do
        {:done, _results} -> :ok
        {:skipped, _reason} -> :ok
        {:error, reason} -> {:error, reason}
        _running -> {:error, :loading}
      end
    end
  end

  @doc """
  The engine answers: on a board, `Vagus.Runtime.Host`'s preparation is
  done. No wait for the internet, since only a pull needs the network.
  """
  @spec engine(keyword()) :: :ok | {:error, term()}
  def engine(opts \\ []), do: Vagus.Runtime.Engine.ready(opts)

  @doc """
  Stands up the `hassio` bridge, binds the `.2`/`.3` anchors and loads
  `Vagus.Network.Nat`'s table. All of it is lost on reboot, and only a
  container app's start would redo it otherwise, so a device running only
  native apps would leave Core unable to reach the Supervisor. On a board
  Vagus makes the bridge interface itself (`Vagus.Network.host_bridge?/1`),
  so the anchors have it whatever podman answered. Each step runs whatever
  the one before returned, and the gate is always `:ok`, so Core and
  host-network apps are never held back here. A table that did not load
  keeps bridged apps from starting instead (`Vagus.Network.Nat.ensure_loaded/1`
  in their start, which retries the load). `opts` reach every step (tests).
  """
  @spec network(keyword()) :: :ok
  def network(opts \\ []) do
    warn_unless_ok(
      Network.ensure(opts),
      "hassio bridge; Core and bridged apps may not reach the Supervisor"
    )

    Network.ensure_supervisor_ip(opts)

    warn_unless_ok(
      Nat.ensure(opts),
      "supervisor DNAT, bridge filters and forwarding; bridged apps will not start until they are in place"
    )

    # The listener's bind address exists only from here, so its next bind
    # attempt is hurried. An optimisation only: the `api` gate still decides.
    Vagus.API.Listener.retry_now()
    :ok
  end

  @doc """
  Starts distribution and exports the session (`Vagus.Dist.enable/1`,
  `Vagus.Dist.export/2`); the agent-dev-board flavor's only, where the
  orchestrator app is useless without it. A bring-up still running
  (`:starting`) and a LAN lease not yet there (`:no_address`) are retried,
  as is an exit; a raise, a throw or any other failure is `{:fatal, reason}`
  and halts the boot, since `Vagus.Dist` wants a reboot rather than a retry
  after a failed bring-up. Running out of tries halts it too
  (`Vagus.App.Orchestrator`).

  The bring-up runs in its own process and `enable/1` answers within its
  `:wait_ms`, under `gate_timeout`, so the kill that bounds a gate never
  lands inside it. `opts`: `:enable`, `:dir` and `:gid` (tests).
  """
  @spec dist(keyword()) ::
          :ok | {:error, :starting | :no_address | {:exit, term()}} | {:fatal, term()}
  def dist(opts \\ []) do
    enable = Keyword.get(opts, :enable, &Vagus.Dist.enable/0)

    with {:ok, session} <- enable.(),
         :ok <- Vagus.Dist.export(session, Keyword.take(opts, [:dir, :gid])) do
      :ok
    else
      {:error, reason} when reason in [:starting, :no_address] -> {:error, reason}
      {:error, reason} -> {:fatal, reason}
    end
  catch
    # A transient race, such as a table or supervisor mid-restart.
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:fatal, {kind, reason}}
  end

  @doc """
  The host has a primary interface, exactly as `GET /network/info` shows it
  to apps: some apps read it once at start and exit for good without one
  (Matter Server: "No primary network interface found"). Not a gate of the
  boot sequence, which must not hold Core: the orchestrator holds only the
  app stages on it (`Vagus.App.Orchestrator`).
  """
  @spec primary() :: :ok | {:error, :no_primary}
  def primary do
    if Enum.any?(Vagus.Backend.network().info().interfaces, & &1.primary),
      do: :ok,
      else: {:error, :no_primary}
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
