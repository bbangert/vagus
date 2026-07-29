defmodule Vagus.API.AddonOptionsConfigTest do
  @moduledoc """
  `GET /addons/self/options/config` — an add-on reading its own effective
  options, which is what `bashio::config` fetches.

  Upstream answers `app.schema.validate(app.options)`: the config's defaults
  deep-merged with the user's saved options, validated, computed live. It is
  deliberately **not** a read of the `/data/options.json` file
  `Vagus.Addon.Manager` writes — that file is an output, so reading it back
  reports whatever the add-on was last started with.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.{Config, Registry, State}

  @opts Vagus.API.Router.init([])

  defp install(slug, opts \\ []) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test Addon",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "options" => Keyword.get(opts, :options, %{"greeting" => "hi", "extra" => false}),
        "schema" => Keyword.get(opts, :schema, %{"greeting" => "str", "extra" => "bool"})
      })

    :ok = State.put(config, :started, user_options: Keyword.get(opts, :user_options, %{}))
    on_exit(fn -> State.delete(slug) end)
    config
  end

  defp addon_token(slug) do
    token = "tok-#{System.unique_integer([:positive])}"

    :ok =
      Registry.register(token, %{slug: slug, services_role: %{}, auth_api: false, discovery: []})

    on_exit(fn -> Registry.unregister_slug(slug) end)
    token
  end

  defp get(path, token) do
    conn(:get, path)
    |> put_req_header("x-supervisor-token", token)
    |> Vagus.API.Router.call(@opts)
  end

  defp data(conn), do: Jason.decode!(conn.resp_body)["data"]

  test "self returns the config defaults when the user has saved nothing" do
    install("core_optcfgdefaults")
    conn = get("/addons/self/options/config", addon_token("core_optcfgdefaults"))

    assert conn.status == 200
    assert data(conn) == %{"greeting" => "hi", "extra" => false}
  end

  test "a saved option wins over the default, without dropping untouched keys" do
    install("core_optcfgmerged", user_options: %{"greeting" => "hello"})
    conn = get("/addons/self/options/config", addon_token("core_optcfgmerged"))

    assert conn.status == 200
    assert data(conn) == %{"greeting" => "hello", "extra" => false}
  end

  test "an option saved while the add-on is running is visible immediately" do
    # The reason this reads State rather than the container's options.json:
    # that file is only written at start, so an add-on re-reading its config
    # after the user saved would otherwise get the values it booted with.
    install("core_optcfglive")
    token = addon_token("core_optcfglive")

    assert data(get("/addons/self/options/config", token))["greeting"] == "hi"

    :ok = State.put_options("core_optcfglive", %{"greeting" => "changed"})

    assert data(get("/addons/self/options/config", token))["greeting"] == "changed"
  end

  test "options that don't validate are a 400, not a half-decoded map" do
    install("core_optcfginvalid", user_options: %{"greeting" => 5})
    conn = get("/addons/self/options/config", addon_token("core_optcfginvalid"))

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["message"] =~ "Invalid configuration data"
  end

  test "an add-on that isn't installed is a 400" do
    # Registered token, no State entry — nothing to compute options from.
    conn = get("/addons/self/options/config", addon_token("core_optcfgghost"))
    assert conn.status == 400
  end

  test "a non-self slug is forbidden (self-only)" do
    install("core_optcfgother")

    assert get("/addons/core_optcfgother/options/config", addon_token("core_optcfgother")).status ==
             403
  end

  test "the supervisor token is not an app → 400" do
    conn =
      conn(:get, "/addons/self/options/config")
      |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 400
  end
end
