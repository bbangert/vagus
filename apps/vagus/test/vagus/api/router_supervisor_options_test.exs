defmodule Vagus.API.RouterSupervisorOptionsTest do
  # async: false — like Vagus.API.RouterCoreOptionsTest, these tests mutate
  # the real globally-supervised Vagus.API.SupervisorOptions (the router
  # always writes to the default-named singleton, matching what Core
  # actually posts to at runtime), so they must not race each other.
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, SupervisorOptions, Token}

  # GET /info calls `Vagus.Backend.os().info()` (via `StaticData.root_info/0`)
  # — same order-independence fix `Vagus.API.StaticDataTest` documents:
  # Mox's global mode ties stub ownership to whichever process last called
  # `set_mox_global/1`, and `Vagus.API.RouterBackendTest` reclaims it for
  # itself. Re-claiming ownership and re-stubbing here makes this module
  # order-independent instead of depending on the ambient stub from
  # `test/test_helper.exs` still being alive.
  setup :set_mox_global

  setup do
    stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)

    on_exit(fn ->
      :ok = SupervisorOptions.put(%{"timezone" => nil, "country" => nil, "diagnostics" => nil})
    end)

    :ok
  end

  @opts Router.init([])

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp req_json(conn), do: put_req_header(conn, "content-type", "application/json")
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp post_options(body) do
    conn(:post, "/supervisor/options", Jason.encode!(body)) |> authed() |> req_json() |> call()
  end

  defp get_supervisor_info, do: conn(:get, "/supervisor/info") |> authed() |> call()
  defp get_info, do: conn(:get, "/info") |> authed() |> call()

  describe "persisted fields: save via POST, read back via GET (E5)" do
    test "timezone round-trips through /supervisor/info and /info" do
      conn = post_options(%{"timezone" => "Europe/Amsterdam"})
      assert conn.status == 200
      assert json_body(conn)["data"] == %{}

      assert json_body(get_supervisor_info())["data"]["timezone"] == "Europe/Amsterdam"
      assert json_body(get_info())["data"]["timezone"] == "Europe/Amsterdam"
    end

    test "\"America/Los_Angeles\" still round-trips (W2 bound doesn't break real tz names)" do
      conn = post_options(%{"timezone" => "America/Los_Angeles"})
      assert conn.status == 200

      assert json_body(get_supervisor_info())["data"]["timezone"] == "America/Los_Angeles"
      assert json_body(get_info())["data"]["timezone"] == "America/Los_Angeles"
    end

    test "country round-trips through /supervisor/info" do
      conn = post_options(%{"country" => "NL"})
      assert conn.status == 200

      assert json_body(get_supervisor_info())["data"]["country"] == "NL"
    end

    test "diagnostics round-trips through /supervisor/info, including an explicit false" do
      conn = post_options(%{"diagnostics" => true})
      assert conn.status == 200
      assert json_body(get_supervisor_info())["data"]["diagnostics"] == true

      conn = post_options(%{"diagnostics" => false})
      assert conn.status == 200
      assert json_body(get_supervisor_info())["data"]["diagnostics"] == false
    end
  end

  describe "unknown keys (PREVENT_EXTRA)" do
    test "an unrecognized key is rejected with a 400" do
      conn = post_options(%{"totally_unknown_field" => "nope"})

      assert conn.status == 400
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] =~ "unknown keys"
      assert body["message"] =~ "totally_unknown_field"
    end
  end

  describe "bad types on every declared key -> 400" do
    @bad_type_cases [
      {"channel", 123},
      {"channel", "nightly"},
      {"addons_repositories", "not-a-list"},
      {"addons_repositories", [1, 2]},
      {"timezone", 123},
      {"country", 123},
      {"country", "way-too-long-a-country-code"},
      {"wait_boot", "soon"},
      {"debug", "yes"},
      {"debug_block", "yes"},
      {"logging", "verbose"},
      {"diagnostics", "yes"},
      {"auto_update", "yes"},
      {"detect_blocking_io", "yes"}
    ]

    for {key, bad_value} <- @bad_type_cases do
      test "#{key} = #{inspect(bad_value)} -> 400" do
        conn = post_options(%{unquote(key) => unquote(bad_value)})

        assert conn.status == 400
        body = json_body(conn)
        assert body["result"] == "error"
        assert body["message"] =~ unquote(key)
      end
    end
  end

  # W2 — timezone is served back to every :default-tier caller and
  # survives reboot, so unlike a bare "must be a string" it needed a
  # length/charset bound (security-phase6.md W1).
  describe "timezone bound (W2)" do
    test "a 65-byte string -> 400" do
      conn = post_options(%{"timezone" => String.duplicate("a", 65)})

      assert conn.status == 400
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] =~ "timezone"
    end

    test "a 64-byte string is still accepted (the boundary itself)" do
      value = String.duplicate("a", 64)
      conn = post_options(%{"timezone" => value})

      assert conn.status == 200
      assert json_body(get_supervisor_info())["data"]["timezone"] == value
    end

    test "control characters (ANSI escape) -> 400" do
      conn = post_options(%{"timezone" => "\e[31mEvil"})

      assert conn.status == 400
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] =~ "timezone"
    end

    # A 9-byte ANSI escape fits inside country's 10-byte bound — same
    # leak class as the timezone case above, same rejection.
    test "country with control characters (ANSI escape) -> 400" do
      conn = post_options(%{"country" => "\e[31mEvil"})

      assert conn.status == 400
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] =~ "country"
    end

    test "the 400 body never echoes the rejected value (phase-5 safe_inspect rule)" do
      conn = post_options(%{"timezone" => "\e[31mEvil"})

      refute json_body(conn)["message"] =~ "Evil"
    end
  end

  describe "validated-but-ignored keys (Vagus has no machinery for them)" do
    test "valid values for every non-persisted key still return 200" do
      conn =
        post_options(%{
          "channel" => "beta",
          "addons_repositories" => ["https://example.com/repo"],
          "wait_boot" => 10,
          "debug" => true,
          "debug_block" => true,
          "logging" => "debug",
          "auto_update" => false,
          "detect_blocking_io" => true
        })

      assert conn.status == 200
      assert json_body(conn)["data"] == %{}
    end

    test "none of them leak into /supervisor/info — it stays at StaticData's static defaults" do
      conn =
        post_options(%{
          "channel" => "beta",
          "debug" => true,
          "logging" => "debug",
          "auto_update" => false
        })

      assert conn.status == 200

      data = json_body(get_supervisor_info())["data"]
      # StaticData's Phase 2 statics — unaffected by the validated-then-
      # dropped fields above.
      assert data["channel"] == "stable"
      assert data["debug"] == false
      assert data["logging"] == "info"
      assert data["auto_update"] == true
    end
  end

  describe "empty body" do
    test "an empty POST is still a valid ok no-op" do
      conn = post_options(%{})
      assert conn.status == 200
      assert json_body(conn)["data"] == %{}
    end
  end
end
