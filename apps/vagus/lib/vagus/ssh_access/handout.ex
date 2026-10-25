defmodule Vagus.SSHAccess.Handout do
  @moduledoc """
  Hands `Vagus.SSHAccess`'s private key out over plain, unauthenticated HTTP
  (`GET http://<board>:8891/key`), on the agent-dev-board flavor only. That
  flavor has no Core admin panel to serve the key through, and released
  images bake no operator keys, so without this nobody could log in.

  The key is offered from boot until an operator runs `drop/0` in the
  board's IEx; nothing closes it automatically. `drop/0` writes a latch file,
  and a latched device never opens the handout again.

  An unclaimed board keeps offering its key, and with it root, to anyone on
  the LAN until someone claims it. Accepted: the board is an expendable
  development appliance.
  """

  use Supervisor

  require Logger

  alias __MODULE__.Latch

  @default_port 8891
  @default_claimed_path "/data/vagus/ssh_handout.claimed"

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:vagus, :ssh_handout, []), opts)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Closes the handout for good: run it in IEx after logging in with the
  fetched key. Idempotent, and safe with no handout running.

  `{:error, reason}` means the latch could not be written: the key is still
  withheld for the rest of this boot, but the handout reopens on the next.
  """
  @spec drop(Supervisor.name()) :: :ok | {:error, term()}
  def drop(name \\ __MODULE__) do
    path = claimed_path(Application.get_env(:vagus, :ssh_handout, []))
    result = latch(path)

    # Set before the call, so the key stays withheld for this boot even if
    # the latch failed and the Server is mid-restart or gone.
    :persistent_term.put(closed_key(name), true)
    stop_server(name)
    result
  end

  # An existing latch is left untouched: `Latch.write/2` creates exclusively.
  defp latch(path) do
    case Latch.write(path, "#{DateTime.to_iso8601(DateTime.utc_now())}\n") do
      :ok ->
        :ok

      {:error, {:partial, reason}} ->
        Logger.error("SSH key handout: latched, but #{path} is incomplete (#{inspect(reason)})")
        :ok

      {:error, reason} = error ->
        Logger.error(
          "SSH key handout: could not write latch #{path} (#{inspect(reason)}), " <>
            "it will reopen next boot"
        )

        error
    end
  end

  defp stop_server(name) do
    GenServer.call(Module.concat(name, Server), :drop)
  catch
    # No Server: not running, already closed, or mid-restart, where the
    # replacement sees the flag and closes.
    :exit, _reason -> :ok
  end

  defp claimed_path(opts), do: Keyword.get(opts, :claimed_path, @default_claimed_path)

  # Boot-scoped closure that survives a latch write failure; see the Plug.
  defp closed_key(name), do: {__MODULE__, name, :closed}

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    port = Keyword.get(opts, :port, @default_port)
    claimed_path = claimed_path(opts)

    if Latch.present?(claimed_path) do
      Logger.info("SSH key handout not started: already claimed (#{claimed_path})")
      :ignore
    else
      listener_supervisor = Module.concat(name, ListenerSupervisor)

      plug =
        {__MODULE__.Plug,
         ssh_access: Keyword.get(opts, :ssh_access, Vagus.SSHAccess),
         claimed_path: claimed_path,
         closed_key: closed_key(name)}

      children = [
        {DynamicSupervisor, name: listener_supervisor, strategy: :one_for_one},
        {Vagus.API.Listener,
         name: Module.concat(name, Listener),
         listener_name: Module.concat(name, "Listener.Bandit"),
         supervisor: listener_supervisor,
         plug: plug,
         port: port,
         ip: Keyword.get(opts, :ip, {0, 0, 0, 0})},
        # Its clean stop closes the handout: `:any_significant` shuts this
        # supervisor, which is `:transient` so its parent leaves it down.
        Supervisor.child_spec(
          {__MODULE__.Server,
           name: Module.concat(name, Server),
           port: port,
           claimed_path: claimed_path,
           closed_key: closed_key(name)},
          restart: :transient,
          significant: true
        )
      ]

      # Each recovers alone: a replaced DynamicSupervisor is rebound by the
      # Listener's retry, a replaced Listener adopts the running Bandit.
      Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
    end
  end
end
