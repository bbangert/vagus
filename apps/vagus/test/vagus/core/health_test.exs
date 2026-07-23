defmodule Vagus.Core.HealthTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.Health

  ## Helpers — injected probe scripting via a fixed-per-test Agent, same
  ## get_and_update-a-queue pattern as client_test.exs's FakeCore.

  defp start_script(entries) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> entries end]}})
  end

  defp scripted_probe(agent, default) do
    fn ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {default, []}
      end)
    end
  end

  describe "await_healthy/1 with an injected probe" do
    test "up immediately -> :healthy" do
      probe = fn -> :ok end
      assert Health.await_healthy(probe: probe, interval: 10, deadline: 200) == :healthy
    end

    test "fails a few times then succeeds -> :healthy" do
      script = start_script([{:error, :econnrefused}, {:error, :econnrefused}])
      probe = scripted_probe(script, :ok)

      assert Health.await_healthy(probe: probe, interval: 10, deadline: 5_000) == :healthy
    end

    test "never succeeds -> :timeout" do
      probe = fn -> {:error, :econnrefused} end
      assert Health.await_healthy(probe: probe, interval: 10, deadline: 50) == :timeout
    end
  end

  describe "check/1 with an injected probe" do
    test ":ok -> :healthy" do
      assert Health.check(probe: fn -> :ok end) == :healthy
    end

    test "{:error, _} -> :unhealthy" do
      assert Health.check(probe: fn -> {:error, :timeout} end) == :unhealthy
    end
  end

  describe "default probe (hermetic, real Bandit server, no injected :probe)" do
    defmodule FakePlug do
      @moduledoc false
      use Plug.Router

      plug(:match)
      plug(:dispatch)

      get "/manifest.json" do
        send_resp(conn, 200, "{}")
      end

      get "/unavailable" do
        send_resp(conn, 503, "")
      end
    end

    setup do
      bandit = start_supervised!({Bandit, plug: FakePlug, port: 0})
      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
      %{port: port}
    end

    test "a real 200 response is healthy", %{port: port} do
      url = "http://127.0.0.1:#{port}/manifest.json"
      assert Health.check(url: url) == :healthy
      assert Health.await_healthy(url: url, interval: 10, deadline: 200) == :healthy
    end

    test "a real non-2xx response is unhealthy", %{port: port} do
      url = "http://127.0.0.1:#{port}/unavailable"
      assert Health.check(url: url) == :unhealthy
    end

    test "an unreachable port is unhealthy" do
      # Listen-then-immediately-close an ephemeral port so nothing answers
      # on it - same TOCTOU-minimizing trick as
      # addon/watchdog/probe_test.exs's `refused_port/0`.
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      url = "http://127.0.0.1:#{port}/manifest.json"
      assert Health.check(url: url) == :unhealthy
    end
  end
end
