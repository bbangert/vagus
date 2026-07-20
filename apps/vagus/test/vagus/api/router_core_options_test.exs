defmodule Vagus.API.RouterCoreOptionsTest do
  # async: false — unlike the rest of Vagus.API.RouterTest, these tests
  # mutate the real globally-supervised Vagus.Core.TokenStore (the router
  # always writes to the default-named singleton, matching what Core
  # actually posts to at runtime), so they must not race each other.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}
  alias Vagus.Core.TokenStore

  @opts Router.init([])

  defp call(conn), do: Router.call(conn, @opts)

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())

  defp req_json(conn), do: put_req_header(conn, "content-type", "application/json")

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp post_options(path, body) do
    conn(:post, path, Jason.encode!(body)) |> authed() |> req_json() |> call()
  end

  describe "POST /core/options" do
    test "persists refresh_token via Vagus.Core.TokenStore and returns an ok envelope" do
      token = "router-core-options-#{System.unique_integer([:positive])}"

      conn =
        post_options("/core/options", %{"refresh_token" => token, "ssl" => true, "port" => 8123})

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"] == "ok"
      assert body["data"] == %{}
      assert TokenStore.get_refresh_token() == token
    end

    test "unknown fields are ignored gracefully (still ok, no crash)" do
      conn = post_options("/core/options", %{"totally_unknown_field" => "nope", "another" => 1})

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end

    test "an options-only call with no refresh_token field still returns ok" do
      conn = post_options("/core/options", %{"ssl" => true, "port" => 8123})

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end
  end

  describe "POST /homeassistant/options (alias)" do
    test "persists refresh_token identically to /core/options" do
      token = "router-ha-options-#{System.unique_integer([:positive])}"
      conn = post_options("/homeassistant/options", %{"refresh_token" => token})

      assert conn.status == 200
      body = json_body(conn)
      assert body["result"] == "ok"
      assert body["data"] == %{}
      assert TokenStore.get_refresh_token() == token
    end

    test "an options-only call with no refresh_token field still returns ok" do
      conn = post_options("/homeassistant/options", %{"watchdog" => true})

      assert conn.status == 200
      assert json_body(conn)["result"] == "ok"
    end
  end
end
