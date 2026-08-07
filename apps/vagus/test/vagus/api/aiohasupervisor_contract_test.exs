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
  `test/fixtures/aiohasupervisor-0.6.0-contract.json`, a field list dumped
  directly from `dataclasses.fields()` on the REAL client classes running
  on-device, independent of anything we hand-wrote.

  ## Regenerating the fixture

  Required on every Core/aiohasupervisor version bump (`homeassistant/
  components/hassio/manifest.json`'s `aiohasupervisor==` pin). Run
  read-only from this devcontainer against a live board (writes no state):

  ```
  ssh <board-ip> 'System.cmd("balena-engine", ["exec", "homeassistant",
    "python3", "-c", "<PY>"], stderr_to_stdout: true) |> elem(0) |> IO.puts()'
  ```

  where `<PY>` is:

  ```python
  import dataclasses, json
  from aiohasupervisor.models import root, homeassistant, supervisor, os as os_mod, host, addons, network, mounts
  models = {
      "root.RootInfo": root.RootInfo,
      "homeassistant.HomeAssistantInfo": homeassistant.HomeAssistantInfo,
      "supervisor.SupervisorInfo": supervisor.SupervisorInfo,
      "os.OSInfo": os_mod.OSInfo,
      "host.HostInfo": host.HostInfo,
      "addons.StoreInfo": addons.StoreInfo,
      "network.NetworkInfo": network.NetworkInfo,
      "mounts.MountsInfo": mounts.MountsInfo,
  }
  out = {
      key: [
          {"n": f.name, "req": f.default is dataclasses.MISSING and f.default_factory is dataclasses.MISSING}
          for f in dataclasses.fields(cls)
      ]
      for key, cls in models.items()
  }
  out["_version"] = __import__("aiohasupervisor").__version__
  print(json.dumps(out))
  ```

  `StoreInfo` lives in `aiohasupervisor.models.addons`, NOT a `models.store`
  module (there isn't one in 0.6.0) — a naive `from aiohasupervisor.models
  import StoreInfo; print(StoreInfo.__module__)` is the way to re-confirm
  that if it ever needs re-checking. Save the output to
  `test/fixtures/aiohasupervisor-0.6.0-contract.json` (rename the file to
  match the new version), replacing the `-0.6.0-` in this module's alias
  below.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "fixtures",
                  "aiohasupervisor-0.6.0-contract.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  # {fixture key, router path}
  @model_endpoints [
    {"root.RootInfo", "/info"},
    {"homeassistant.HomeAssistantInfo", "/core/info"},
    {"supervisor.SupervisorInfo", "/supervisor/info"},
    {"os.OSInfo", "/os/info"},
    {"host.HostInfo", "/host/info"},
    {"addons.StoreInfo", "/store"},
    {"network.NetworkInfo", "/network/info"},
    {"mounts.MountsInfo", "/mounts"}
  ]

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "every required aiohasupervisor 0.6.0 field is present on the wire" do
    for {fixture_key, path} <- @model_endpoints do
      required_fields =
        @fixture
        |> Map.fetch!(fixture_key)
        |> Enum.filter(& &1["req"])
        |> Enum.map(& &1["n"])

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

  test "the fixture itself covers exactly the 8 models Core's hassio coordinator gathers" do
    assert Map.keys(@fixture) |> Enum.reject(&(&1 == "_version")) |> Enum.sort() ==
             Enum.map(@model_endpoints, &elem(&1, 0)) |> Enum.sort()
  end
end
