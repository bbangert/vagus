defmodule Vagus.API.Refusal do
  @moduledoc """
  What a refused caller is told.

  `Vagus.API.Authz`'s table and a route's own guard in `Vagus.API.Router`
  refuse the same requests, and a caller must not be able to tell which of
  them did. Both take the status and the message from here, so neither can
  drift from the other.
  """

  @type kind ::
          :forbidden
          | :not_core
          | :not_this_app
          | :self_only
          | :no_auth_api
          | :service
          | :not_found

  @type t :: {401 | 403 | 404, String.t()}

  @kinds ~w(forbidden not_core not_this_app self_only no_auth_api service not_found)a

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  `subject` is the decoded path segment a `:service` refusal names; the other
  kinds ignore it.
  """
  @spec answer(kind(), method :: String.t(), subject :: String.t() | nil) :: t()
  def answer(:forbidden, _method, _subject), do: {403, "unauthorized"}
  # Upstream's `require_home_assistant` raises `HTTPUnauthorized`.
  def answer(:not_core, _method, _subject), do: {401, "unauthorized"}
  def answer(:not_this_app, _method, _subject), do: {403, "Not authorized for this add-on"}
  def answer(:self_only, _method, _subject), do: {403, "This can be only read by the app itself!"}

  def answer(:no_auth_api, _method, _subject),
    do: {403, "Caller is not allowed to access the auth API"}

  def answer(:not_found, _method, _subject), do: {404, "not found"}

  def answer(:service, method, service) when is_binary(service) do
    # A segment that is not UTF-8 cannot be encoded as JSON, and the envelope
    # would raise instead of refusing.
    named = if String.valid?(service), do: "'#{service}'", else: "this service"

    case method do
      "POST" -> {403, "Caller may not provide #{named}"}
      "DELETE" -> {403, "Caller may not delete #{named}"}
      _read -> {403, "Caller not authorized for #{named}"}
    end
  end
end
