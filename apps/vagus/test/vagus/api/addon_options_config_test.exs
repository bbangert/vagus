defmodule Vagus.API.AddonOptionsConfigTest do
  @moduledoc "GET /addons/self/options/config — an add-on reading its own effective options."
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.Registry

  @opts Vagus.API.Router.init([])

  setup do
    # Point the addon data root at a tmp dir and write an options.json for the
    # add-on under test (as Manager.start would).
    root = Path.join(System.tmp_dir!(), "vagus-optcfg-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:vagus, :addon_data_root)
    Application.put_env(:vagus, :addon_data_root, root)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:vagus, :addon_data_root, prev),
        else: Application.delete_env(:vagus, :addon_data_root)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp write_options(root, slug, options) do
    path = Path.join([root, "addons", "data", slug, "options.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(options))
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

  test "self returns the add-on's effective options", %{root: root} do
    options = %{"logins" => [], "require_certificate" => false, "certfile" => "fullchain.pem"}
    write_options(root, "core_mosquitto", options)
    token = addon_token("core_mosquitto")

    conn = get("/addons/self/options/config", token)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["data"] == options
  end

  test "a non-self slug is forbidden (self-only)", %{root: root} do
    write_options(root, "core_mosquitto", %{})
    token = addon_token("core_mosquitto")
    assert get("/addons/core_mosquitto/options/config", token).status == 403
  end

  test "the supervisor token is not an app → 400", %{} do
    conn =
      conn(:get, "/addons/self/options/config")
      |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
      |> Vagus.API.Router.call(@opts)

    assert conn.status == 400
  end

  test "missing options.json → 400", %{} do
    token = addon_token("never_started")
    assert get("/addons/self/options/config", token).status == 400
  end
end
