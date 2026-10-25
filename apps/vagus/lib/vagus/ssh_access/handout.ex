defmodule Vagus.SSHAccess.Handout do
  @moduledoc """
  Hands `Vagus.SSHAccess`'s private key out over plain, unauthenticated HTTP
  (`GET http://<board>:8891/key`) for a short window after boot, on the
  agent-dev-board flavor only. That flavor has no Core admin panel to serve
  the key through, and released images bake no operator keys, so without
  this nobody could log in.

  Any successful SSH login, with any key and even after the window, writes a
  latch file, and a latched device never opens the handout again. A window
  that ends with nobody logged in writes nothing, so the next boot reopens
  it instead of stranding the board. The window's deadline is fixed when
  this supervisor starts, so a Server crash does not extend it.

  Anyone on the LAN during the window can take the key and with it root.
  Accepted: the board is an expendable development appliance.
  """

  use Supervisor

  require Logger

  alias __MODULE__.Latch

  @server __MODULE__.Server
  @default_port 8891
  @default_window_ms 300_000
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
  The daemon's `connectfun`, run in the SSH connection process after every
  successful authentication. It latches here rather than in the Server
  because the Server is gone once the window has elapsed, and a lookup
  before a cast cannot tell whether the cast will land. The latch is written
  before anything formats the attacker-chosen user name. Never raises: a
  failure only means the next boot reopens the handout.
  """
  @spec on_login(charlist(), term(), charlist(), GenServer.server()) :: :ok
  def on_login(user, peer, method, server \\ @server) do
    latch()
    GenServer.cast(server, {:login, who(user, peer, method)})
  catch
    kind, reason ->
      Logger.error("SSH key handout: login hook failed: #{Exception.format(kind, reason)}")
  end

  # Contains its own failures so the cast that closes the handout still runs.
  defp latch do
    path = claimed_path(Application.get_env(:vagus, :ssh_handout, []))

    unless Latch.present?(path) do
      case Latch.write(path, "#{DateTime.to_iso8601(DateTime.utc_now())}\n") do
        :ok ->
          :ok

        {:error, {:partial, reason}} ->
          Logger.error("SSH key handout: latched, but #{path} is incomplete (#{inspect(reason)})")

        {:error, reason} ->
          Logger.error(
            "SSH key handout: could not write latch #{path} (#{inspect(reason)}), " <>
              "it will reopen next boot"
          )
      end
    end
  catch
    kind, reason ->
      Logger.error(
        "SSH key handout: latch failed, it will reopen next boot: " <>
          Exception.format(kind, reason)
      )
  end

  defp who(user, peer, method), do: "#{inspect(user)} from #{peer_ip(peer)} (#{inspect(method)})"

  defp peer_ip({ip, _port}) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> inspect(ip)
      address -> List.to_string(address)
    end
  end

  defp peer_ip(peer), do: inspect(peer)

  defp claimed_path(opts), do: Keyword.get(opts, :claimed_path, @default_claimed_path)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    port = Keyword.get(opts, :port, @default_port)
    claimed_path = claimed_path(opts)
    closed_key = {__MODULE__, name, :closed}

    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :window_ms, @default_window_ms)

    if Latch.present?(claimed_path) do
      Logger.info("SSH key handout not started: already claimed (#{claimed_path})")
      :ignore
    else
      listener_supervisor = Module.concat(name, ListenerSupervisor)

      plug =
        {__MODULE__.Plug,
         ssh_access: Keyword.get(opts, :ssh_access, Vagus.SSHAccess),
         deadline: deadline,
         claimed_path: claimed_path,
         closed_key: closed_key}

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
           deadline: deadline,
           claimed_path: claimed_path,
           closed_key: closed_key},
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
