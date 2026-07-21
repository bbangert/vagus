defmodule Vagus.IngressTest do
  @moduledoc """
  IW-P2-T1: `Vagus.Ingress` — session store (§B1) + dynamic port allocator
  (§B3.2). Every test starts its own privately-named instance and drives
  time via an injected `:clock` fn (backed by an `Agent`) rather than
  sleeping.
  """
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, State}
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

  defp start_state(opts \\ []) do
    start_supervised!({State, Keyword.merge([name: nil, persist_path: nil], opts)},
      id: make_ref()
    )
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

  describe "resolve_token/2" do
    test "resolves an ingress-capable add-on's token to its slug" do
      state = start_state()
      config = fixture_config("core_esphome", true)
      :ok = State.put(config, :started, server: state)
      {:ok, %{ingress_token: token}} = State.get("core_esphome", state)

      ingress = start_ingress(state: state)
      assert {:ok, "core_esphome"} = Ingress.resolve_token(token, ingress)
    end

    test "a non-ingress add-on's token does not resolve" do
      state = start_state()
      config = fixture_config("core_mosquitto", false)
      :ok = State.put(config, :started, server: state)
      {:ok, %{ingress_token: token}} = State.get("core_mosquitto", state)

      ingress = start_ingress(state: state)
      assert :error = Ingress.resolve_token(token, ingress)
    end

    test "an unknown token is :error" do
      state = start_state()
      ingress = start_ingress(state: state)
      assert :error = Ingress.resolve_token("not-a-real-token", ingress)
    end
  end

  describe "dynamic_port/2" do
    test "allocates a port in 62000..65500 and persists it" do
      state = start_state()
      config = fixture_config("core_esphome", true)
      :ok = State.put(config, :started, server: state)

      ingress =
        start_ingress(
          state: state,
          rand: fn min, _max -> min end,
          port_probe: fn _, _ -> :free end
        )

      assert {:ok, port} = Ingress.dynamic_port("core_esphome", ingress)
      assert port in 62_000..65_500
      assert {:ok, %{ingress_port: ^port}} = State.get("core_esphome", state)
    end

    test "a second call returns the same (already-persisted) port" do
      state = start_state()
      config = fixture_config("core_esphome", true)
      :ok = State.put(config, :started, server: state)

      call_count = :counters.new(1, [])

      rand = fn min, max ->
        :counters.add(call_count, 1, 1)
        min + rem(:counters.get(call_count, 1), max - min + 1)
      end

      ingress = start_ingress(state: state, rand: rand, port_probe: fn _, _ -> :free end)

      assert {:ok, port1} = Ingress.dynamic_port("core_esphome", ingress)
      assert {:ok, port2} = Ingress.dynamic_port("core_esphome", ingress)
      assert port1 == port2
      # Only the first call should have needed to roll a candidate.
      assert :counters.get(call_count, 1) == 1
    end

    test "a candidate colliding with another slug's port is skipped" do
      state = start_state()
      esphome = fixture_config("core_esphome", true)
      other = fixture_config("core_other", true)
      :ok = State.put(esphome, :started, server: state)
      :ok = State.put(other, :started, server: state)

      # Give "core_other" a fixed port directly.
      :ok = State.put_setting("core_other", :ingress_port, 62_500, state)

      candidates = [62_500, 63_000]
      counter = :counters.new(1, [])

      rand = fn _min, _max ->
        idx = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        Enum.at(candidates, idx)
      end

      ingress = start_ingress(state: state, rand: rand, port_probe: fn _, _ -> :free end)

      assert {:ok, 63_000} = Ingress.dynamic_port("core_esphome", ingress)
    end

    test "a candidate the port_probe reports :listening forces a re-roll" do
      state = start_state()
      config = fixture_config("core_esphome", true)
      :ok = State.put(config, :started, server: state)

      candidates = [62_111, 63_222]
      counter = :counters.new(1, [])

      rand = fn _min, _max ->
        idx = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        Enum.at(candidates, idx)
      end

      probe = fn _ip, port -> if port == 62_111, do: :listening, else: :free end

      ingress = start_ingress(state: state, rand: rand, port_probe: probe)

      assert {:ok, 63_222} = Ingress.dynamic_port("core_esphome", ingress)
    end

    test "unknown slug is {:error, :not_found}" do
      state = start_state()
      ingress = start_ingress(state: state)
      assert {:error, :not_found} = Ingress.dynamic_port("nope", ingress)
    end

    test "exhausting 100 tries is {:error, :no_free_port}" do
      state = start_state()
      config = fixture_config("core_esphome", true)
      :ok = State.put(config, :started, server: state)

      ingress =
        start_ingress(
          state: state,
          rand: fn min, _max -> min end,
          port_probe: fn _, _ -> :listening end
        )

      assert {:error, :no_free_port} = Ingress.dynamic_port("core_esphome", ingress)
    end
  end
end
