defmodule Vagus.DNS.TCP do
  @moduledoc """
  DNS over TCP for `Vagus.DNS` (RFC 7766): what a client asks again after a
  truncated UDP reply.

  Three kinds of process, each for a runtime reason:

    * `Vagus.DNS` owns the listening socket, admits each connection against
      its cap and counts it, as it does its UDP relays;
    * one acceptor, linked to it, because `accept` blocks and the server
      must keep answering UDP meanwhile; it dies with the listening socket's
      owner, and its crash takes that owner down for its supervisor to
      restart with a fresh socket;
    * one task per connection under the relays' task supervisor, so one
      slow client or upstream holds up no other; it owns its socket, which
      closes with it.

  Every message is framed by its 2-byte length (`packet: 2`), so a read
  never holds more than one frame of at most 65 535 bytes, and a frame that
  does not arrive whole within the idle timeout ends the connection. Each
  query is answered before the next is read.
  """

  alias Vagus.DNS

  # RFC 7766 §6.2.3 asks for an idle timeout of seconds, not minutes.
  @idle_ms 10_000
  @opts [:binary, packet: 2, active: false]

  @doc "How long a connection may sit without a whole frame."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: @idle_ms

  @spec listen(:inet.ip4_address(), :inet.port_number()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def listen(ip, port), do: :gen_tcp.listen(port, @opts ++ [ip: ip, reuseaddr: true])

  @doc """
  Starts the acceptor, linked to the caller. It hands each connection to
  `server` as `{:tcp_accepted, socket}`, owned by `server`.
  """
  @spec start_acceptor(:gen_tcp.socket(), pid()) :: {:ok, pid()}
  def start_acceptor(listen, server), do: Task.start_link(fn -> accept(listen, server) end)

  # `:closed` is the owner closing its socket: the acceptor's work is over.
  defp accept(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :ok = :gen_tcp.controlling_process(sock, server)
        send(server, {:tcp_accepted, sock})
        accept(listen, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept, reason})
    end
  end

  @doc """
  A connection's task: waits for its socket, then answers frame by frame.
  `conn` carries the zone, the upstreams in the order the server chose at
  admission, and where to report the one that answered.
  """
  @spec serve(map()) :: :ok
  def serve(conn) do
    receive do
      {:socket, sock} ->
        try do
          loop(sock, conn)
        after
          :gen_tcp.close(sock)
        end
    after
      conn.idle_ms -> :ok
    end
  end

  defp loop(sock, conn) do
    with {:ok, packet} <- :gen_tcp.recv(sock, 0, conn.idle_ms) do
      case answer(packet, conn) do
        nil -> loop(sock, conn)
        resp -> with :ok <- :gen_tcp.send(sock, resp), do: loop(sock, conn)
      end
    end

    :ok
  end

  # Unanswered, the client times out and asks again, as over UDP.
  defp answer(packet, conn) do
    case DNS.local_answer(packet, conn) do
      {:answer, resp} ->
        resp

      {:forward, nxdomain} when conn.upstreams == [] ->
        nxdomain

      {:forward, _nxdomain} ->
        case ask(conn.upstreams, conn.upstreams, packet, conn.upstream_port, DNS.deadline()) do
          {:ok, ip, resp} ->
            DNS.answered(conn.server, conn.upstreams, ip)
            resp

          :error ->
            nil
        end
    end
  end

  defp ask(_all, [], _packet, _port, _deadline), do: :error

  defp ask(all, [upstream | rest] = untried, packet, port, deadline) do
    wait = DNS.slice(deadline, length(untried))

    case wait > 0 && ask_one(upstream, port, packet, wait) do
      {:ok, resp} -> {:ok, upstream, resp}
      false -> :error
      _failed -> ask(all, rest, packet, port, deadline)
    end
  end

  # The connect and the answer share the server's slice.
  defp ask_one(upstream, port, packet, wait) do
    until = System.monotonic_time(:millisecond) + wait

    with {:ok, sock} <- :gen_tcp.connect(upstream, port, @opts, wait) do
      try do
        left = max(until - System.monotonic_time(:millisecond), 0)
        with :ok <- :gen_tcp.send(sock, packet), do: :gen_tcp.recv(sock, 0, left)
      after
        :gen_tcp.close(sock)
      end
    end
  end
end
