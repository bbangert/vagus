defmodule Vagus.IngressTest do
  @moduledoc """
  IW-P2-T1: `Vagus.Ingress` — session store (§B1) and token resolution, plus
  dynamic ingress ports (§B3.2) as app directory keys. Every test starts its
  own privately-named instance and drives time via an injected `:clock` fn
  (backed by an `Agent`) rather than sleeping.
  """
  use ExUnit.Case, async: true

  import Vagus.AppFixtures, only: [app_info: 1, forget_app: 1, install_app: 2]

  alias Vagus.Addon.Config
  alias Vagus.App.Steps
  alias Vagus.Ingress

  defp start_clock(initial_ms \\ 0) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> initial_ms end]}})
  end

  defp advance(agent, ms), do: Agent.update(agent, &(&1 + ms))

  defp clock_fn(agent), do: fn -> Agent.get(agent, & &1) end

  defp start_ingress(opts \\ []) do
    name = :"ingress_#{System.unique_integer([:positive])}"
    start_supervised!({Ingress, Keyword.put(opts, :name, name)}, id: make_ref())
  end

  defp fixture_config(slug, ingress? \\ false) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test",
        "version" => "1.0",
        "slug" => slug,
        "description" => "d",
        "arch" => ["aarch64"],
        "ingress" => ingress?
      })

    config
  end

  describe "create_session/1 + validate_session/2" do
    test "token is 128 lowercase hex chars, and valid immediately" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress)
      assert token =~ ~r/\A[0-9a-f]{128}\z/
      assert :ok = Ingress.validate_session(token, ingress)
    end

    test "still valid at just under 15 minutes with no renewal" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress)
      advance(clock, 15 * 60 * 1000 - 1)
      assert :ok = Ingress.validate_session(token, ingress)
    end

    test "expires at 15 minutes + 1s with no renewal, and is pruned" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress)
      advance(clock, 15 * 60 * 1000 + 1_000)

      assert :error = Ingress.validate_session(token, ingress)
      assert Ingress.session_count(ingress) == 0
    end

    test "unknown token is :error" do
      ingress = start_ingress()
      assert :error = Ingress.validate_session("deadbeef", ingress)
    end

    test "sliding renewal: validate at +10m, then +10m more, then idle +16m expires" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress)

      advance(clock, 10 * 60 * 1000)
      assert :ok = Ingress.validate_session(token, ingress)

      # Window slid to +25m; a naive fixed-TTL check (created at 0, TTL 15m)
      # would already consider this expired — proving the renewal is real.
      advance(clock, 10 * 60 * 1000)
      assert :ok = Ingress.validate_session(token, ingress)

      # Idle from +20m (last renewal) to +36m — well past another 15m window.
      advance(clock, 16 * 60 * 1000)
      assert :error = Ingress.validate_session(token, ingress)
    end

    test "session_count reflects live, unexpired sessions" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, _t1} = Ingress.create_session(ingress)
      {:ok, _t2} = Ingress.create_session(ingress)
      assert Ingress.session_count(ingress) == 2

      advance(clock, 15 * 60 * 1000 + 1_000)
      assert Ingress.session_count(ingress) == 0
    end
  end

  # The Core `user_id` from `POST /ingress/session` — the only identity a
  # later proxied ingress request can be attributed to.
  describe "create_session/2 + session_user/2" do
    test "records the user id passed at creation" do
      ingress = start_ingress()

      {:ok, token} = Ingress.create_session(ingress, user_id: "user-abc")

      assert {:ok, "user-abc"} = Ingress.session_user(token, ingress)
    end

    test "no opts records no user" do
      ingress = start_ingress()

      {:ok, token} = Ingress.create_session(ingress)

      assert {:ok, nil} = Ingress.session_user(token, ingress)
    end

    test "a non-binary user id is recorded as nil, not stored verbatim" do
      ingress = start_ingress()

      {:ok, token} = Ingress.create_session(ingress, user_id: %{"nope" => true})

      assert {:ok, nil} = Ingress.session_user(token, ingress)
    end

    test "an unknown token is :error" do
      ingress = start_ingress()
      assert :error = Ingress.session_user("deadbeef", ingress)
    end

    test "an expired token is :error" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress, user_id: "user-abc")
      advance(clock, 15 * 60 * 1000 + 1_000)

      assert :error = Ingress.session_user(token, ingress)
    end

    # Inspection, not use: a lookup must not renew the session (the proxy
    # path already slid the window via `validate_session/2` earlier in the
    # same request).
    test "does not slide the expiry" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress, user_id: "user-abc")

      advance(clock, 14 * 60 * 1000)
      assert {:ok, "user-abc"} = Ingress.session_user(token, ingress)

      # +15m from creation, only 1m after the lookup: still expired, which it
      # would not be had the lookup renewed the window.
      advance(clock, 61 * 1000)
      assert :error = Ingress.validate_session(token, ingress)
    end

    test "validate_session/2 preserves the recorded user across a renewal" do
      clock = start_clock()
      ingress = start_ingress(clock: clock_fn(clock))

      {:ok, token} = Ingress.create_session(ingress, user_id: "user-abc")

      advance(clock, 10 * 60 * 1000)
      assert :ok = Ingress.validate_session(token, ingress)

      assert {:ok, "user-abc"} = Ingress.session_user(token, ingress)
    end
  end

  # Installs under the global app tree, with slugs no other test uses.
  describe "resolve_token/2" do
    test "resolves an ingress-capable add-on's token to its slug" do
      slug = "core_ingress_test_#{System.unique_integer([:positive])}"
      install_app(fixture_config(slug, true), [])
      {:ok, %{ingress_token: token}} = app_info(slug)

      ingress = start_ingress()
      assert {:ok, ^slug} = Ingress.resolve_token(token, ingress)

      # The key goes with the app.
      forget_app(slug)
      assert :error = Ingress.resolve_token(token, ingress)
    end

    test "a non-ingress add-on's token does not resolve" do
      slug = "core_ingress_test_#{System.unique_integer([:positive])}"
      install_app(fixture_config(slug, false), [])
      {:ok, %{ingress_token: token}} = app_info(slug)

      ingress = start_ingress()
      assert :error = Ingress.resolve_token(token, ingress)
    end

    test "an unknown token is :error" do
      ingress = start_ingress()
      assert :error = Ingress.resolve_token("not-a-real-token", ingress)
    end
  end

  # The global directory: each app holds its own port as a key, so the
  # candidates here are drawn from a range no other test uses.
  describe "dynamic ingress ports" do
    defp port_base, do: 64_000 + rem(System.unique_integer([:positive]), 1_000)

    defp app_with_port(port) do
      slug = "core_ingress_port_#{System.unique_integer([:positive])}"
      config = fixture_config(slug, true) |> Map.put(:ingress_port, 0)
      install_app(config, ingress_port: port)
      slug
    end

    defp pick(candidates, probe \\ fn _ip, _port -> :free end) do
      counter = :counters.new(1, [])

      rand = fn ->
        idx = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        Enum.at(candidates, idx, List.last(candidates))
      end

      Steps.run(:port, %{rand: rand, port_probe: probe})
    end

    test "an app's saved port is its key, and goes with the app" do
      port = port_base()
      slug = app_with_port(port)
      assert [{_pid, ^slug}] = Registry.lookup(Vagus.App.Directory, {:ingress_port, port})
      assert {:ok, %{ingress_port: ^port}} = app_info(slug)

      forget_app(slug)
      assert [] = Registry.lookup(Vagus.App.Directory, {:ingress_port, port})
    end

    test "a candidate another app holds is skipped" do
      port = port_base()
      app_with_port(port)
      assert {:ok, next} = pick([port, port + 1])
      assert next == port + 1
    end

    test "a candidate the port probe reports :listening forces a re-roll" do
      port = port_base()
      probe = fn _ip, candidate -> if candidate == port, do: :listening, else: :free end
      assert {:ok, next} = pick([port, port + 2], probe)
      assert next == port + 2
    end

    test "exhausting 100 tries is {:error, :no_free_port}" do
      assert {:error, :no_free_port} = pick([port_base()], fn _ip, _port -> :listening end)
    end
  end
end
