defmodule Vagus.Core.ReservedContractTest do
  @moduledoc """
  Contract test for `Vagus.Core.Reserved`: every view Core actually registers
  under `/api/hassio*` must be refused to a proxied caller, on both the
  Supervisor-side path (`Vagus.API.Tiers.blacklisted?/1`) and the Core-side
  one (`Vagus.Core.Transport.build/6`).

  This exists because the bug it guards against was never a coding error —
  it was a list going stale. Upstream's deny named `hassio/` when that was
  the only view there was; Core later added `hassio_auth` and
  `hassio_auth/password_reset` on its own release cadence, and nothing on the
  Supervisor side noticed until an audit found an add-on could reset the
  owner's password through the proxy. A test that restates our own rule back
  to us would have stayed green through all of it, so this one checks the
  rule against a fixture dumped from Core's source instead.

  ## What tells us Core moved

  Nothing in this repo pins a Core version — `Vagus.Core.Versions` reports
  whatever `version.home-assistant.io/stable.json` currently serves — so
  this fixture cannot detect drift on its own, and a test asserting only
  that it agrees with its own filename would go stale silently along with
  it. `.github/workflows/core-contract-drift.yml` is the part that notices:
  weekly (and on demand), it re-derives both lists from whatever Core stable
  serves *today* and fails when they differ from this fixture.

  ## Regenerating the fixture

  `scripts/core-hassio-surface.sh <tag>` prints the JSON — the same script
  the drift workflow runs, so a regeneration cannot disagree with the check
  that demanded it. Save as `test/fixtures/core-<tag>-hassio-views.json` and
  point `@fixture_path` at it.

  Scanning Core's source rather than a running instance is deliberate: it
  needs no device, it is reproducible from a tag by anyone, and a view
  registered but never exercised still shows up.

  A new url or command appearing that this test then refuses is the normal
  case and needs nothing beyond regenerating. One that this test FAILS on
  means Core has put a Supervisor-privileged endpoint outside the reserved
  names, and the reservation no longer describes reality — a design question
  (`Vagus.Core.Reserved`'s "why a namespace, not a list"), not a fixture
  update.
  """

  use ExUnit.Case, async: true

  alias Vagus.API.Tiers
  alias Vagus.Core.{Reserved, Transport}

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "fixtures",
                  "core-2026.8.1-hassio-views.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()
  @urls @fixture["urls"]
  @ws_commands @fixture["ws_commands"]

  # Same cross-check the aiohasupervisor contract test uses: a fixture saved
  # under a filename that disagrees with the version it was dumped from
  # fails loudly instead of silently redefining the contract.
  @core_version @fixture_path
                |> Path.basename()
                |> String.replace_prefix("core-", "")
                |> String.replace_suffix("-hassio-views.json", "")

  test "the fixture records the Core version its filename claims" do
    assert @fixture["_core_version"] == @core_version
  end

  test "the fixture is not empty and is all `/api/hassio`-prefixed" do
    assert length(@urls) >= 6
    assert Enum.all?(@urls, &String.starts_with?(&1, "/api/hassio"))
  end

  # aiohttp's `{name}` / `{name:regex}` placeholders stand in for one path
  # segment (or, for `{path:.*}`, several); any literal serves to prove the
  # routing decision, which is made on the segment after `api` alone.
  defp concrete(url) do
    url
    |> String.split("/", trim: true)
    |> Enum.map(fn
      "{" <> _rest = _placeholder -> "x"
      literal -> literal
    end)
  end

  describe "every Core hassio view" do
    test "is refused on the Supervisor-side path, under both proxy families" do
      for url <- @urls, family <- ["core", "homeassistant"] do
        segments = concrete(url)

        assert Tiers.blacklisted?([family | segments]),
               "#{family}/#{Enum.join(segments, "/")} (Core #{url}) is reachable through the proxy"
      end
    end

    test "raises when built as a proxied Core request" do
      for url <- @urls do
        path = "/" <> Enum.join(concrete(url), "/")

        assert_raise Reserved.Error, fn ->
          Transport.build({:socket, "/run/os/core.sock"}, :proxied, :post, path)
        end
      end
    end

    test "is still ours to call internally" do
      for url <- @urls do
        path = "/" <> Enum.join(concrete(url), "/")

        assert %Finch.Request{} =
                 Transport.build({:socket, "/run/os/core.sock"}, :internal, :post, path)
      end
    end
  end

  # The two the audit turned on, spelled out rather than left implicit in the
  # loop above: `hassio_auth` is a password-verification oracle running as us,
  # and `hassio_auth/password_reset` resets any HA user's password with no
  # owner check on Core's side.
  test "the account-takeover pair specifically" do
    for path <- [["api", "hassio_auth"], ["api", "hassio_auth", "password_reset"]] do
      assert Reserved.view?(path)
      assert Tiers.blacklisted?(["core" | path])
      assert Tiers.blacklisted?(["homeassistant" | path])
    end
  end

  describe "every Core hassio WS command" do
    test "is reserved" do
      for command <- @ws_commands do
        assert Reserved.command?(command), "#{command} would be relayed to Core as the Supervisor"
      end
    end

    # This list is why the fixture exists. Reading
    # `@websocket_api.ws_require_user(only_supervisor=True)` above
    # `websocket_supervisor_event` suggests the command is `hassio/event`;
    # the type string it actually dispatches on is `WS_TYPE_EVENT`, i.e.
    # `supervisor/event`. A rule written from the handler names alone reads
    # correct and blocks nothing.
    test "the escalating command is in Core's `supervisor` domain, not `hassio`" do
      assert "supervisor/api" in @ws_commands
      refute "hassio/api" in @ws_commands
    end

    test "ordinary Core commands are untouched" do
      for command <- ["get_states", "call_service", "config/auth/list", "subscribe_events"] do
        refute Reserved.command?(command)
      end
    end
  end
end
