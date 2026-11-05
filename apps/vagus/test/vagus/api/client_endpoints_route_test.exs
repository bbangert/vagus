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

  @fixture_path Path.expand("../../fixtures/aiohasupervisor-0.8.1-contract.json", __DIR__)
  @external_resource @fixture_path
  @endpoints @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("_endpoints")

  @placeholders %{"{slug}" => "core_example", "{version}" => "1.0.0"}

  defp concrete(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&Map.get(@placeholders, &1, &1))
  end

  defp matches?(pattern, segments),
    do: segments_match?(String.split(pattern, "/", trim: true), segments)

  defp segments_match?([], []), do: true
  defp segments_match?(["*" <> _glob], _rest), do: true
  defp segments_match?([":" <> _param | pattern], [_ | rest]), do: segments_match?(pattern, rest)
  defp segments_match?([same | pattern], [same | rest]), do: segments_match?(pattern, rest)
  defp segments_match?(_pattern, _segments), do: false

  test "the fixture lists each client's endpoints" do
    assert Map.keys(@endpoints) |> Enum.sort() == ~w(addons ingress store)
    assert Enum.all?(Map.values(@endpoints), &(&1 != []))
  end

  test "every endpoint the client can call is routed" do
    routes = RouterRoutes.routes()

    unrouted =
      for {_client, endpoints} <- @endpoints,
          [method, path] <- endpoints,
          not Enum.any?(routes, fn {verb, pattern} ->
            verb == method and matches?(pattern, concrete(path))
          end),
          do: "#{method} #{path}"

    assert unrouted == [], "client endpoints with no route: #{inspect(unrouted)}"
  end
end
