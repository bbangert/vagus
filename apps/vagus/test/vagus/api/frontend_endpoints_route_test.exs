defmodule Vagus.API.FrontendEndpointsRouteTest do
  @moduledoc """
  Every Supervisor endpoint the Home Assistant frontend can request has a
  route here, or a stated reason it does not.

  The frontend has no typed client: it reaches the Supervisor through Core's
  untyped `supervisor/api` WS proxy and `/api/hassio/<path>` view, so
  `Vagus.API.ClientEndpointsRouteTest` cannot see it. The list is extracted
  from the frontend's source at the tag Core pins, by
  `scripts/frontend-hassio-endpoints.sh`, which also pins the SHA-256 of every
  source file that can reach the Supervisor. `core-contract-drift.yml` fails
  when Core moves to a frontend where any of those files, or the list, differs:
  the hashes fail closed where the extractor cannot read a construct.
  """

  use ExUnit.Case, async: true

  alias Vagus.RouterRoutes
  alias Vagus.Test.ContractFixture

  @fixture_path ContractFixture.frontend_path()
  @external_resource @fixture_path
  @fixture ContractFixture.load_frontend()
  @endpoints @fixture["endpoints"]
  @raw Enum.filter(@endpoints, & &1["raw"])

  # Any value fits a `:param` route segment; `{param}` must not stand in for
  # a literal one (see `/host/disks/{param}/usage`).
  @placeholders %{
    "{slug}" => "core_example",
    "{version}" => "1.0.0",
    "{token}" => "abcdef",
    "{param}" => "param"
  }

  @no_mounts "Vagus has no network-storage mounts: GET /mounts reports none"
  @no_registries "no private-registry credentials: app images pull anonymously, and storing registry passwords is a feature to design, not a route to add"

  @unserved %{
    {"GET", "/docker/registries"} => @no_registries,
    {"POST", "/docker/registries"} => @no_registries,
    {"DELETE", "/docker/registries/{param}"} => @no_registries,
    {"GET", "/hardware/audio"} =>
      "only the app audio card calls it, and every app renders `audio: false`",
    {"GET", "/host/disks"} => "only the add-mount dialog calls it; " <> @no_mounts,
    {"GET", "/host/disks/{param}/usage"} =>
      "served for `default`, the data disk; any other value is a mount name, and " <> @no_mounts,
    {"POST", "/host/options"} => "the hostname is the firmware's, with no write path",
    {"POST", "/mounts"} => @no_mounts,
    {"POST", "/mounts/options"} => @no_mounts,
    {"PUT", "/mounts/{param}"} => @no_mounts,
    {"DELETE", "/mounts/{param}"} => @no_mounts,
    {"POST", "/mounts/{param}/reload"} => @no_mounts,
    {"POST", "/os/config/sync"} =>
      "HAOS's CONFIG-USB import; Vagus has none, and nothing calls it",
    {"POST", "/os/datadisk/move"} =>
      "GET /os/datadisk/list offers no device, so the move dialog has nothing to submit"
  }

  # Raw entries: constructs outside the extractor's whitelist, each with its
  # source text, so editing one fails the drift check. Counted per file so a
  # new one fails here and gets read, instead of being skipped.
  @raw_reviewed %{
    "src/data/hassio/supervisor.ts" =>
      {6,
       "log URLs whose first segment `provider` picks at runtime (`addons/<slug>`, core, supervisor, host); every family's /logs, /logs/follow and /logs/boots/:bootid routes are served"},
    "src/data/config_flow.ts" =>
      {1,
       "`config/config_entries/flow_handlers` with an optional `?type=`; Core's own API, not a `hassio/` path"},
    "src/data/hassio/common.ts" =>
      {1, "fetchHassioStats's own body; its callers are extracted as <prefix>/stats"},
    "src/data/supervisor/common.ts" =>
      {1,
       "supervisorApiCall's own body (`options?.method || \"get\"`); its callers are extracted, a missing method as GET"},
    "src/data/supervisor/supervisor.ts" =>
      {2,
       "getSupervisorEventCollection's endpoint parameter, whose callers are extracted (none at this tag); supervisorApiWsRequest's own body (`...request`), whose callers are extracted"}
  }

  defp concrete(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &Map.get(@placeholders, &1, &1))
  end

  test "the fixture is the frontend its name says" do
    assert @fixture["_frontend"] == ContractFixture.frontend_tag()
  end

  test "every endpoint was read from a pinned source" do
    sources = @fixture["sources"]
    assert is_map(sources) and map_size(sources) > 0

    unpinned =
      @endpoints
      |> Enum.map(& &1["source"])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(sources, &1))

    assert unpinned == [],
           "endpoints read from files the fixture does not hash: #{inspect(unpinned)}"
  end

  test "every endpoint the frontend can call is routed" do
    routes = RouterRoutes.routes()

    unrouted =
      for %{"method" => method, "path" => path} = endpoint <- @endpoints,
          !endpoint["raw"],
          not Map.has_key?(@unserved, {method, path}),
          not RouterRoutes.routed?(routes, method, concrete(path)),
          uniq: true,
          do: "#{method} #{path}"

    assert unrouted == [],
           "frontend endpoints with no route: #{inspect(unrouted, limit: :infinity)}"
  end

  test "each unserved endpoint is still called and still unrouted" do
    routes = RouterRoutes.routes()
    called = MapSet.new(@endpoints, &{&1["method"], &1["path"]})

    stale =
      for {method, path} = key <- Map.keys(@unserved),
          not MapSet.member?(called, key) or RouterRoutes.routed?(routes, method, concrete(path)),
          do: "#{method} #{path}"

    assert stale == [], "allowlisted but called no longer, or now routed: #{inspect(stale)}"
    assert RouterRoutes.routed?(routes, "GET", "/host/disks/default/usage")
  end

  test "every raw entry has been reviewed" do
    counts = @raw |> Enum.frequencies_by(& &1["source"])
    assert counts == Map.new(@raw_reviewed, fn {source, {count, _}} -> {source, count} end)
  end

  for %{"method" => method, "path" => path, "source" => source} <- @raw do
    {_count, reason} = Map.get(@raw_reviewed, source, {0, "not reviewed"})
    @tag skip: "raw: #{reason}"
    test "raw #{method} #{path} (#{source})"
  end
end
