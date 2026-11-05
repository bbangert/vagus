defmodule Vagus.API.AiohasupervisorContractTest do
  @moduledoc """
  Regression contract test for the 2026-08-07 incident: Core's hassio
  coordinator crashed every refresh with
  `mashumaro.exceptions.MissingField: Field "version_pending" ... missing
  in OSInfo` — our `OSInfo` payload had drifted behind the aiohasupervisor
  client (0.6.0) actually running inside Core, which added a required
  field our hand-maintained `docs/contract-2026.7.md` (pinned at 0.5.0)
  and `Vagus.API.Models.OSInfo` had both missed. `test/vagus/api/router_test.exs`
  pins key lists TRANSCRIBED from that same doc, so it caught nothing —
  the doc and the code drifted together. This test instead checks against
  `test/fixtures/aiohasupervisor-<version>-contract.json`, a field list dumped
  directly from `dataclasses.fields()` on the REAL client classes running
  on-device, independent of anything we hand-wrote.

  ## Regenerating the fixture

  Required on every Core/aiohasupervisor version bump (`homeassistant/
  components/hassio/manifest.json`'s `aiohasupervisor==` pin). Run
  read-only against a live board (writes no state), from the repo root:

  ```
  scp scripts/dump_aiohasupervisor_contract.py <board-ip>:/tmp/dump_models.py
  ssh <board-ip> 'System.cmd("sh", ["-c",
    "podman exec -i homeassistant python3 - < /tmp/dump_models.py"]) |> elem(0) |> IO.puts()'
  ```

  The script dumps every dataclass in the 8 `aiohasupervisor.models` modules
  the coordinator touches, not just the models wired into `@model_endpoints`,
  so wiring in another endpoint needs no new dump. It also writes
  `_endpoints`, every request the app-facing clients make, read from the
  client's source at the same version (`Vagus.API.ClientEndpointsRouteTest`
  checks each is routed). Save the output to
  `test/fixtures/aiohasupervisor-<new version>-contract.json`, replacing the
  old file (`Vagus.Test.ContractFixture` requires exactly one, and both this
  test and the route guard follow it; nothing else needs editing). The
  "records its own `_version`" test asserts the fixture's `_version` key
  equals its filename's version, so a fixture saved under the wrong filename
  (or dumped from the wrong environment) fails loudly.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Vagus.AppFixtures

  alias Vagus.Addon.{Config, Store}
  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  @fixture_path Vagus.Test.ContractFixture.path()
  @external_resource @fixture_path
  @fixture Vagus.Test.ContractFixture.load()

  # Cross-checked against the fixture's own `_version` below: a fixture
  # regenerated from the wrong environment fails loudly instead of silently
  # redefining the contract.
  @client_version Vagus.Test.ContractFixture.version()

  # {fixture key, router path} or {fixture key, router path, where}. A path
  # is a GET unless written `{:post, path}`. `where` names the payload's
  # model instances: `each: key` for every element of the list under `key`,
  # `each_value: key` for every value of the map under `key`; without it the
  # payload itself is the instance.
  @model_endpoints [
    {"root.RootInfo", "/info"},
    {"homeassistant.HomeAssistantInfo", "/core/info"},
    {"supervisor.SupervisorInfo", "/supervisor/info"},
    {"os.OSInfo", "/os/info"},
    {"host.HostInfo", "/host/info"},
    {"addons.StoreInfo", "/store"},
    {"network.NetworkInfo", "/network/info"},
    {"mounts.MountsInfo", "/mounts"},
    # Core 2026.11.0's `supervisor/ingress/info` parses this one through the
    # typed client, which is what opening any app's sidebar panel goes
    # through — the `vagus` admin panel included.
    {"addons.InstalledAddonComplete", "/addons/vagus/info"},
    {"addons.AddonsStats", "/addons/vagus/stats"},
    {"addons.AddonsConfigValidate", {:post, "/addons/vagus/options/validate"}},
    {"addons.InstalledAddonComplete", "/addons/contract_app/info"},
    {"addons.InstalledAddon", "/addons", each: "addons"},
    {"addons.StoreAddon", "/store", each: "addons"},
    {"addons.Repository", "/store", each: "repositories"},
    {"ingress.IngressPanel", "/ingress/panels", each_value: "panels"},
    {"addons.AddonsStats", "/addons/contract_app/stats"},
    {"addons.AddonsConfigValidate", {:post, "/addons/contract_app/options/validate"}}
  ]

  # Model field name => wire key, for fields mashumaro reads under an alias.
  @wire_aliases %{"supervisor_api" => "hassio_api", "supervisor_role" => "hassio_role"}

  # Needs the app process (`App.info/1`), hence `async: false`.
  setup do
    {:ok, config} =
      Config.parse(%{
        "name" => "Contract app",
        "version" => "1.0.0",
        "slug" => "contract_app",
        "description" => "An installed app for the contract check",
        "arch" => ["aarch64"],
        "ingress" => true
      })

    install_app(config, state: :started)
    install_app(admin_panel_config(), state: :started, ingress_panel: true)

    # An empty store would pass `each:` vacuously.
    original = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      %{
        state
        | catalog: %{"contract_app" => %{config: config, repository: "core"}},
          repositories: [
            %{slug: "core", url: "https://github.com/home-assistant/addons", source: "core"}
          ]
      }
    end)

    on_exit(fn -> :sys.replace_state(Store, fn _state -> original end) end)

    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp request({:post, path}),
    do: conn(:post, path, "{}") |> put_req_header("content-type", "application/json")

  defp request(path), do: conn(:get, path)

  # `List.wrap/1`, not `[data]`: a literal non-empty list makes the compiler
  # flag the emptiness check below as always true.
  defp instances(data, []), do: List.wrap(data)
  defp instances(data, each: key), do: Map.fetch!(data, key)
  defp instances(data, each_value: key), do: data |> Map.fetch!(key) |> Map.values()

  describe "every required aiohasupervisor field is present on the wire" do
    for row <- @model_endpoints do
      {fixture_key, path, where} =
        case row do
          {key, path} -> {key, path, []}
          {key, path, where} -> {key, path, where}
        end

      {method, url} = if is_tuple(path), do: path, else: {:get, path}

      required_fields =
        @fixture
        |> Map.fetch!(fixture_key)
        |> Enum.filter(& &1["req"])
        |> Enum.map(&Map.get(@wire_aliases, &1["n"], &1["n"]))

      test "#{method |> Atom.to_string() |> String.upcase()} #{url} #{inspect(where)} " <>
             "includes every required #{fixture_key} field" do
        conn = unquote(Macro.escape(path)) |> request() |> authed() |> call()

        assert conn.status == 200
        instances = instances(json_body(conn)["data"], unquote(where))
        assert instances != [], "#{unquote(url)} has no #{unquote(fixture_key)} to check"

        required = MapSet.new(unquote(required_fields))

        for instance <- instances do
          missing = MapSet.difference(required, MapSet.new(Map.keys(instance)))

          assert MapSet.size(missing) == 0,
                 "#{unquote(url)} is missing required aiohasupervisor field(s) " <>
                   "#{inspect(MapSet.to_list(missing))} — Core's mashumaro deserializer " <>
                   "will crash with MissingField on these; see this module's moduledoc " <>
                   "to regenerate the fixture if aiohasupervisor bumped again, or fix the " <>
                   "payload builder/model otherwise"
        end
      end
    end
  end

  # Core makes one device and update entity per listed slug.
  test "GET /addons lists the admin panel among the apps the each: row checks" do
    conn = "/addons" |> request() |> authed() |> call()

    states = Map.new(json_body(conn)["data"]["addons"], &{&1["slug"], &1["state"]})
    # A file its process could not load would be listed too, as `unknown`.
    assert %{"vagus" => "started", "contract_app" => "started"} = states
  end

  test "the fixture covers every model this test checks" do
    for row <- @model_endpoints, fixture_key = elem(row, 0) do
      assert Map.has_key?(@fixture, fixture_key), "fixture has no #{fixture_key}"
    end
  end

  test "the fixture records the aiohasupervisor version its filename claims" do
    assert @fixture["_version"] == @client_version
  end
end
