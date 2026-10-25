defmodule Vagus.SSHAccess.Handout do
  @moduledoc """
  Hands `Vagus.SSHAccess`'s private key out over plain, unauthenticated HTTP
  (`GET http://<board>:8891/key`) for a short window after boot, on the
  agent-dev-board flavor only. That flavor has no Core admin panel to serve
  the key through, and released images bake no operator keys, so without
  this nobody could log in.

  Any successful SSH login (any key; nerves_ssh calls `on_login/3` as the
  daemon's `connectfun`) writes a latch file and closes the handout if it is
  open, and a latched device never opens it again. That holds for a login
  after the window too: it still latches, so the next boot stays shut. A
  window that ends with nobody logged in writes nothing, so the next boot
  reopens it instead of stranding the board.

  Anyone on the LAN during the window can take the key and with it root.
  Accepted: the board is an expendable development appliance.

  Closing is the tree's job: the Server is a significant `:transient` child
  under `auto_shutdown: :any_significant`, so its clean stop shuts this
  supervisor and the listener down, and this supervisor is `:transient`
  itself so its parent does not reopen it. A crash restarts and re-arms a
  full window. Running out of restart intensity also exits `:shutdown`,
  which closes the handout for the rest of that boot.
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
  before a cast cannot tell whether the cast will land. Never raises: a
  failure only means the next boot reopens the handout.
  """
  @spec on_login(charlist(), term(), charlist(), GenServer.server()) :: :ok
  def on_login(user, peer, method, server \\ @server) do
    who = "#{user} from #{peer_ip(peer)} (#{method})"
    latch(who)
    GenServer.cast(server, {:login, who})
  catch
    kind, reason -> log_crash(kind, reason)
  end

  defp latch(who) do
    path = claimed_path(Application.get_env(:vagus, :ssh_handout, []))

    unless Latch.present?(path) do
      case Latch.write(path, "#{DateTime.to_iso8601(DateTime.utc_now())} #{who}\n") do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "SSH key handout: could not write latch #{path} (#{inspect(reason)}), " <>
              "it will reopen next boot"
          )
      end
    end

    :ok
  catch
    kind, reason -> log_crash(kind, reason)
  end

  defp log_crash(kind, reason) do
    Logger.error("SSH key handout: login hook failed: #{Exception.format(kind, reason)}")
  end

  defp claimed_path(opts), do: Keyword.get(opts, :claimed_path, @default_claimed_path)

  # `:ssh` passes `{ip, port}`.
  defp peer_ip({ip, _port}) when is_tuple(ip), do: :inet.ntoa(ip)
  defp peer_ip(peer), do: inspect(peer)

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
      plug = {__MODULE__.Plug, ssh_access: Keyword.get(opts, :ssh_access, Vagus.SSHAccess)}

      children = [
        {DynamicSupervisor, name: listener_supervisor, strategy: :one_for_one},
        {Vagus.API.Listener,
         name: Module.concat(name, Listener),
         listener_name: Module.concat(name, "Listener.Bandit"),
         supervisor: listener_supervisor,
         plug: plug,
         port: port,
         ip: Keyword.get(opts, :ip, {0, 0, 0, 0})},
        Supervisor.child_spec(
          {__MODULE__.Server,
           name: Module.concat(name, Server),
           port: port,
           window_ms: Keyword.get(opts, :window_ms, @default_window_ms)},
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
