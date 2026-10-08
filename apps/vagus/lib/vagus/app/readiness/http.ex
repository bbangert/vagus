defmodule Vagus.App.Readiness.Http do
  @moduledoc """
  `Vagus.App.Readiness` asked over the network: a TCP connect for a `tcp`
  target, otherwise one `GET` on a connection of its own, answered by any
  status below 300. Certificates are not verified: an app's own is usually
  self-signed, and the question is whether anything answers.

  `timeout` bounds the whole exchange, connect included.
  """

  @behaviour Vagus.App.Readiness

  @impl true
  def probe(%{proto: "tcp", host: host, port: port}, timeout) do
    case :gen_tcp.connect(String.to_charlist(host), port, [active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        :error
    end
  end

  def probe(%{proto: proto, host: host, port: port, path: path}, timeout)
      when proto in ["http", "https"] do
    deadline = System.monotonic_time(:millisecond) + timeout

    case get(String.to_existing_atom(proto), host, port, path, deadline) do
      {:ok, status} when status < 300 -> :ok
      _other -> :error
    end
  rescue
    # A host that is no host, or anything else the client raises on: nothing
    # answered.
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  def probe(_target, _timeout), do: :error

  defp get(scheme, host, port, path, deadline) do
    with {:ok, left} <- left(deadline),
         {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, connect_opts(scheme, left)) do
      try do
        with {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, [], ""),
             do: status(conn, ref, deadline)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp connect_opts(:https, timeout),
    do: [mode: :passive, timeout: timeout, transport_opts: [verify: :verify_none]]

  defp connect_opts(:http, timeout), do: [mode: :passive, timeout: timeout]

  defp status(conn, ref, deadline) do
    with {:ok, left} <- left(deadline),
         {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, left) do
      case List.keyfind(responses, :status, 0) do
        {:status, ^ref, status} -> {:ok, status}
        _not_yet -> status(conn, ref, deadline)
      end
    else
      _gave_up -> :error
    end
  end

  defp left(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      ms when ms > 0 -> {:ok, ms}
      _none -> :error
    end
  end
end
