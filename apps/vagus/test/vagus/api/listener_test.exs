defmodule Vagus.API.ListenerTest do
  # async: false — the bind-config describe reads/writes the global app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.API.Listener

  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 200, "ok")
  end

  setup do
    original = %{
      ip: Application.get_env(:vagus, :api_bind_ip),
      port: Application.get_env(:vagus, :api_port)
    }

    on_exit(fn ->
      for {key, config} <- [api_bind_ip: :ip, api_port: :port] do
        case Map.fetch!(original, config) do
          nil -> Application.delete_env(:vagus, key)
          value -> Application.put_env(:vagus, key, value)
        end
      end
    end)

    :ok
  end

  describe "bandit_options/1 (the bind)" do
    test "no :api_bind_ip means no ip: option — Bandit's wildcard, as on :host" do
      Application.delete_env(:vagus, :api_bind_ip)
      Application.put_env(:vagus, :api_port, 8888)

      options = Listener.bandit_options()

      refute Keyword.has_key?(options, :ip)
      assert options[:port] == 8888
      assert options[:plug] == Vagus.API.Dispatcher
    end

    test "target.exs's values bind ONLY the hassio anchor, off port 80" do
      # The whole point of B1: nothing of ours may hold :80 any more, and the
      # listener must not be on the wildcard either or the LAN sees it.
      Application.put_env(:vagus, :api_bind_ip, "172.30.32.2")
      Application.put_env(:vagus, :api_port, 8888)

      options = Listener.bandit_options()

      assert options[:ip] == {172, 30, 32, 2}
      assert options[:port] == 8888
      refute options[:port] == 80
    end

    test "an :api_bind_ip tuple is accepted as-is" do
      Application.put_env(:vagus, :api_bind_ip, {172, 30, 32, 2})
      assert Listener.bandit_options()[:ip] == {172, 30, 32, 2}
    end

    test "an unreadable :api_bind_ip degrades to the wildcard rather than no API at all" do
      Application.put_env(:vagus, :api_bind_ip, "not-an-ip")

      log = capture_log(fn -> refute Keyword.has_key?(Listener.bandit_options(), :ip) end)

      assert log =~ "invalid :api_bind_ip"
    end

    test "keeps the compression and Thousand Island settings the surface depends on" do
      options = Listener.bandit_options()

      assert options[:http_options] == [compress: false]
      assert options[:thousand_island_options] == [num_acceptors: 2, read_timeout: 900_000]
    end

    test "explicit opts win over config" do
      Application.put_env(:vagus, :api_bind_ip, "172.30.32.2")
      Application.put_env(:vagus, :api_port, 8888)

      options = Listener.bandit_options(ip: {127, 0, 0, 1}, port: 1234, plug: EchoPlug)

      assert options[:ip] == {127, 0, 0, 1}
      assert options[:port] == 1234
      assert options[:plug] == EchoPlug
    end
  end

  describe "the .2-appears-late race" do
    defp listener_supervisor do
      {:ok, pid} =
        start_supervised(
          {DynamicSupervisor, name: :"nat_test_sup_#{System.unique_integer([:positive])}"},
          id: {:sup, System.unique_integer([:positive])}
        )

      pid
    end

    defp start_listener(opts) do
      start_supervised!(
        {Listener,
         Keyword.merge([name: nil, supervisor: listener_supervisor(), retry_ms: 10], opts)},
        id: {:listener, System.unique_integer([:positive])}
      )
    end

    test "a bind that fails retries instead of crashing the subtree" do
      parent = self()

      starter = fn _sup, _options ->
        send(parent, :attempt)
        {:error, {:shutdown, {:failed_to_start_child, :listener, :eaddrnotavail}}}
      end

      log =
        capture_log(fn ->
          pid = start_listener(starter: starter)

          assert_receive :attempt, 500
          assert_receive :attempt, 500
          assert_receive :attempt, 500
          # The manager is still alive — a failing bind must never escalate.
          assert Process.alive?(pid)
        end)

      assert log =~ "could not bind"
      assert log =~ "eaddrnotavail"
    end

    test "the listener comes up on the attempt after the address appears" do
      parent = self()
      {:ok, appeared} = Agent.start_link(fn -> false end)

      starter = fn _sup, _options ->
        if Agent.get(appeared, & &1) do
          send(parent, :bound)
          {:ok, spawn(fn -> Process.sleep(:infinity) end)}
        else
          send(parent, :attempt)
          {:error, :eaddrnotavail}
        end
      end

      capture_log(fn ->
        start_listener(starter: starter)

        assert_receive :attempt, 500
        Agent.update(appeared, fn _ -> true end)

        assert_receive :bound, 1_000
      end)
    end

    test "a listener that dies later is restarted" do
      parent = self()

      starter = fn _sup, _options ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        send(parent, {:started, pid})
        {:ok, pid}
      end

      capture_log(fn ->
        start_listener(starter: starter)

        assert_receive {:started, first}, 500
        Process.exit(first, :kill)

        assert_receive {:started, second}, 1_000
        refute second == first
      end)
    end

    test "an already_started listener is adopted, not retried against" do
      parent = self()
      existing = spawn(fn -> Process.sleep(:infinity) end)

      starter = fn _sup, _options ->
        send(parent, :attempt)
        {:error, {:already_started, existing}}
      end

      capture_log(fn ->
        start_listener(starter: starter)

        assert_receive :attempt, 500
        refute_receive :attempt, 200
      end)
    end
  end

  defp await_listener(manager, previous, deadline \\ 40) do
    case :sys.get_state(manager) do
      %{listener_pid: pid} when is_pid(pid) and pid != previous ->
        pid

      _not_yet when deadline > 0 ->
        Process.sleep(25)
        await_listener(manager, previous, deadline - 1)
    end
  end

  # `capture_log/1` swallows the return value; these tests need both.
  defp capture_log_returning(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:returned, fun.()}) end)
    receive do: ({:returned, value} -> value)
  end

  describe "against a real socket" do
    test "the ip: option reaches the listening socket" do
      {:ok, sup} =
        start_supervised({DynamicSupervisor, name: :vagus_listener_real_sup},
          id: :vagus_listener_real_sup
        )

      listener =
        capture_log_returning(fn ->
          start_supervised!(
            {Listener, name: nil, supervisor: sup, ip: {127, 0, 0, 1}, port: 0, plug: EchoPlug},
            id: :vagus_listener_real
          )
        end)

      # `start_supervised!` returns once `init/1` has, and the bind happens in
      # the `{:continue, :listen}` after it — this call blocks until it has.
      assert %{listener_pid: bandit} = :sys.get_state(listener)
      assert is_pid(bandit)
      assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
      assert port > 0
    end

    test "the DynamicSupervisor does not restart a crashed listener — this manager does" do
      # Bandit's default child spec is `restart: :permanent`, which would have
      # the supervisor put a replacement on the port behind the manager's
      # back: the manager's own retry then hits :eaddrinuse forever while
      # monitoring a pid nobody owns.
      {:ok, sup} =
        start_supervised({DynamicSupervisor, name: :vagus_listener_own_sup},
          id: :vagus_listener_own_sup
        )

      manager =
        capture_log_returning(fn ->
          start_supervised!(
            {Listener,
             name: nil,
             supervisor: sup,
             ip: {127, 0, 0, 1},
             port: 0,
             plug: EchoPlug,
             retry_ms: 400},
            id: :vagus_listener_own
          )
        end)

      assert %{listener_pid: first} = :sys.get_state(manager)
      ref = Process.monitor(first)

      capture_log(fn ->
        Process.exit(first, :kill)
        assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 500

        # Well inside :retry_ms, so anything back in the supervisor now would
        # be the supervisor's own doing.
        Process.sleep(100)
        assert DynamicSupervisor.which_children(sup) == []

        second = await_listener(manager, first)
        assert [{:undefined, ^second, _type, [Bandit]}] = DynamicSupervisor.which_children(sup)
      end)
    end

    test "an address that does not exist on this host never binds, and never crashes" do
      # 192.0.2.0/24 is TEST-NET-1 — guaranteed not configured here, which is
      # exactly the state 172.30.32.2 is in until the hassio bridge is up.
      {:ok, sup} =
        start_supervised({DynamicSupervisor, name: :vagus_listener_dead_sup},
          id: :vagus_listener_dead_sup
        )

      log =
        capture_log(fn ->
          pid =
            start_supervised!(
              {Listener,
               name: nil,
               supervisor: sup,
               ip: {192, 0, 2, 1},
               port: 0,
               plug: EchoPlug,
               retry_ms: 50},
              id: :vagus_listener_dead
            )

          assert %{listener_pid: nil, attempt: attempt} = :sys.get_state(pid)
          assert attempt >= 1
          assert Process.alive?(pid)
          assert DynamicSupervisor.which_children(sup) == []
        end)

      assert log =~ "could not bind 192.0.2.1:0"
    end
  end
end
