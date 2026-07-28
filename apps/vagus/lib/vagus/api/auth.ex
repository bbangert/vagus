defmodule Vagus.API.Auth do
  @moduledoc """
  Token auth + caller resolution for the Supervisor-API emulator.

  Every request must carry a token — either `Authorization: Bearer <token>` or
  `X-Supervisor-Token: <token>` (bashio/add-ons use the latter) — with one
  exception: the icon/logo GETs Core's proxy forwards with no `Authorization`
  header at all, which this module recognises itself via `unauthenticated?/1`.

  That decision is deliberately made HERE and nowhere else. An earlier
  revision had the router set a `conn.assigns[:auth_bypass]` flag that this
  module honored; assigns are a channel any plug can write, so trusting one
  at the auth boundary meant a future plug could disable authentication for
  any route by accident. There is now no flag to set.
  The token is resolved to a **caller**, assigned on `conn.assigns.caller`, so
  add-on-facing endpoints can authorize:

    * the token `Vagus.API.Token` resolves (constant-time
      `Plug.Crypto.secure_compare/2`, checked first so Core's polling never
      touches the registry) → `:supervisor`;
    * a token registered in `Vagus.Addon.Registry` (a running add-on's
      per-start token) → `{:addon, identity}`;
    * otherwise a 401 error envelope, halted before dispatch.
  """

  @behaviour Plug

  import Plug.Conn

  alias Vagus.Addon.Registry
  alias Vagus.API.{Envelope, Token}

  @impl Plug
  def init(opts), do: opts

  # Kinds served without a token. See `unauthenticated?/1`.
  @unauthenticated_asset_kinds ~w(icon logo)

  @impl Plug
  def call(conn, opts)

  def call(%Plug.Conn{} = conn, _opts) do
    if unauthenticated?(conn), do: conn, else: authenticate(conn)
  end

  @doc """
  Whether `conn` is one of the icon/logo GETs that must be served with no
  token at all.

  Computed here rather than read from an assign set by an earlier plug. An
  assign is a channel any plug in the pipeline could write, so trusting one
  at the auth boundary would mean a future plug could disable authentication
  for *any* route by accident. Nothing outside this module decides that a
  request skips auth.

  The exemption is forced, not chosen: Core's proxy forwards these GETs with
  no `Authorization` header at all (`homeassistant/components/hassio/http.py`
  — when `PATHS_NO_AUTH` matches, the branch short-circuits before the header
  is set, for admins too), and Supervisor skips its own middleware for them
  (`no_security_check` splices in `_V1_FRONTEND_PATHS`, i.e.
  `|/(store/)?addons/<RE_SLUG>/(logo|icon)`). Requiring a token here means
  permanently broken images, whatever the frontend does.

  Deliberately narrow: GET only, exact `path_info` segment match (never a
  regex over the raw path), and a slug that passes
  `Vagus.Addon.Config.valid_slug?/1`. Core itself 405s a non-GET on these
  paths, so the method restriction matches upstream rather than merely being
  cautious.
  """
  @spec unauthenticated?(Plug.Conn.t()) :: boolean()
  def unauthenticated?(%Plug.Conn{method: "GET", path_info: path_info}),
    do: asset_path?(path_info)

  def unauthenticated?(%Plug.Conn{}), do: false

  defp asset_path?(["addons", slug, kind]), do: asset?(kind, slug)
  defp asset_path?(["store", "addons", slug, kind]), do: asset?(kind, slug)
  defp asset_path?(_path_info), do: false

  defp asset?(kind, slug),
    do: kind in @unauthenticated_asset_kinds and Vagus.Addon.Config.valid_slug?(slug)

  defp authenticate(conn) do
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
