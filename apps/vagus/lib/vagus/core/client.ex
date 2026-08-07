defmodule Vagus.Core.Client do
  @moduledoc """
  Lazy access-token exchange against Core's `/auth/token`
  (`docs/contract-2026.7.md` §5), mirroring the real Supervisor's
  `_ensure_access_token`.

  Caches `{access_token, issued_at, expires_in}`; before any Core call, if
  the cached token is missing or expired (`now >= issued_at + expires_in`),
  exchanges the stored refresh token (`Vagus.Core.TokenStore`) for a fresh
  one via `POST {core_base}/auth/token`, form-encoded
  `grant_type=refresh_token&refresh_token=<token>`.

  Deliberately sends **no `client_id`** — the Supervisor's refresh token is
  created by Core with `client_id = nil` (§5), and the equality check on
  Core's `/auth/token` handler is `refresh_token.client_id != client_id`;
  sending any `client_id` value (even an empty string) would make
  `nil != client_id` true and fail the exchange. Omitting the form field
  entirely is what makes both sides agree (`nil == nil`).

  Never crashes on a Core-side or network failure — every error path
  returns `{:error, reason}` from `access_token/1`/`request/3`, including
  the case where no refresh token has been posted yet
  (`{:error, :no_refresh_token}`).

  ## Transport (`Vagus.Core.Transport`)

  Every request here — the token exchange included — rides the
  Supervisor↔Core unix socket when it exists, and falls back to TCP
  `:core_base_url` when it doesn't. The transport is resolved once per
  request, so a socket that appears (Core started) or disappears (Core
  recreated) is picked up by the next call with nothing to invalidate.

  On the socket, Core authenticates the caller as the Supervisor user
  implicitly: `request/3` sends **no** `Authorization` header at all, and
  since there is no bearer token in play there is nothing to invalidate and
  re-exchange, so the 401-retry-once dance is TCP-only — a socket-path 401
  is returned to the caller as an ordinary response. The token machinery
  itself stays live regardless (Core's WS API on the TCP fallback, and
  `Vagus.API.CoreProxy`, still need real tokens).
  """

  use GenServer

  alias Vagus.Core.Transport

  @default_finch Vagus.Core.Finch

  @typedoc "Injectable clock, defaults to wall-clock seconds. Tests supply their own for expiry control."
  @type clock :: (-> integer())

  @doc """
  Starts the client.

  Options:

    * `:name` - GenServer name, defaults to `__MODULE__`.
    * `:core_base_url` - defaults to `config :vagus, :core_base_url`
      (itself defaulting to `"http://localhost:8123"`).
    * `:finch_name` - the `Finch` pool to issue requests through, defaults
      to `Vagus.Core.Finch`.
    * `:token_store` - the `Vagus.Core.TokenStore` server to read the
      refresh token from, defaults to `Vagus.Core.TokenStore`.
    * `:clock` - a zero-arity function returning "now" as an integer
      (seconds), defaults to `System.system_time(:second)`. Tests inject a
      controllable clock to exercise expiry without sleeping.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns a currently-valid access token, exchanging the refresh token for
  a new one first if the cached one is missing or expired.
  """
  @spec access_token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def access_token(server \\ __MODULE__) do
    GenServer.call(server, :access_token)
  end

  @doc "Clears the cached access token, forcing the next call to re-exchange."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  end

  @doc """
  Issues a request against `path` on whichever transport is live
  (`Vagus.Core.Transport`).

  Over the socket the request carries no credential at all (Core reads it
  as the Supervisor user) and is issued exactly once. Over TCP it is
  authenticated with the cached access token and retried exactly once on a
  `401` (clears the cached token, re-exchanges, retries with the new
  token).

  `opts`:

    * `:server` - the `Vagus.Core.Client` to call, defaults to `__MODULE__`.
    * `:headers` - extra headers, defaults to `[]`.
    * `:body` - request body, defaults to `nil`.
  """
  @spec request(Finch.Request.method(), String.t(), keyword()) ::
          {:ok, Finch.Response.t()} | {:error, term()}
  def request(method, path, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)
    GenServer.call(server, {:request, method, path, headers, body})
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    state = %{
      access_token: nil,
      issued_at: nil,
      expires_in: nil,
      core_base_url: Keyword.get(opts, :core_base_url, core_base_url()),
      finch_name: Keyword.get(opts, :finch_name, @default_finch),
      token_store: Keyword.get(opts, :token_store, Vagus.Core.TokenStore),
      clock: Keyword.get(opts, :clock, &default_clock/0)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:access_token, _from, state) do
    case ensure_token(state) do
      {:ok, token, new_state} -> {:reply, {:ok, token}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:request, method, path, headers, body}, _from, state) do
    state
    |> transport()
    |> dispatch_request(method, path, headers, body, state)
  end

  @impl GenServer
  def handle_cast(:invalidate, state) do
    {:noreply, %{state | access_token: nil, issued_at: nil, expires_in: nil}}
  end

  ## Internals

  # Socket: implicit Supervisor-user auth, so no token is fetched, none is
  # sent, and a 401 (which can only mean something other than "our token
  # went stale") is handed back as an ordinary response rather than
  # triggering a re-exchange that has nothing to exchange.
  defp dispatch_request({:socket, _path} = transport, method, path, headers, body, state) do
    case do_request(transport, method, path, headers, body, nil, state) do
      {:ok, response, new_state} -> {:reply, {:ok, response}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  defp dispatch_request({:tcp, _base_url} = transport, method, path, headers, body, state) do
    case ensure_token(state) do
      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}

      {:ok, token, new_state} ->
        case do_request(transport, method, path, headers, body, token, new_state) do
          {:ok, %Finch.Response{status: 401}, retry_state} ->
            retry_once(transport, method, path, headers, body, retry_state)

          {:ok, response, new_state2} ->
            {:reply, {:ok, response}, new_state2}

          {:error, reason, new_state2} ->
            {:reply, {:error, reason}, new_state2}
        end
    end
  end

  defp retry_once(transport, method, path, headers, body, state) do
    cleared = %{state | access_token: nil, issued_at: nil, expires_in: nil}

    case ensure_token(cleared) do
      {:error, reason, final_state} ->
        {:reply, {:error, reason}, final_state}

      {:ok, token, final_state} ->
        case do_request(transport, method, path, headers, body, token, final_state) do
          {:ok, %Finch.Response{status: 401}, again_state} ->
            {:reply, {:error, :unauthorized}, again_state}

          {:ok, response, again_state} ->
            {:reply, {:ok, response}, again_state}

          {:error, reason, again_state} ->
            {:reply, {:error, reason}, again_state}
        end
    end
  end

  defp transport(state), do: Transport.current(base_url: state.core_base_url)

  defp ensure_token(state) do
    if valid?(state) do
      {:ok, state.access_token, state}
    else
      exchange(state)
    end
  end

  defp valid?(%{access_token: nil}), do: false

  defp valid?(%{issued_at: issued_at, expires_in: expires_in} = state) do
    now(state) < issued_at + expires_in
  end

  defp exchange(state) do
    case Vagus.Core.TokenStore.get_refresh_token(state.token_store) do
      nil -> {:error, :no_refresh_token, state}
      refresh_token -> do_exchange(refresh_token, state)
    end
  end

  defp do_exchange(refresh_token, state) do
    # No `client_id` field — see moduledoc.
    body =
      URI.encode_query(%{"grant_type" => "refresh_token", "refresh_token" => refresh_token})

    request =
      Transport.build(
        transport(state),
        :post,
        "/auth/token",
        [{"content-type", "application/x-www-form-urlencoded"}],
        body
      )

    case Finch.request(request, state.finch_name) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        handle_token_response(resp_body, state)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_token_response(resp_body, state) do
    case Jason.decode(resp_body) do
      {:ok, %{"access_token" => access_token, "expires_in" => expires_in}}
      when is_binary(access_token) and is_integer(expires_in) ->
        new_state = %{
          state
          | access_token: access_token,
            issued_at: now(state),
            expires_in: expires_in
        }

        {:ok, access_token, new_state}

      {:ok, _other} ->
        # Also catches an `access_token`/`expires_in` of the wrong type (e.g.
        # `expires_in` as a string) - `valid?/1` does integer arithmetic on
        # `expires_in`, so caching a non-integer here would only surface as
        # an ArithmeticError on some later, unrelated call.
        {:error, :invalid_token_response, state}

      {:error, reason} ->
        {:error, {:invalid_json, reason}, state}
    end
  end

  defp do_request(transport, method, path, headers, body, token, state) do
    request =
      Transport.build(transport, method, path, auth_headers(transport, headers, token), body)

    case Finch.request(request, state.finch_name) do
      {:ok, response} -> {:ok, response, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The A3 rule, in one place: a bearer token on TCP, nothing at all on the
  # socket (Core reads the peer as the Supervisor user itself).
  defp auth_headers(transport, headers, token) do
    if Transport.implicit_auth?(transport) do
      headers
    else
      [{"authorization", "Bearer " <> token} | headers]
    end
  end

  defp now(state), do: state.clock.()

  defp default_clock, do: System.system_time(:second)

  defp core_base_url do
    Application.get_env(:vagus, :core_base_url, "http://localhost:8123")
  end
end
