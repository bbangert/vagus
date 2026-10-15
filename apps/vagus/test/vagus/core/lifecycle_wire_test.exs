defmodule Vagus.Core.LifecycleWireTest do
  # What `Vagus.Core.Lifecycle` puts on the Engine-API wire through the
  # Docker adapter; `LifecycleTest` covers the behaviour on `Engine.Fake`.
  # async: false — the Core lifecycle lock is node-global.
  use ExUnit.Case, async: false

  alias Vagus.Core.{Container, Lifecycle, Versions}
  alias Vagus.Test.FakeEngine

  defp daemon(script) do
    engine = FakeEngine.start(script)
    on_exit(fn -> FakeEngine.stop(engine) end)
    {engine, [engine_opts: [socket: engine.socket]]}
  end

  defp versions(installed) do
    name = :"lifecycle_wire_versions_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.json")
    on_exit(fn -> File.rm(path) end)

    start_supervised!(%{
      id: name,
      start:
        {Versions, :start_link, [[name: name, path: path, fetch: fn -> {:error, :unused} end]]}
    })

    :ok = Versions.set_installed(installed, name)
    name
  end

  defp inspect_body(version, env) do
    %{
      "Id" => "existing-container-id",
      "Name" => "/homeassistant",
      "Config" => %{
        "Image" => Container.image(version),
        "Env" => env,
        "Labels" => %{Container.spec_fingerprint_label() => "stale"}
      },
      "State" => %{"Status" => "running", "Running" => true}
    }
  end

  @not_found {404, %{"message" => "No such container: homeassistant"}}

  test "an absent Core is created from create_config/2, named by the query, then started" do
    {engine, opts} = daemon([@not_found, {201, %{"Id" => "fresh-id"}}, {204, nil}])

    assert :ok =
             Lifecycle.start(opts ++ [versions: versions("2026.7.0"), health: fn -> :healthy end])

    assert [
             %{method: :get, path: "/containers/homeassistant/json"},
             %{method: :post, path: "/containers/create", query: %{"name" => "homeassistant"}} =
               create,
             %{method: :post, path: "/containers/fresh-id/start"}
           ] = FakeEngine.requests(engine)

    assert create.body == Container.create_config("2026.7.0")
  end

  test "stop sends the gracetime-derived timeout as t" do
    {engine, opts} =
      daemon([{200, inspect_body("2026.7.0", ["S6_SERVICES_GRACETIME=5000"])}, {204, nil}])

    assert :ok = Lifecycle.stop(opts)

    assert [_inspect, %{method: :post, path: "/containers/homeassistant/stop", query: query}] =
             FakeEngine.requests(engine)

    assert query["t"] == "25"
  end

  test "update pulls the target image by repo and tag" do
    {engine, opts} = daemon([{200, "{\"status\":\"Pull complete\"}\n"}, @not_found])

    assert {:ok, "2026.8.0"} =
             Lifecycle.update("2026.8.0", opts ++ [versions: versions("2026.7.0")])

    assert [%{method: :post, path: "/images/create", query: query}, _inspect] =
             FakeEngine.requests(engine)

    assert query["fromImage"] == "ghcr.io/home-assistant/home-assistant"
    assert query["tag"] == "2026.8.0"
  end

  test "a 404 inspect adopts nothing" do
    {engine, opts} = daemon([@not_found])

    assert :absent = Lifecycle.adopt(opts)
    assert [%{method: :get, path: "/containers/homeassistant/json"}] = FakeEngine.requests(engine)
  end
end
