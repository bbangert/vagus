defmodule Vagus.Addon.Watchdog.ProbeTest do
  @moduledoc """
  M4B-IW-P1-T3, `docs/contract-2026.7-m4b-ingress-watchdog.md` §B7. Every
  state-machine test injects `:state`, `:manager`, `:host_ip_fun`, and
  `:probe_fun` so nothing touches a real docker daemon, the real
  `Vagus.Addon.State` singleton, or a real network — same hermetic-injection
  style as `watchdog_test.exs`.

  Ticks are driven **manually** (`send(pid, :tick)`) against a huge
  `:interval` (so the module's own scheduled tick never fires mid-test) —
  more deterministic than racing a tiny real timer, and it exercises exactly
  the same `handle_info(:tick, _)` clause the real scheduler would.

  `FakeManager` (bottom of file) forwards each `restart/2` call as a message
  to whichever pid `config :vagus, :probe_test_pid` names, the same
  app-env-as-cross-process-test-knob trick `watchdog_test.exs`'s
  `FakeManager` uses — needed because the restart runs inside this module's
  own `Task`, a different process from the test.

  A last `describe` block exercises the real (non-injected) `:probe_fun`
  default against real listening `Bandit` servers — hermetic, no Internet,
  no daemon — to prove the §B7.3 TCP/HTTP/HTTPS probe rules themselves
  (3xx-is-unhealthy in particular) rather than just the surrounding state
  machine.
  """

  use ExUnit.Case, async: false

  alias Vagus.Addon.{Config, State}
  alias Vagus.Addon.Watchdog.Probe
  alias Vagus.Addon.Watchdog.ProbeTest.FakeManager

  ## Helpers

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
  defp unique_slug(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp start_state do
    start_supervised!({State, name: unique_name("probe_state"), persist_path: nil})
  end

  defp fixture_config(slug, overrides) do
    base = %{
      "name" => "Test",
      "version" => "1",
      "slug" => slug,
      "description" => "d",
      "arch" => ["amd64"]
    }

    {:ok, config} = Config.parse(Map.merge(base, overrides))
    config
  end

  defp seed(state_pid, slug, lifecycle_state, watchdog?, config_overrides) do
    config = fixture_config(slug, config_overrides)
    :ok = State.put(config, lifecycle_state, server: state_pid)
    :ok = State.put_setting(slug, :watchdog, watchdog?, state_pid)
    config
  end

  # Huge :interval — the automatic scheduled tick (Process.send_after in
  # init/1) would only fire long after any test finishes; every tick in
  # these tests is a manual `send(pid, :tick)` instead.
  defp start_probe(opts) do
    name = unique_name("probe")
    start_supervised!({Probe, Keyword.merge([name: name, interval: 3_600_000], opts)})
  end

  # A `:probe_fun` that reports the spec it was handed (`[HOST]` already
  # substituted) back to the test, so the default `:host_ip_fun`'s decision is
  # observable without dialling anything.
  defp probe_spy(pid) do
    fn spec ->
      send(pid, {:spec, spec})
      :healthy
    end
  end

  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
  end

  # The restart Task's completion message (clearing `state.tasks`) races the
  # test process's next `send(pid, :tick)` — wait for it to actually settle
  # (peeking at the GenServer's own state via :sys.get_state/1) so the next
  # manual tick isn't spuriously skipped as "restart still in flight".
  defp wait_until_idle(pid, slug) do
    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).tasks, slug) end)
  end

  setup do
    Application.put_env(:vagus, :probe_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:vagus, :probe_test_pid)
      Application.delete_env(:vagus, :probe_test_hang?)
    end)

    %{state_pid: start_state()}
  end

  ## 1: two-strikes-then-restart, counter resets

  test "two consecutive unhealthy ticks -> exactly one restart; counter resets", %{
    state_pid: state_pid
  } do
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> {:ok, "1.2.3.4"} end,
        probe_fun: fn _spec -> :unhealthy end
      )

    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500
    wait_until_idle(pid, slug)

    # Counter reset to 0 by the restart: a single further unhealthy tick
    # alone must not immediately restart again.
    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500
  end

  ## 2: unhealthy-then-healthy -> no restart, counter reset

  test "unhealthy then healthy -> no restart, counter resets", %{state_pid: state_pid} do
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})

    healthy? = :counters.new(1, [])

    probe_fun = fn _spec ->
      if :counters.get(healthy?, 1) == 1, do: :healthy, else: :unhealthy
    end

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> {:ok, "1.2.3.4"} end,
        probe_fun: probe_fun
      )

    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    :counters.put(healthy?, 1, 1)
    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    # If the counter hadn't reset on the healthy tick, this single unhealthy
    # tick would be strike 2 (since it'd already be at 1) and restart.
    :counters.put(healthy?, 1, 0)
    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500
  end

  ## 3: watchdog:false / :stopped / no-template entries are never probed

  test "watchdog:false, :stopped, and template-less entries are never probed", %{
    state_pid: state_pid
  } do
    test_pid = self()
    probe_fun = fn _spec -> send(test_pid, :probe_called) end
    host_ip_fun = fn _slug -> send(test_pid, :host_ip_called) end

    slug_off = unique_slug("probe_off")
    seed(state_pid, slug_off, :started, false, %{"watchdog" => "tcp://[HOST]:1234"})

    slug_stopped = unique_slug("probe_stopped")
    seed(state_pid, slug_stopped, :stopped, true, %{"watchdog" => "tcp://[HOST]:1234"})

    slug_no_template = unique_slug("probe_notpl")
    seed(state_pid, slug_no_template, :started, true, %{})

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: host_ip_fun,
        probe_fun: probe_fun
      )

    send(pid, :tick)

    refute_receive :probe_called, 200
    refute_receive :host_ip_called, 200
  end

  ## 4: host_ip_fun :error -> probe_fun skipped, no restart

  test "host_ip_fun :error -> probe_fun is never called, no restart", %{state_pid: state_pid} do
    test_pid = self()
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})

    probe_fun = fn _spec -> send(test_pid, :probe_called) end

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> :error end,
        probe_fun: probe_fun
      )

    send(pid, :tick)

    refute_receive :probe_called, 200
    refute_receive {:restart, ^slug}, 100
  end

  ## 5: counters pruned when a slug leaves State

  test "counters are pruned when a slug leaves State (no crash, no stale restart)", %{
    state_pid: state_pid
  } do
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> {:ok, "1.2.3.4"} end,
        probe_fun: fn _spec -> :unhealthy end
      )

    # First strike.
    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    :ok = State.delete(slug, state_pid)

    # Slug is gone; must prune quietly, not crash.
    send(pid, :tick)
    assert Process.alive?(pid)

    # Re-seed fresh (e.g. a reinstall) and prove the counter really was
    # pruned to 0, not merely skipped this tick: a single unhealthy tick
    # must not immediately restart (it would if the old count of 1 had
    # survived).
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})
    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500
  end

  ## 6 (W1): a manager.restart call that never returns is bounded, not wedged

  test "manager.restart blocking forever is bounded, not left wedged", %{state_pid: state_pid} do
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})
    Application.put_env(:vagus, :probe_test_hang?, true)

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> {:ok, "1.2.3.4"} end,
        probe_fun: fn _spec -> :unhealthy end,
        attempt_timeout_ms: 20
      )

    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500

    # The bounded call timed out (killed after ~20ms) instead of hanging
    # forever — proves the task actually completed rather than staying
    # wedged in `st.tasks`.
    wait_until_idle(pid, slug)
  end

  ## 7 (W1): the sequence-deadline failsafe recovers a wedge outside the
  ## per-attempt bound

  test "the sequence-deadline failsafe clears a wedged restart task and accepts a fresh restart after",
       %{state_pid: state_pid} do
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})
    Application.put_env(:vagus, :probe_test_hang?, true)

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> {:ok, "1.2.3.4"} end,
        probe_fun: fn _spec -> :unhealthy end,
        # Deliberately much larger than the tiny sequence_deadline_ms below,
        # so the deadline (not the per-attempt bound) is what recovers this.
        attempt_timeout_ms: 10_000,
        sequence_deadline_ms: 30
      )

    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100

    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500

    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).tasks, slug) end)

    Application.put_env(:vagus, :probe_test_hang?, false)

    # A fresh unhealthy streak must be accepted again (not left permanently
    # skipped by `maybe_probe/2`'s in-flight check) — manager.restart/2 is
    # actually called a second time.
    send(pid, :tick)
    refute_receive {:restart, ^slug}, 100
    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500
  end

  ## 9 (issue #39): shutdown_check gates the whole tick

  test "shutdown_check: true skips the whole tick — no probe, no restart, even for a slug already at 1 strike",
       %{state_pid: state_pid} do
    test_pid = self()
    slug = unique_slug("probe")
    seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})

    probe_fun = fn _spec ->
      send(test_pid, :probe_called)
      :unhealthy
    end

    pid =
      start_probe(
        state: state_pid,
        manager: FakeManager,
        host_ip_fun: fn _slug -> {:ok, "1.2.3.4"} end,
        probe_fun: probe_fun,
        shutdown_check: fn -> false end
      )

    # Bank one strike with the seam reading false, exactly like a real tick
    # would — this proves the shutdown gate below isn't just "skip because
    # nothing was eligible yet".
    send(pid, :tick)
    assert_receive :probe_called, 200
    refute_receive {:restart, ^slug}, 100

    :sys.replace_state(pid, fn st -> %{st | shutdown_check: fn -> true end} end)

    # This tick would otherwise be strike 2 (restart) — the shutdown gate
    # must suppress it entirely, including the probe call itself.
    send(pid, :tick)
    refute_receive :probe_called, 200
    refute_receive {:restart, ^slug}, 100

    :sys.replace_state(pid, fn st -> %{st | shutdown_check: fn -> false end} end)

    # State was left untouched by the skipped tick: the failure counter is
    # still at 1, so this next unhealthy tick is strike 2 and restarts.
    send(pid, :tick)
    assert_receive {:restart, ^slug}, 500
  end

  # No separate "shutdown_check: false leaves normal behavior intact" test:
  # every other test in this file omits `:shutdown_check` entirely, so they
  # already exercise the default seam (`Vagus.Host.Shutdown.in_flight?/0`,
  # persistent_term unset -> false) end to end — see e.g. test 1 above.

  ## 8: default :probe_fun against real listening Bandit servers (§B7.3)

  describe "default probe_fun (hermetic, real sockets, no injected :probe_fun)" do
    defmodule FakePlug do
      @moduledoc false
      use Plug.Router

      plug(:match)
      plug(:dispatch)

      get "/" do
        send_resp(conn, 200, "ok")
      end

      get "/redirect" do
        conn
        |> put_resp_header("location", "/")
        |> send_resp(302, "")
      end
    end

    setup do
      bandit = start_supervised!({Bandit, plug: FakePlug, port: 0})
      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
      %{port: port}
    end

    # W4: returns the still-open listener alongside its port — closing it is
    # left to the caller, right before the tick that actually attempts the
    # connection, to shrink the TOCTOU window between "port freed" and
    # "connection attempted" as much as possible. A busy CI box reusing the
    # ephemeral port inside that (now much smaller) gap would flip this
    # test's "connection refused" assumption to a real connect — vanishingly
    # rare within microseconds; the accepted fallback is a CI re-run, not a
    # bulletproof guarantee.
    defp refused_port do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      {port, listen}
    end

    test "200 response -> healthy, no restart", ctx do
      state_pid = ctx.state_pid
      slug = unique_slug("probe")

      seed(state_pid, slug, :started, true, %{
        "watchdog" => "http://[HOST]:[PORT:#{ctx.port}]/"
      })

      pid =
        start_probe(
          state: state_pid,
          manager: FakeManager,
          host_ip_fun: fn _slug -> {:ok, "127.0.0.1"} end
        )

      send(pid, :tick)
      send(pid, :tick)
      refute_receive {:restart, ^slug}, 200
    end

    test "302 response -> unhealthy (§B7.3: 3xx counts as unhealthy)", ctx do
      state_pid = ctx.state_pid
      slug = unique_slug("probe")

      seed(state_pid, slug, :started, true, %{
        "watchdog" => "http://[HOST]:[PORT:#{ctx.port}]/redirect"
      })

      pid =
        start_probe(
          state: state_pid,
          manager: FakeManager,
          host_ip_fun: fn _slug -> {:ok, "127.0.0.1"} end
        )

      send(pid, :tick)
      send(pid, :tick)
      assert_receive {:restart, ^slug}, 500
    end

    test "connection refused -> unhealthy", ctx do
      state_pid = ctx.state_pid
      slug = unique_slug("probe")
      {port, listen} = refused_port()

      seed(state_pid, slug, :started, true, %{
        "watchdog" => "http://[HOST]:[PORT:#{port}]/"
      })

      pid =
        start_probe(
          state: state_pid,
          manager: FakeManager,
          host_ip_fun: fn _slug -> {:ok, "127.0.0.1"} end
        )

      # W4: close as late as possible, immediately before the first tick
      # that actually attempts the connection — see refused_port/0's comment.
      :gen_tcp.close(listen)

      send(pid, :tick)
      send(pid, :tick)
      assert_receive {:restart, ^slug}, 500
    end

    test "tcp probe against a listening port -> healthy, no restart", ctx do
      state_pid = ctx.state_pid
      slug = unique_slug("probe")

      seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:#{ctx.port}"})

      pid =
        start_probe(
          state: state_pid,
          manager: FakeManager,
          host_ip_fun: fn _slug -> {:ok, "127.0.0.1"} end
        )

      send(pid, :tick)
      send(pid, :tick)
      refute_receive {:restart, ^slug}, 200
    end
  end

  ## 9: default :host_ip_fun (no injected one) — must reach the identical
  ## loopback-or-gateway verdict `Vagus.API.IngressProxy.resolve_ip/3` does,
  ## or a host-networked add-on bound only to the gateway is probed on
  ## loopback, looks dead every tick, and gets restart-looped.

  describe "default host_ip_fun (host_network add-ons, hermetic)" do
    test "resolves loopback when the watchdog port listens there", %{state_pid: state_pid} do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      on_exit(fn -> :gen_tcp.close(listen) end)
      {:ok, port} = :inet.port(listen)
      slug = unique_slug("probe")

      seed(state_pid, slug, :started, true, %{
        "host_network" => true,
        "watchdog" => "tcp://[HOST]:#{port}"
      })

      pid = start_probe(state: state_pid, manager: FakeManager, probe_fun: probe_spy(self()))
      send(pid, :tick)

      assert_receive {:spec, %{host: "127.0.0.1", port: ^port}}, 500
    end

    test "falls back to the bridge gateway when loopback refuses", %{state_pid: state_pid} do
      # `172.30.32.1` doesn't exist on a CI host; the injected `:probe_fun`
      # means it is never dialled, only decided upon.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)
      slug = unique_slug("probe")

      seed(state_pid, slug, :started, true, %{
        "host_network" => true,
        "watchdog" => "tcp://[HOST]:#{port}"
      })

      pid = start_probe(state: state_pid, manager: FakeManager, probe_fun: probe_spy(self()))
      send(pid, :tick)

      gateway = Vagus.Network.gateway()
      assert_receive {:spec, %{host: ^gateway, port: ^port}}, 500
    end

    test "a bridge-mode add-on still resolves through the container lookup", %{
      state_pid: state_pid
    } do
      slug = unique_slug("probe")
      seed(state_pid, slug, :started, true, %{"watchdog" => "tcp://[HOST]:1234"})

      pid = start_probe(state: state_pid, manager: FakeManager, probe_fun: probe_spy(self()))
      send(pid, :tick)

      # No `addon_<slug>` container exists, so the inspect fails and the tick
      # is skipped — proving the host-address shortcut wasn't taken.
      refute_receive {:spec, _}, 200
      refute_receive {:restart, ^slug}, 100
    end
  end

  defmodule FakeManager do
    @moduledoc false

    def restart(slug, _opts) do
      case Application.get_env(:vagus, :probe_test_pid) do
        pid when is_pid(pid) -> send(pid, {:restart, slug})
        _ -> :ok
      end

      # W1 test hook: simulates a manager call that never returns (e.g.
      # blocked on the per-slug :global.trans lock), to prove
      # attempt_timeout_ms/sequence_deadline_ms actually bound it.
      if Application.get_env(:vagus, :probe_test_hang?, false) do
        Process.sleep(:infinity)
      end

      {:ok, %{}}
    end
  end
end
