defmodule Vagus.API.ClientEndpointsRouteTest do
  @moduledoc """
  Every request aiohasupervisor's app-facing clients (`AddonsClient`,
  `StoreClient`, `IngressClient`) can make has a route here.

  The list is the `_endpoints` key of the same versioned fixture
  `Vagus.API.AiohasupervisorContractTest` reads, extracted from the client's
  own source at that version by `scripts/dump_aiohasupervisor_contract.py`.
  A client release that adds a method Vagus does not route fails this test
  on the fixture bump, instead of as a 404 inside Core.

  Only the route's existence is checked: what each one answers is the
  contract test's and the route tests' job.
  """

  use ExUnit.Case, async: true

  alias Vagus.RouterRoutes

  @fixture_path Vagus.Test.ContractFixture.path()
  @external_resource @fixture_path
  @endpoints Vagus.Test.ContractFixture.load() |> Map.fetch!("_endpoints")

  @placeholders %{"{slug}" => "core_example", "{version}" => "1.0.0"}

  defp concrete(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &Map.get(@placeholders, &1, &1))
  end

  test "the fixture lists each client's endpoints" do
    assert Map.keys(@endpoints) |> Enum.sort() == ~w(addons ingress store)
    assert Enum.all?(Map.values(@endpoints), &(&1 != []))
  end

  test "every endpoint the client can call is routed" do
    routes = RouterRoutes.routes()

    unrouted =
      for {_client, endpoints} <- @endpoints,
          [method, path] <- endpoints,
          not RouterRoutes.routed?(routes, method, concrete(path)),
          do: "#{method} #{path}"

    assert unrouted == [], "client endpoints with no route: #{inspect(unrouted)}"
  end
end
