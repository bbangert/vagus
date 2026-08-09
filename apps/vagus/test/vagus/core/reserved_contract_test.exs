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

  ## Regenerating the fixture

  Required on every Core version bump (`Vagus.Core.Versions`' pinned
  `"default"`). From this devcontainer, against the tag being adopted:

  ```
  TAG=2026.7.4
  gh api "repos/home-assistant/core/git/trees/$TAG?recursive=1" --jq '.tree[].path' \\
    | grep -E '^homeassistant/components/hassio/.*\\.py$' \\
    | while read -r p; do curl -sf "https://raw.githubusercontent.com/home-assistant/core/$TAG/$p"; done \\
    | grep -oE 'url = "/api/[^"]+"' | sed 's/url = //' | tr -d '"' | sort -u
  ```

  Save as `test/fixtures/core-<TAG>-hassio-views.json` and point
  `@fixture_path` at it. Scanning Core's source rather than a running
  instance is deliberate — it needs no device, it is reproducible from a tag
  by anyone, and a view registered but never exercised still shows up.

  A NEW url appearing here that this test then refuses is the normal case and
  needs no action beyond regenerating. A new url that this test FAILS on
  means Core has put a Supervisor-only view outside the `hassio` prefix, and
  the namespace rule no longer describes reality — that is a design question
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
                  "core-2026.7.3-hassio-views.json"
                ])
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()
  @urls @fixture["urls"]

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
end
