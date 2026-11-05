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
  so wiring in another endpoint needs no new dump. Save the output to
  `test/fixtures/aiohasupervisor-<new version>-contract.json` and update
  `@fixture_path` below to match — `@client_version` derives from that
  path, and the "records its own `_version`" test asserts it equals the
  fixture's own `_version` key, so a fixture saved under the wrong
  filename (or dumped from the wrong environment) fails loudly instead of
  silently redefining the contract.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Vagus.AppFixtures

  alias Vagus.Addon.Config
  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "fixtures",
                  "aiohasupervisor-0.8.1-contract.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  # Derived from the fixture's own versioned filename (e.g. "0.6.0" out of
  # "aiohasupervisor-0.8.1-contract.json") so the two can be cross-checked
  # below — a fixture regenerated from the wrong environment (a different
  # aiohasupervisor than the filename claims) fails loudly instead of
  # silently redefining the contract.
  @client_version @fixture_path
                  |> Path.basename()
                  |> String.replace_prefix("aiohasupervisor-", "")
                  |> String.replace_suffix("-contract.json", "")

  # {fixture key, router path}
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
    # through — the synthetic `vagus` panel included.
    {"addons.InstalledAddonComplete", "/addons/vagus/info"},
    {"addons.InstalledAddonComplete", "/addons/contract_app/info"}
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
    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "every required aiohasupervisor field is present on the wire" do
    for {fixture_key, path} <- @model_endpoints do
      required_fields =
        @fixture
        |> Map.fetch!(fixture_key)
        |> Enum.filter(& &1["req"])
        |> Enum.map(&Map.get(@wire_aliases, &1["n"], &1["n"]))

      test "GET #{path} response includes every required #{fixture_key} field" do
        conn = conn(:get, unquote(path)) |> authed() |> call()

        assert conn.status == 200
        data = json_body(conn)["data"]

        present = MapSet.new(Map.keys(data))
        required = MapSet.new(unquote(required_fields))
        missing = MapSet.difference(required, present)

        assert MapSet.size(missing) == 0,
               "#{unquote(path)} is missing required aiohasupervisor field(s) " <>
                 "#{inspect(MapSet.to_list(missing))} — Core's mashumaro deserializer " <>
                 "will crash with MissingField on these; see this module's moduledoc " <>
                 "to regenerate the fixture if aiohasupervisor bumped again, or fix the " <>
                 "payload builder/model otherwise"
      end
    end
  end

  test "the fixture covers every model this test checks" do
    for {fixture_key, _path} <- @model_endpoints do
      assert Map.has_key?(@fixture, fixture_key), "fixture has no #{fixture_key}"
    end
  end

  test "the fixture records the aiohasupervisor version its filename claims" do
    assert @fixture["_version"] == @client_version
  end
end
