defmodule Vagus.SSHAccess.Handout.Plug do
  @moduledoc """
  `GET /key`: the SSH access private key, unauthenticated by design (see
  `Vagus.SSHAccess.Handout`).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Vagus.SSHAccess.Handout.Latch

  @impl true
  def init(opts) do
    %{
      ssh_access: Keyword.get(opts, :ssh_access, Vagus.SSHAccess),
      claimed_path: Keyword.fetch!(opts, :claimed_path),
      closed_key: Keyword.fetch!(opts, :closed_key)
    }
  end

  # `connection: close`: the listener's long keep-alive would otherwise let an
  # open connection fetch again while the closed handout drains. A request
  # already in flight when it closes is refused here instead.
  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["key"]} = conn, opts) do
    conn = put_resp_header(conn, "connection", "close")

    if closed?(opts), do: refuse(conn), else: send_key(conn, opts)
  end

  def call(%Plug.Conn{path_info: ["key"]} = conn, _opts) do
    conn
    |> put_resp_header("allow", "GET")
    |> send_resp(405, "")
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  defp closed?(opts) do
    :persistent_term.get(opts.closed_key, false) or Latch.present?(opts.claimed_path)
  end

  defp refuse(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(410, "handout closed\n")
  end

  defp send_key(conn, opts) do
    case Vagus.SSHAccess.private_key(opts.ssh_access) do
      {:ok, pem} ->
        # The call can wait out a closure, so check again before the key leaves.
        if closed?(opts) do
          refuse(conn)
        else
          Logger.warning("SSH access key fetched by #{:inet.ntoa(conn.remote_ip)}")

          conn
          |> put_resp_content_type("text/plain")
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(200, pem)
        end

      {:error, :unavailable} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "SSH access key unavailable\n")
    end
  end
end
