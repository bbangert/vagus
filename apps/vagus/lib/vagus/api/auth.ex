defmodule Vagus.API.Auth do
  @moduledoc """
  Token auth + caller resolution for the Supervisor-API emulator.

  Every request must carry a token — either `Authorization: Bearer <token>` or
  `X-Supervisor-Token: <token>` (bashio/add-ons use the latter). There are no
  exempt routes. The token is resolved to a **caller**, assigned on
  `conn.assigns.caller`, so add-on-facing endpoints can authorize:

    * the token `Vagus.API.Token` resolves (constant-time
      `Plug.Crypto.secure_compare/2`, checked first so Core's polling never
      touches the registry) → `:supervisor`;
    * a token registered in `Vagus.Addon.Registry` (a running add-on's
      per-start token) → `{:addon, identity}`;
    * otherwise a 401 error envelope, halted before dispatch.
  """

  @behaviour Plug

  import Plug.Conn

  alias Vagus.API.{Envelope, Token}
  alias Vagus.Addon.Registry

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case token(conn) do
      nil -> unauthorized(conn)
      token -> resolve(conn, token)
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        token

      _other ->
        case get_req_header(conn, "x-supervisor-token") do
          [token | _] -> token
          [] -> nil
        end
    end
  end

  defp resolve(conn, token) do
    cond do
      Plug.Crypto.secure_compare(token, Token.get()) ->
        assign(conn, :caller, :supervisor)

      match?({:ok, _}, addon_identity(token)) ->
        {:ok, identity} = addon_identity(token)
        assign(conn, :caller, {:addon, identity})

      true ->
        unauthorized(conn)
    end
  end

  # Registry may be absent in narrow test setups — treat as "no add-on tokens".
  defp addon_identity(token) do
    if Process.whereis(Registry), do: Registry.identity_for_token(token), else: :error
  end

  defp unauthorized(conn), do: Envelope.send_error(conn, "unauthorized", 401)
end
