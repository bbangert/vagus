defmodule Vagus.API.AuthRouterTest do
  @moduledoc "P4-T3: /auth endpoints through Auth's caller resolution."
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.Registry

  @opts Vagus.API.Router.init([])

  # A stub Core client: the router's `Vagus.Auth.check_login/3` runs
  # synchronously in this (test) process, so it reads the reply + records the
  # forwarded body via the process dictionary. Accepts "alice"/"secret".
  defmodule StubCore do
    def request(_method, _path, opts) do
      body = Jason.decode!(Keyword.fetch!(opts, :body))
      Process.put(:auth_forwarded, body)

      if body["username"] == "alice" and body["password"] == "secret",
        do: {:ok, %{status: 200}},
        else: {:ok, %{status: 401}}
    end
  end

  setup do
    Application.put_env(:vagus, :core_client, StubCore)
    Vagus.Auth.reset_cache()
    on_exit(fn -> Application.delete_env(:vagus, :core_client) end)
    :ok
  end

  defp addon_token(slug, auth_api, grants \\ %{}) do
    token = "tok-#{System.unique_integer([:positive])}"

    identity =
      Map.merge(
        %{
          slug: slug,
          services_role: %{},
          auth_api: auth_api,
          discovery: [],
          hassio_api: false,
          hassio_role: "default"
        },
        grants
      )

    :ok = Registry.register(token, identity)

    on_exit(fn -> Registry.unregister_slug(slug) end)
    token
  end

  defp basic(user, pass), do: "Basic " <> Base.encode64("#{user}:#{pass}")

  test "Basic-header creds are extracted and forwarded to Core" do
    token = addon_token("core_mosquitto", true)

    conn =
      conn(:post, "/auth", "")
      |> put_req_header("x-supervisor-token", token)
      |> put_req_header("authorization", basic("alice", "secret"))
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 200
    assert Process.get(:auth_forwarded)["addon"] == "core_mosquitto"
  end

  test "JSON body creds (with `user` alias) are extracted" do
    token = addon_token("core_mosquitto", true)

    conn =
      conn(:post, "/auth", Jason.encode!(%{"user" => "alice", "password" => "secret"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-supervisor-token", token)
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 200
    assert Process.get(:auth_forwarded)["username"] == "alice"
  end

  test "form-encoded body creds are extracted" do
    token = addon_token("core_mosquitto", true)

    conn =
      conn(:post, "/auth", "username=alice&password=secret")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("x-supervisor-token", token)
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 200
  end

  test "bad creds → 401 + WWW-Authenticate realm" do
    token = addon_token("core_mosquitto", true)

    conn =
      conn(:post, "/auth", "")
      |> put_req_header("x-supervisor-token", token)
      |> put_req_header("authorization", basic("alice", "wrong"))
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 401
    assert ["Basic realm=" <> _] = get_resp_header(conn, "www-authenticate")
  end

  test "no credentials → 401" do
    token = addon_token("core_mosquitto", true)

    conn =
      conn(:post, "/auth", "")
      |> put_req_header("x-supervisor-token", token)
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 401
  end

  test "an add-on without auth_api → 403" do
    token = addon_token("no_auth_addon", false)

    conn =
      conn(:post, "/auth", "")
      |> put_req_header("x-supervisor-token", token)
      |> put_req_header("authorization", basic("alice", "secret"))
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 403
  end

  test "the supervisor token may not use /auth" do
    conn =
      conn(:get, "/auth", "")
      |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 403
  end

  # Audit A6/B2. `/auth/cache` is NOT part of the `auth_api` grant surface —
  # upstream puts it in `role_access[manager]` (security.py L135) and its
  # handler makes no `access_auth_api` check at all. Vagus had both halves
  # backwards: an `auth_api: true` default-role add-on was let in, and Core
  # itself was refused, so any Core-side cache reset failed.
  describe "DELETE /auth/cache" do
    test "Core's own token clears the cache" do
      conn =
        conn(:delete, "/auth/cache", "")
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 200
    end

    test "a manager-role add-on clears the cache" do
      token =
        addon_token("core_manager", false, %{hassio_api: true, hassio_role: "manager"})

      conn =
        conn(:delete, "/auth/cache", "")
        |> put_req_header("x-supervisor-token", token)
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 200
    end

    test "an auth_api add-on without the manager role is refused" do
      token = addon_token("core_mosquitto", true, %{hassio_api: true, hassio_role: "default"})

      conn =
        conn(:delete, "/auth/cache", "")
        |> put_req_header("x-supervisor-token", token)
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 403
    end
  end
end
