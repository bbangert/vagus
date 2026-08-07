defmodule Vagus.Core.ApiSocket do
  @moduledoc """
  Minimal HTTP/1 client for Home Assistant Core's **Supervisor unix socket**
  (Mint over `{:local, socket}`), the channel real HAOS uses for
  Supervisor→Core calls.

  Core opens this socket when started with `SUPERVISOR_CORE_API_SOCKET=<path>`
  and, per `homeassistant/components/http/auth.py`, treats every request that
  arrives on it as the **Supervisor user** — so no bearer token is needed and
  the caller-IP check in `api/hassio_auth` (`_check_access`) is bypassed. That
  IP check is why a TCP call from the host-networked emulator (source = the LAN
  IP, not `172.30.32.2`) is rejected; the socket sidesteps it entirely.

  The socket is the shared one `Vagus.Core.Transport` resolves
  (`Vagus.Core.Container.socket_path/0`, bind-mounted into both mount
  namespaces by Core's own run spec); `path/0` is `nil` when it doesn't
  exist right now and callers fall back to their TCP path.

  This is the no-Finch half of the transport: `Vagus.Core.Client` and
  friends ride the same socket through a Finch pool, but this one call runs
  before/independently of that machinery, so it keeps its own short-lived
  connection. Transport mirrors `Vagus.Runtime.Docker`: one short-lived
  passive Mint connection per request, hard body cap, never raises.
  """

  alias Vagus.Core.Transport

  @recv_timeout 30_000
  @max_body 1_048_576

  @doc "The Core API socket path if the socket exists right now, or `nil`."
  @spec path() :: String.t() | nil
  def path, do: Transport.socket()

  @doc """
  POSTs `body` (a map → JSON) to `path` over the Core API socket. Returns
  `{:ok, status}` or `{:error, reason}`.

  `opts[:socket]` is the resolved socket path — callers that already
  branched on `path/0` pass it so this call can't re-resolve to something
  else (or to nothing) mid-request. Without it the path is resolved here,
  and a resolution that comes back empty is `{:error, :no_socket}`: a
  `nil` would otherwise reach `Mint.HTTP.connect(:http, {:local, nil}, 0)`,
  which raises — this module never does.
  """
  @spec post(String.t(), map(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def post(request_path, body, opts \\ []) when is_map(body) do
    case Keyword.get(opts, :socket, path()) do
      socket when is_binary(socket) -> do_post(request_path, body, socket)
      _no_socket -> {:error, :no_socket}
    end
  end

  defp do_post(request_path, body, socket) do
    payload = Jason.encode!(body)
    headers = [{"content-type", "application/json"}]
    {scheme, address, port} = Transport.connect_args({:socket, socket})
    connect_opts = [mode: :passive] ++ Transport.connect_opts({:socket, socket})

    case Mint.HTTP.connect(scheme, address, port, connect_opts) do
      {:ok, conn} ->
        try do
          with {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", request_path, headers, payload),
               {:ok, status} <- recv_status(conn, ref) do
            {:ok, status}
          else
            {:error, _conn, reason} -> {:error, reason}
            {:error, reason} -> {:error, reason}
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  # Drain the response, capping total data, and return the status line's code.
  defp recv_status(conn, ref, status \\ nil, size \\ 0) do
    case Mint.HTTP.recv(conn, 0, @recv_timeout) do
      {:ok, conn, responses} ->
        status =
          Enum.find_value(responses, status, fn
            {:status, ^ref, s} -> s
            _ -> nil
          end)

        size = size + data_size(responses)

        cond do
          size > @max_body -> {:error, :response_too_large}
          Enum.any?(responses, &match?({:done, ^ref}, &1)) -> {:ok, status}
          true -> recv_status(conn, ref, status, size)
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end

  defp data_size(responses) do
    Enum.reduce(responses, 0, fn
      {:data, _ref, chunk}, acc -> acc + byte_size(chunk)
      _other, acc -> acc
    end)
  end
end
