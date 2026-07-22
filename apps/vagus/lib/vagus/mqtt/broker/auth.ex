defmodule Vagus.Mqtt.Broker.Auth do
  @moduledoc """
  CONNECT credential validation for the native MQTT broker (M5, MQ-P1).

  mqttx ships no credential store — auth is delegated 100% to `handle_connect`
  (`Vagus.Mqtt.Broker.Handler`). This module holds the ordered check, reusing
  the add-on subsystem's existing machinery verbatim rather than inventing a new
  auth path. A CONNECT is accepted if any of these match, in order:

    1. **mqtt service credentials** — the `username`/`password` in the provider
       payload registered via `POST /services/mqtt` (`Vagus.Services.get/2`).
       This is how add-ons authenticate against the broker (Mosquitto's
       `addons` service user); a local, no-round-trip check.
    2. **Home Assistant users** — `Vagus.Auth.check_login/4`, the same cache →
       Core `api/hassio_auth` path `POST /auth` already uses (`auth.ex`). REUSED,
       not reimplemented.
    3. **broker options logins** — static `%{username, password}` pairs from the
       add-on's own options (empty until the options schema lands).

  Anonymous connects (no username) are rejected unless `allow_anonymous` is set.
  A miss returns `:error`, which the handler maps to CONNACK reason code `0x05`
  ("not authorised", MQTT 3.1.1 §3.2.2.3) — matching Mosquitto's `mosquitto_pub`
  exit-5 behaviour the conformance gate checks.

  Local credential comparisons (service creds, options logins) use
  `Plug.Crypto.secure_compare/2` to avoid a timing oracle; the HA-user path's
  timing is dominated by the Core round-trip / cache and is out of scope here.
  """

  alias Vagus.Mqtt.Broker.AuthCache
  alias Vagus.Services

  @type login :: %{username: String.t(), password: String.t()}
  @type config :: %{
          slug: String.t(),
          services: GenServer.server(),
          auth_opts: keyword(),
          logins: [login()],
          allow_anonymous: boolean(),
          neg_cache: atom() | nil
        }

  @doc """
  Builds an auth `config` from broker options.

    * `:slug` — add-on slug passed to `check_login/4` (default `"core_mqtt"`)
    * `:services` — `Vagus.Services` server (default `Vagus.Services`)
    * `:auth_opts` — opts threaded into `Vagus.Auth.check_login/4` (`:server`,
      `:core_client`; mainly for tests)
    * `:logins` — static `%{username, password}` option logins (default `[]`)
    * `:allow_anonymous` — accept CONNECTs with no username (default `false`)
    * `:neg_cache` — `Vagus.Mqtt.Broker.AuthCache` table name for short-TTL
      failure caching (reconnect-storm mitigation); `nil` disables it (default)
  """
  @spec config(keyword()) :: config()
  def config(opts \\ []) do
    %{
      slug: Keyword.get(opts, :slug, "core_mqtt"),
      services: Keyword.get(opts, :services, Services),
      auth_opts: Keyword.get(opts, :auth_opts, []),
      logins: Keyword.get(opts, :logins, []),
      allow_anonymous: Keyword.get(opts, :allow_anonymous, false),
      neg_cache: Keyword.get(opts, :neg_cache)
    }
  end

  @doc """
  Validates a CONNECT's credentials against `config`. `:ok` to accept, `:error`
  to reject. An empty/absent username is anonymous; an empty password is always
  rejected (so an empty configured secret can never authenticate).
  """
  @spec authenticate(String.t() | nil, String.t() | nil, config()) :: :ok | :error
  def authenticate(username, password, config) do
    cond do
      blank?(username) -> if config.allow_anonymous, do: :ok, else: :error
      blank?(password) -> :error
      true -> authenticate_credentials(username, password, config)
    end
  end

  defp authenticate_credentials(username, password, config) do
    key = neg_key(config, username, password)

    cond do
      neg_blocked?(config, key) ->
        :error

      service_credentials?(username, password, config.services) or
        Vagus.Auth.check_login(username, password, config.slug, config.auth_opts) or
          options_login?(username, password, config.logins) ->
        :ok

      true ->
        # Remember only genuine misses, so a reconnect storm on the same bad
        # pair stops hitting Core / re-running the local checks for the TTL.
        neg_record(config, key)
        :error
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp neg_key(%{neg_cache: nil}, _username, _password), do: nil
  defp neg_key(_config, username, password), do: AuthCache.key(username, password)

  defp neg_blocked?(%{neg_cache: nil}, _key), do: false
  defp neg_blocked?(%{neg_cache: table}, key), do: AuthCache.blocked?(table, key)

  defp neg_record(%{neg_cache: nil}, _key), do: :ok
  defp neg_record(%{neg_cache: table}, key), do: AuthCache.record_failure(table, key)

  defp service_credentials?(username, password, services) do
    case Services.get("mqtt", services) do
      {:ok, %{"username" => u, "password" => p}} when is_binary(u) and is_binary(p) and p != "" ->
        secure_equal?(u, username) and secure_equal?(p, password)

      _ ->
        false
    end
  end

  defp options_login?(username, password, logins) do
    Enum.any?(logins, fn %{username: u, password: p} ->
      secure_equal?(u, username) and secure_equal?(p, password)
    end)
  end

  # Constant-time, and length-safe: `secure_compare/2` returns false on a length
  # mismatch without leaking it through timing.
  defp secure_equal?(a, b), do: Plug.Crypto.secure_compare(a, b)
end
