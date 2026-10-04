defmodule Vagus.Resubscribe do
  @moduledoc """
  Keeps a subscription to a sibling server alive across that server's
  restarts.

  `Vagus.Runtime.Events` and `Vagus.Core.TokenStore` hold their subscriber
  sets in memory, so a restart of either silently drops every subscription
  — and the watchdogs that subscribed in their own `init/1` live in other
  subtrees, so nothing restarts *them* to subscribe again. A subscriber
  therefore monitors the server it subscribed to (`subscribe/2`) and, when
  that monitor fires, retries (`down/2` + `retry/3`) until the
  name-registered server is back.

  Only a subscription that once succeeded is retried, and only against a
  registered name: a server that was never running (a unit test without
  one, `:events_enabled` off) stays the documented "idle" case, and a dead
  pid can never come back.
  """

  @retry_ms 1_000

  @doc """
  Subscribes the calling process via `subscribe_fun.(server)` and monitors
  `server`. Returns the monitor ref, or `nil` when the server isn't running
  or the subscribe call exited.
  """
  @spec subscribe(GenServer.server(), (GenServer.server() -> term())) :: reference() | nil
  def subscribe(server, subscribe_fun) do
    case whereis(server) do
      pid when is_pid(pid) ->
        # Monitor first so a death between the two calls still reaches us.
        ref = Process.monitor(pid)

        try do
          subscribe_fun.(server)
          ref
        catch
          :exit, _reason ->
            Process.demonitor(ref, [:flush])
            nil
        end

      nil ->
        nil
    end
  end

  @doc """
  The subscribed server went down: arm a `msg` retry if it is
  name-registered (and so can come back). Returns `nil`, the new ref.
  """
  @spec down(GenServer.server(), term()) :: nil
  def down(server, msg) do
    if is_atom(server), do: Process.send_after(self(), msg, @retry_ms)
    nil
  end

  @doc """
  Handles the `msg` retry armed by `down/2`: subscribes again, re-arming
  the retry while the server is still away. Returns the new monitor ref
  (`nil` while still retrying).
  """
  @spec retry(GenServer.server(), (GenServer.server() -> term()), term()) :: reference() | nil
  def retry(server, subscribe_fun, msg) do
    case subscribe(server, subscribe_fun) do
      nil -> down(server, msg)
      ref -> ref
    end
  end

  defp whereis(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp whereis(name) when is_atom(name), do: Process.whereis(name)
  defp whereis(_other), do: nil
end
