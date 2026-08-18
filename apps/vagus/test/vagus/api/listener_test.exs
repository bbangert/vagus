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

      assert options[:thousand_island_options] == [
               num_acceptors: 2,
               read_timeout: 900_000,
               supervisor_options: [name: Vagus.API.Listener.Bandit]
             ]
    end

    test "the child registers a name, so a restarted manager can find it" do
      options = Listener.bandit_options(listener_name: :some_listener)

      assert options[:thousand_island_options][:supervisor_options] == [name: :some_listener]
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

  describe "retry_now/1" do
    test "an unregistered name is a quiet no-op, not an exit" do
      # :host, mix test and :api_server_enabled false all leave the name free.
      assert Listener.retry_now(:vagus_listener_never_started) == :ok
    end

    test "a manager that has not bound yet attempts again immediately" do
      parent = self()

      starter = fn _sup, _options ->
        send(parent, :attempt)
        {:error, :eaddrnotavail}
      end

      capture_log(fn ->
        # A retry interval far longer than this test: any second attempt can
        # only be the nudge, never the timer.
        manager = start_listener(starter: starter, retry_ms: 60_000, name: nil)

        assert_receive :attempt, 500
        refute_receive :attempt, 100

        assert Listener.retry_now(manager) == :ok
        assert_receive :attempt, 500
      end)
    end

    test "a manager that is already listening ignores it" do
      parent = self()

      starter = fn _sup, _options ->
        send(parent, :attempt)
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end

      capture_log(fn ->
        manager = start_listener(starter: starter, retry_ms: 60_000, name: nil)

        assert_receive :attempt, 500
        assert Listener.retry_now(manager) == :ok
        refute_receive :attempt, 200
      end)
    end
  end

  describe "accepting?/1" do
    # An ephemeral loopback socket, not 172.30.32.2 — that address exists on
    # a device with the hassio bridge up and nowhere else.
    test "true against a socket that is listening, false once it is not" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
      {:ok, port} = :inet.port(socket)

      assert Listener.accepting?(ip: {127, 0, 0, 1}, port: port)

      :ok = :gen_tcp.close(socket)
      refute Listener.accepting?(ip: {127, 0, 0, 1}, port: port)
    end

    test "with no :api_bind_ip it probes Bandit's wildcard bind on loopback" do
      Application.delete_env(:vagus, :api_bind_ip)

      {:ok, socket} = :gen_tcp.listen(0, active: false)
      {:ok, port} = :inet.port(socket)
      Application.put_env(:vagus, :api_port, port)

      assert Listener.accepting?()

      :ok = :gen_tcp.close(socket)
      refute Listener.accepting?()
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
         Keyword.merge(
           [
             name: nil,
             supervisor: listener_supervisor(),
             listener_name: unique_listener_name(),
             retry_ms: 10
           ],
           opts
         )},
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

  # Every real-socket test gets its own registered child name — the default
  # is a single global atom, and adoption would otherwise make one test's
  # listener visible to the next.
  defp unique_listener_name, do: :"vagus_listener_test_#{System.unique_integer([:positive])}"

  describe "against a real socket" do
    test "the ip: option reaches the listening socket" do
      {:ok, sup} =
        start_supervised({DynamicSupervisor, name: :vagus_listener_real_sup},
          id: :vagus_listener_real_sup
        )

      listener =
        capture_log_returning(fn ->
          start_supervised!(
            {Listener,
             name: nil,
             supervisor: sup,
             listener_name: unique_listener_name(),
             ip: {127, 0, 0, 1},
             port: 0,
             plug: EchoPlug},
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
             listener_name: unique_listener_name(),
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

    test "a crash of the manager leaves its listener adoptable, not orphaned" do
      # `restart: :temporary` means nothing else will ever pick this child up:
      # a replacement manager that could not find it would bind again and get
      # :eaddrinuse forever, with the live listener unmonitored.
      {:ok, sup} =
        start_supervised({DynamicSupervisor, name: :vagus_listener_adopt_sup},
          id: :vagus_listener_adopt_sup
        )

      name = unique_listener_name()
      parent = self()

      first =
        capture_log_returning(fn ->
          start_supervised!(
            {Listener,
             name: nil,
             supervisor: sup,
             listener_name: name,
             ip: {127, 0, 0, 1},
             port: 0,
             plug: EchoPlug,
             retry_ms: 50},
            id: :vagus_listener_adopt_first,
            restart: :temporary
          )
        end)

      assert %{listener_pid: bandit} = :sys.get_state(first)
      assert Process.whereis(name) == bandit

      Process.exit(first, :kill)

      starter = fn _sup, _options ->
        send(parent, :bind_attempt)
        {:error, :eaddrinuse}
      end

      log =
        capture_log(fn ->
          second =
            start_supervised!(
              {Listener,
               name: nil,
               supervisor: sup,
               listener_name: name,
               ip: {127, 0, 0, 1},
               port: 0,
               plug: EchoPlug,
               retry_ms: 50,
               starter: starter},
              id: :vagus_listener_adopt_second
            )

          assert %{listener_pid: ^bandit} = :sys.get_state(second)
          refute_receive :bind_attempt, 200

          # The monitor is real, not just the pid in state: the adopted
          # listener dying puts the replacement back on its retry loop.
          Process.exit(bandit, :kill)
          assert_receive :bind_attempt, 1_000
        end)

      assert log =~ "adopting the running listener"
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
               listener_name: unique_listener_name(),
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
