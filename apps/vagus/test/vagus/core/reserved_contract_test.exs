defmodule Vagus.Core.ReservedContractTest do
  @moduledoc """
  Contract test for `Vagus.Core.Reserved`: every view Core actually registers
  under `/api/hassio*`, and every command it registers in its reserved
  domains, must be refused to a proxied caller: by `Vagus.API.Authz`, which
  decides both proxy legs, by `Vagus.API.Dispatcher` and
  `Vagus.API.Tiers.blacklisted?/1` on the Supervisor-side path, and by
  `Vagus.Core.Transport.build/6` on the Core-side one.

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

  alias Vagus.API.{Authz, Dispatcher, ExploitFilter, Tiers}
  alias Vagus.API.CoreProxy.WSBridge
  alias Vagus.Core.{Reserved, Transport}
  alias Vagus.ReservedSpellings

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

  # The one caller the proxy admits, so a refusal below is the reservation's
  # and not the caller's.
  @app {:addon, %{slug: "contract", homeassistant_api: true}}

  defp authorize_view(principal, segments, decoded),
    do:
      Authz.authorize(principal, {:rest, :core_api, "POST", segments}, %{
        leg: :core_api,
        decoded_segments: decoded
      })

  defp authorize_command(principal, command),
    do:
      Authz.authorize(principal, {:ws, :core_api, command, %{"type" => command}}, %{
        leg: :core_api,
        decoded_segments: nil
      })

  # `%68` for a leading `h`: reserved to Core, which decodes it, and not to a
  # literal match.
  defp encoded(["api", "h" <> rest | tail]), do: ["api", "%68" <> rest | tail]

  describe "every Core hassio view" do
    test "is blacklisted by the evaluator, for every principal and in either spelling" do
      for url <- @urls,
          family <- ["core", "homeassistant"],
          principal <- [@app, :supervisor, :anonymous] do
        plain = [family | concrete(url)]
        spelled = [family | url |> concrete() |> encoded()]

        assert authorize_view(principal, plain, plain) == {:error, :blacklisted},
               "#{Enum.join(plain, "/")} (Core #{url}) is reachable through the proxy"

        assert authorize_view(principal, spelled, plain) == {:error, :blacklisted},
               "#{Enum.join(spelled, "/")} (Core #{url}) is reachable through the proxy"

        # The other way round, so the raw spelling is shown to be checked too.
        assert authorize_view(principal, plain, spelled) == {:error, :blacklisted}

        # `%68assio` as the decoded spelling is what `%2568assio` was sent as.
        assert authorize_view(principal, spelled, spelled) == {:error, :blacklisted}
      end
    end

    # Core's router does not collapse `.` segments, but nothing here may rest
    # on that. Before `api` a dot makes a path that is not the proxy's at all.
    test "is denied with a `.` segment at each position, by the evaluator and the dispatcher" do
      for url <- @urls, family <- ["core", "homeassistant"] do
        ["api" | rest] = concrete(url)

        for at <- 0..length(rest), dot <- [".", "%2e", "%2E"] do
          raw = [family, "api" | List.insert_at(rest, at, dot)]
          decoded = Enum.map(raw, &URI.decode/1)
          path = "/" <> Enum.join(raw, "/")

          for principal <- [@app, :supervisor, :anonymous] do
            assert authorize_view(principal, raw, decoded) == {:error, :blacklisted},
                   "#{path} (Core #{url}) is reachable through the proxy"
          end

          conn = Dispatcher.call(Plug.Test.conn(:post, path), Dispatcher.init([]))
          assert conn.status == 403, "#{path} (Core #{url}) got past the dispatcher"

          assert_raise Reserved.Error, fn ->
            Transport.build(
              {:socket, "/run/os/core.sock"},
              :proxied,
              :post,
              "/api/" <> Enum.join(tl(tl(raw)), "/")
            )
          end
        end
      end
    end

    test "is denied when it takes more than one decode to read, by all three" do
      for url <- @urls,
          {label, tail} <- url |> concrete() |> tl() |> ReservedSpellings.multiply_encoded(),
          family <- ["core", "homeassistant"] do
        path = "/#{family}/api/#{tail}"
        raw = String.split(path, "/", trim: true)
        decoded = path |> URI.decode() |> String.split("/", trim: true)

        for principal <- [@app, :supervisor, :anonymous] do
          assert authorize_view(principal, raw, decoded) == {:error, :blacklisted},
                 "#{path} (Core #{url}, #{label}) is reachable through the proxy"
        end

        conn = Dispatcher.call(Plug.Test.conn(:post, path), Dispatcher.init([]))
        assert conn.status == 403, "#{path} (Core #{url}, #{label}) got past the dispatcher"

        assert_raise Reserved.Error, fn ->
          Transport.build({:socket, "/run/os/core.sock"}, :proxied, :post, "/api/" <> tail)
        end
      end
    end

    # A path the dispatcher passes and the proxy then refuses is a 500. With
    # no token the proxy's own answer is a 401, so a 403 is the dispatcher's.
    test "is judged alike by the dispatcher, the evaluator and the transport, at every depth" do
      tails =
        for url <- @urls,
            [view | more] = url |> concrete() |> tl(),
            subject <- [view, "states", "x" <> view],
            layers <- 1..8,
            at <- [0, byte_size(subject) - 1],
            wrap <- ["", "./", "%2e/", "%252e%252F", "states/"] do
          <<before::binary-size(^at), char::binary-size(1), rest::binary>> = subject
          spelled = before <> ReservedSpellings.layered(char, layers) <> rest
          wrap <> Enum.join([spelled | more], "/")
        end

      for tail <- Enum.uniq(tails), family <- ["core", "homeassistant"] do
        path = "/#{family}/api/#{tail}"
        raw = String.split(path, "/", trim: true)
        decoded = path |> URI.decode() |> String.split("/", trim: true)

        evaluator = authorize_view(@app, raw, decoded) == {:error, :blacklisted}
        dispatcher = Dispatcher.call(Plug.Test.conn(:post, path), Dispatcher.init([])).status

        transport =
          try do
            Transport.build({:socket, "/run/os/core.sock"}, :proxied, :post, "/api/" <> tail)
            false
          rescue
            Reserved.Error -> true
          end

        assert dispatcher == if(evaluator, do: 403, else: 401), path
        assert transport == evaluator, path
      end
    end

    test "leaves its neighbours to the caller's grant" do
      for family <- ["core", "homeassistant"],
          rest <- [["states"], ["states", "sensor.hassio_cpu"], ["services", "hassio", "x"]] do
        segments = [family, "api" | rest]
        assert authorize_view(@app, segments, segments) == :ok
      end
    end

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

  describe "decoding is bounded" do
    # `Vagus.API.ExploitFilter` reads the same eight layers and answers 400
    # past them, so the dispatcher never brings a deeper path here.
    test "eight layers are read: a reserved view is found, anything else is not reserved" do
      assert Reserved.view?(["api", ReservedSpellings.layered("h", 8) <> "assio_auth"])
      refute Reserved.view?(["api", "states", "a" <> ReservedSpellings.layered("A", 8)])
      refute Reserved.path?("/api/states/a" <> ReservedSpellings.layered("A", 8))

      for tail <- [
            "#{ReservedSpellings.layered("h", 8)}assio_auth",
            "states/a#{ReservedSpellings.layered("A", 8)}"
          ] do
        refute ExploitFilter.harmful_path?("/core/api/" <> tail)
      end
    end

    test "a path still encoded after eight is refused, whatever it would have read as" do
      for layers <- [9, 10, 40], subject <- ["hassio_auth", "states"] do
        <<first::binary-size(1), rest::binary>> = subject
        segment = ReservedSpellings.layered(first, layers) <> rest

        assert Reserved.view?(["api", segment])
        assert Reserved.view?(["api", "states", segment])
        assert Reserved.path?("/api/states/" <> segment)
        assert Tiers.blacklisted?(["core", "api", "states", segment])

        assert authorize_view(@app, ["core", "api", segment], ["core", "api", segment]) ==
                 {:error, :blacklisted}

        assert ExploitFilter.harmful_path?("/core/api/" <> segment)
      end
    end

    # Each layer costs two bytes, so a request line can carry thousands.
    test "a path of nothing but layers is refused without being read to the end" do
      segment = "%" <> String.duplicate("25", 4_900) <> "41"

      {micros, reserved?} = :timer.tc(fn -> Reserved.view?(["api", "states", segment]) end)

      assert reserved?
      assert micros < 250_000
    end

    test "a path with no escape in it is judged as written" do
      assert Reserved.view?(["api", "hassio_auth"])
      refute Reserved.view?(["api", "states", "hassio_auth"])
      refute Reserved.view?(["api"])
      refute Reserved.view?([])
      refute Reserved.view?(["states", "hassio_auth"])
    end
  end

  describe "every Core hassio WS command" do
    test "is reserved" do
      for command <- @ws_commands do
        assert Reserved.command?(command), "#{command} would be relayed to Core as the Supervisor"
      end
    end

    # Core dispatches each element of an array frame as its own command, so
    # the reservation has to hold inside a batch too.
    test "is refused by the proxy when wrapped in a batch frame" do
      for command <- @ws_commands do
        frame = Jason.encode!([%{"id" => 1, "type" => command}])

        assert WSBridge.screen(frame, @app) == {:refuse, nil},
               "[#{command}] would be relayed to Core as the Supervisor"
      end
    end

    test "is refused by the proxy alone, under its own id" do
      for command <- @ws_commands do
        frame = Jason.encode!(%{"id" => 9, "type" => command})

        assert WSBridge.screen(frame, @app) == {:refuse, 9},
               "#{command} would be relayed to Core as the Supervisor"
      end
    end

    # A frame Core's own schema would accept for `supervisor/api`: the one
    # shape the proxy does not refuse, and it still does not relay it.
    test "is never relayed, however well formed" do
      for command <- @ws_commands do
        frame =
          Jason.encode!(%{
            "id" => 9,
            "type" => command,
            "endpoint" => "/supervisor/info",
            "method" => "get"
          })

        case WSBridge.screen(frame, @app) do
          {:call, 9, _request} -> assert command == "supervisor/api"
          {:refuse, 9} -> assert command != "supervisor/api"
        end
      end
    end

    # `supervisor/api` is the one the evaluator sets aside to be answered
    # here; it is no more relayed than the rest.
    test "is never allowed by the evaluator, to the one caller the proxy admits" do
      for command <- @ws_commands do
        expected =
          if command == "supervisor/api",
            do: {:intercept, :supervisor_api},
            else: {:error, :blacklisted}

        assert authorize_command(@app, command) == expected,
               "#{command} would be relayed to Core as the Supervisor"
      end
    end

    test "is refused by the evaluator to every other principal" do
      for command <- @ws_commands, principal <- [:supervisor, :anonymous] do
        assert {:error, _refusal} = authorize_command(principal, command)
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
        assert authorize_command(@app, command) == :ok
        assert WSBridge.screen(Jason.encode!(%{"id" => 1, "type" => command}), @app) == :relay
      end
    end
  end
end
