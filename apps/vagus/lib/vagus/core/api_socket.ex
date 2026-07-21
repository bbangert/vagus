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

  The socket path is `config :vagus, :core_api_socket` (a host path the Core
  container's socket dir is bind-mounted onto); `nil` means "no socket
  configured" and callers fall back to their TCP path.

  Transport mirrors `Vagus.Runtime.Docker`: one short-lived passive Mint
  connection per request, hard body cap, never raises.
  """

  @recv_timeout 30_000
  @max_body 1_048_576

  @doc "The configured Core API socket path, or `nil`."
  @spec path() :: String.t() | nil
  def path, do: Application.get_env(:vagus, :core_api_socket)

  @doc """
  POSTs `body` (a map → JSON) to `path` over the Core API socket. Returns
  `{:ok, status}` or `{:error, reason}`. `opts[:socket]` overrides the path.
  """
  @spec post(String.t(), map(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def post(request_path, body, opts \\ []) when is_map(body) do
    socket = Keyword.get(opts, :socket, path())
    payload = Jason.encode!(body)
    headers = [{"content-type", "application/json"}]

    case Mint.HTTP.connect(:http, {:local, socket}, 0, mode: :passive, hostname: "localhost") do
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
