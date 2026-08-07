defmodule Vagus.Core.HealthTest do
  # `async: false`: the transport describes below move `:core_base_url` /
  # `:core_socket_path` (process-global application env).
  use ExUnit.Case, async: false

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

  describe "the Finch pool being down (HL1)" do
    test "a probe against a pool that isn't running is :unhealthy, not a crash" do
      # `Finch.request/3` RAISES (`ArgumentError`, unknown registry) rather
      # than returning an error when its pool is gone — reachable whenever
      # the `:rest_for_one` Core subtree restarts, which is exactly when the
      # watchdog probes and when `Vagus.API.CoreProxy` health-gates a
      # proxied request. A crash there means a 5xx instead of the documented
      # 502, and a watchdog that dies instead of recovering Core.
      down = :"never_started_finch_#{System.unique_integer([:positive])}"

      assert Health.check(url: "http://127.0.0.1:1/manifest.json", finch: down) == :unhealthy

      assert Health.await_healthy(
               url: "http://127.0.0.1:1/manifest.json",
               finch: down,
               interval: 10,
               deadline: 50
             ) == :timeout
    end
  end

  describe "default transport resolution (A2 — no hardcoded Core port)" do
    setup do
      prev_base = Application.get_env(:vagus, :core_base_url)

      on_exit(fn ->
        Application.put_env(:vagus, :core_socket_path, nil)

        if is_nil(prev_base),
          do: Application.delete_env(:vagus, :core_base_url),
          else: Application.put_env(:vagus, :core_base_url, prev_base)
      end)

      :ok
    end

    test "with no socket, the probe follows :core_base_url rather than :8123" do
      bandit = start_supervised!({Bandit, plug: __MODULE__.FakePlug, port: 0})
      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

      Application.put_env(:vagus, :core_socket_path, nil)
      Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:#{port}")

      assert Health.check() == :healthy
    end

    test "with the socket present, the probe rides it" do
      path =
        Path.join(System.tmp_dir!(), "vagus_health_#{System.unique_integer([:positive])}.sock")

      on_exit(fn -> File.rm(path) end)

      start_supervised!(
        {Bandit,
         plug: __MODULE__.FakePlug,
         port: 0,
         thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]},
        id: :fake_core_socket
      )

      # Nothing is listening on this TCP base — only the socket can answer.
      Application.put_env(:vagus, :core_base_url, "http://127.0.0.1:1")
      Application.put_env(:vagus, :core_socket_path, path)

      assert Health.check() == :healthy

      # Core going away (socket unlinked) falls back to the — here dead —
      # TCP base rather than reporting a stale :healthy.
      File.rm!(path)
      assert Health.check() == :unhealthy
    end
  end
end
