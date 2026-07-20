defmodule Vagus.API.Auth do
  @moduledoc """
  Bearer-token auth plug for the Supervisor-API emulator.

  Every request must carry `Authorization: Bearer <token>` matching the
  token `Vagus.API.Token` resolves — there are no exempt routes. The
  comparison uses `Plug.Crypto.secure_compare/2` (constant-time) to avoid
  leaking the token's value via response-timing side channels. On any
  failure (missing header, malformed header, wrong token) the conn gets a
  401 error envelope and is halted before reaching the router's dispatch.
  """

  @behaviour Plug

  import Plug.Conn

  alias Vagus.API.{Envelope, Token}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if Plug.Crypto.secure_compare(token, Token.get()) do
          conn
        else
          unauthorized(conn)
        end

      _other ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn), do: Envelope.send_error(conn, "unauthorized", 401)
end
