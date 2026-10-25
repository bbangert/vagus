defmodule Vagus.SSHAccess.Handout.Plug do
  @moduledoc """
  `GET /key`: the SSH access private key, unauthenticated by design (see
  `Vagus.SSHAccess.Handout`).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: Keyword.get(opts, :ssh_access, Vagus.SSHAccess)

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["key"]} = conn, ssh_access) do
    case Vagus.SSHAccess.private_key(ssh_access) do
      {:ok, pem} ->
        Logger.warning("SSH access key fetched by #{:inet.ntoa(conn.remote_ip)}")

        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, pem)

      {:error, :unavailable} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "SSH access key unavailable\n")
    end
  end

  def call(%Plug.Conn{path_info: ["key"]} = conn, _ssh_access) do
    conn
    |> put_resp_header("allow", "GET")
    |> send_resp(405, "")
  end

  def call(conn, _ssh_access), do: send_resp(conn, 404, "")
end
