defmodule Vagus.App.AuthIndexTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Vagus.Resource.Harness

  alias Vagus.App.AuthIndex
  alias Vagus.Resource.{Runtime, Store, TestInstance, Verdict}

  defmodule Tokened do
    @moduledoc """
    Owns `:tokened`: each resource has a token in its spec, and is ready
    once the index knows that token as its own. A pass that finds it
    unknown puts it.
    """
    @behaviour Vagus.Resource.Controller

    @impl true
    def kind, do: :tokened
    @impl true
    def condition_types, do: [:ready]

    @impl true
    def observe(%{name: name, spec: %{"token" => token}}, context),
      do: %{known?: AuthIndex.lookup(token, instance: context.instance) == {:ok, name}}

    @impl true
    def reconcile(_tokened, %{known?: true}), do: {Verdict.new(ready: {true, :known}), []}

    def reconcile(_tokened, %{known?: false}),
      do: {Verdict.new(ready: {false, :unknown}), [{:action, :put, nil}]}

    @impl true
    def act(:put, nil, %{resource: %{name: name, spec: %{"token" => token}}} = context) do
      Vagus.Resource.Harness.record(context, name, :put)
      AuthIndex.put(name, token, instance: context.instance)
    end
  end

  defp start_index(_context \\ %{}) do
    instance = TestInstance.name()
    pid = start_supervised!({AuthIndex, instance: instance})
    %{i: [instance: instance], pid: pid}
  end

  defp token(n), do: "token-" <> Base.encode16(:crypto.hash(:md5, inspect(n)), case: :lower)

  describe "put, lookup and remove" do
    setup :start_index

    test "a token put is its app's from the moment put returns", %{i: i} do
      assert AuthIndex.lookup(token(1), i) == :error
      assert AuthIndex.put("a", token(1), i) == :ok
      assert AuthIndex.lookup(token(1), i) == {:ok, "a"}
      assert AuthIndex.lookup(token(2), i) == :error
    end

    test "a second token for an app replaces the first, and leaves no row of it", %{i: i} do
      :ok = AuthIndex.put("a", token(1), i)
      :ok = AuthIndex.put("b", token(9), i)
      :ok = AuthIndex.put("a", token(2), i)

      assert AuthIndex.lookup(token(1), i) == :error
      assert AuthIndex.lookup(token(2), i) == {:ok, "a"}
      assert AuthIndex.lookup(token(9), i) == {:ok, "b"}
      assert :ets.info(AuthIndex.table(i[:instance]), :size) == 2
    end

    test "putting the same token again changes nothing", %{i: i} do
      :ok = AuthIndex.put("a", token(1), i)
      before = :ets.tab2list(AuthIndex.table(i[:instance]))

      assert AuthIndex.put("a", token(1), i) == :ok
      assert :ets.tab2list(AuthIndex.table(i[:instance])) == before
      assert AuthIndex.lookup(token(1), i) == {:ok, "a"}
    end

    test "a token is one app's: put for another it is no longer the first's", %{i: i} do
      :ok = AuthIndex.put("a", token(1), i)
      :ok = AuthIndex.put("b", token(1), i)

      assert AuthIndex.lookup(token(1), i) == {:ok, "b"}
      # The first app has no token now, so removing it takes nothing of "b".
      assert AuthIndex.remove("a", i) == :ok
      assert AuthIndex.lookup(token(1), i) == {:ok, "b"}
    end

    test "remove forgets the app's token, and is the same done twice or for nobody", %{i: i} do
      :ok = AuthIndex.put("a", token(1), i)
      :ok = AuthIndex.put("b", token(2), i)

      assert AuthIndex.remove("a", i) == :ok
      assert AuthIndex.lookup(token(1), i) == :error
      assert AuthIndex.lookup(token(2), i) == {:ok, "b"}
      assert AuthIndex.remove("a", i) == :ok
      assert AuthIndex.remove("never", i) == :ok
      assert :ets.info(AuthIndex.table(i[:instance]), :size) == 1
    end

    test "a lookup is one table read and never waits for the process", %{i: i, pid: pid} do
      :ok = AuthIndex.put("a", token(1), i)
      :sys.suspend(pid)

      assert AuthIndex.lookup(token(1), i) == {:ok, "a"}
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
      :sys.resume(pid)
    end

    test "what is no token is nobody's, and is never put", %{i: i} do
      :ok = AuthIndex.put("a", token(1), i)

      # The last is the same bytes to a hash, and still no token.
      for not_a_token <- ["", nil, :token, 7, {:ok, "t"}, [token(1)]] do
        assert AuthIndex.lookup(not_a_token, i) == :error
      end

      for not_a_token <- ["", nil, 7, [token(2)], %{}] do
        assert AuthIndex.put("b", not_a_token, i) == {:error, :invalid}
      end

      for not_a_name <- [nil, :a, 7, ["a"]] do
        assert AuthIndex.put(not_a_name, token(3), i) == {:error, :invalid}
      end

      assert AuthIndex.lookup(token(3), i) == :error

      assert :ets.tab2list(AuthIndex.table(i[:instance])) == [
               {:crypto.hash(:sha256, token(1)), "a"}
             ]
    end

    test "a row is the token's SHA-256 and the app, and nothing else", %{i: i} do
      :ok = AuthIndex.put("a", token(1), i)
      :ok = AuthIndex.put("b", token(2), i)

      assert Enum.sort(:ets.tab2list(AuthIndex.table(i[:instance]))) ==
               Enum.sort([
                 {:crypto.hash(:sha256, token(1)), "a"},
                 {:crypto.hash(:sha256, token(2)), "b"}
               ])
    end

    test "putting an app's own token again deletes nothing, so no reader can miss it", %{
      i: i,
      pid: pid
    } do
      :ok = AuthIndex.put("a", token(1), i)
      digest = :crypto.hash(:sha256, token(1))

      :erlang.trace_pattern({:ets, :delete, 2}, true, [])
      :erlang.trace(pid, true, [:call])

      :ok = AuthIndex.put("a", token(1), i)
      :ok = AuthIndex.put("a", token(2), i)

      :erlang.trace(pid, false, [:call])
      :erlang.trace_pattern({:ets, :delete, 2}, false, [])
      delivered = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^delivered}, 2_000

      # One delete in all: the old token's, when another replaced it.
      assert_received {:trace, ^pid, :call, {:ets, :delete, [_table, ^digest]}}
      refute_received {:trace, ^pid, :call, {:ets, :delete, _args}}
    end

    test "many writers at once leave one row an app, each its last", %{i: i} do
      1..200
      |> Task.async_stream(
        fn n ->
          app = "app#{rem(n, 20)}"
          :ok = AuthIndex.put(app, token({app, 1}), i)
          :ok = AuthIndex.put(app, token({app, 2}), i)
        end,
        max_concurrency: 50
      )
      |> Stream.run()

      for n <- 0..19 do
        assert AuthIndex.lookup(token({"app#{n}", 2}), i) == {:ok, "app#{n}"}
        assert AuthIndex.lookup(token({"app#{n}", 1}), i) == :error
      end

      assert :ets.info(AuthIndex.table(i[:instance]), :size) == 20
    end

    # A stress test: what pins the rule is the test above.
    test "readers never miss a token while others are written, or it is put again", %{i: i} do
      :ok = AuthIndex.put("steady", token(:steady), i)
      test = self()

      readers =
        for _ <- 1..8 do
          spawn_link(fn ->
            misses =
              Enum.count(1..20_000, fn _ ->
                AuthIndex.lookup(token(:steady), i) != {:ok, "steady"}
              end)

            send(test, {:misses, self(), misses})
          end)
        end

      for n <- 1..500 do
        :ok = AuthIndex.put("churn", token(n), i)
        :ok = AuthIndex.put("steady", token(:steady), i)
        if rem(n, 50) == 0, do: :ok = AuthIndex.remove("churn", i)
      end

      for reader <- readers, do: assert_receive({:misses, ^reader, 0}, 10_000)
    end
  end

  describe "with no process" do
    test "nobody is known, and a write says it was not made" do
      i = [instance: TestInstance.name()]

      assert AuthIndex.lookup(token(1), i) == :error
      assert AuthIndex.put("a", token(1), i) == {:error, :unavailable}
      assert AuthIndex.remove("a", i) == {:error, :unavailable}
    end

    test "a write that the process does not answer in time says so too, and may have been made" do
      %{i: i, pid: pid} = start_index()
      :sys.suspend(pid)

      started = System.monotonic_time(:millisecond)
      assert AuthIndex.put("a", token(1), [timeout: 20] ++ i) == {:error, :unavailable}
      assert AuthIndex.remove("b", [timeout: 20] ++ i) == {:error, :unavailable}
      # The timeout given, and not the default of seconds.
      assert System.monotonic_time(:millisecond) - started < 2_000

      :sys.resume(pid)
      :sys.get_state(pid)
      assert AuthIndex.lookup(token(1), i) == {:ok, "a"}
    end

    test "when it is killed every token is unknown, and its replacement knows none" do
      %{i: i, pid: pid} = start_index()
      :ok = AuthIndex.put("a", token(1), i)
      {:ok, supervisor} = ExUnit.fetch_test_supervisor()

      TestInstance.kill_observed(pid, supervisor)

      replacement = Process.whereis(AuthIndex.name(i[:instance]))
      assert is_pid(replacement) and replacement != pid
      assert AuthIndex.lookup(token(1), i) == :error
      assert :ets.info(AuthIndex.table(i[:instance]), :size) == 0

      assert AuthIndex.put("a", token(1), i) == :ok
      assert AuthIndex.lookup(token(1), i) == {:ok, "a"}
    end
  end

  describe "no token is ever held or logged" do
    setup :start_index

    test "not in the table, the process's state or its messages", %{i: i, pid: pid} do
      :erlang.trace(pid, true, [:receive])
      :ok = AuthIndex.put("a", token(1), i)
      :ok = AuthIndex.put("a", token(2), i)
      :ok = AuthIndex.remove("a", i)
      :ok = AuthIndex.put("b", token(3), i)
      :erlang.trace(pid, false, [:receive])

      messages = collect_traces(pid)
      assert length(messages) >= 4

      held =
        inspect({messages, :sys.get_state(pid), :ets.tab2list(AuthIndex.table(i[:instance]))},
          limit: :infinity,
          printable_limit: :infinity
        )

      for n <- 1..3, do: refute(held =~ token(n))
    end

    # A task that fails at once may be gone before it is monitored, and the
    # monitor then says only that there is no such process.
    defp watched do
      receive do
        :watched -> :ok
      end
    end

    test "not in what a caller that fails logs, whatever it passed", %{i: i} do
      tasks = start_supervised!(Task.Supervisor)
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          for {app, secret} <- [{nil, token(:a)}, {:not_a_name, token(:b)}, {"app", token(:c)}] do
            {:ok, task} =
              Task.Supervisor.start_child(tasks, fn ->
                watched()
                # A match that fails, in a function whose arguments are no token.
                :done = AuthIndex.put(app, secret, i)
              end)

            ref = Process.monitor(task)
            send(task, :watched)
            assert_receive {:DOWN, ^ref, :process, ^task, {{:badmatch, _result}, _stack}}, 2_000
          end

          {:ok, task} =
            Task.Supervisor.start_child(tasks, fn ->
              watched()
              {:ok, :nobody} = AuthIndex.lookup(token(:d), i)
            end)

          ref = Process.monitor(task)
          send(task, :watched)
          assert_receive {:DOWN, ^ref, :process, ^task, {{:badmatch, :error}, _stack}}, 2_000
          Logger.flush()
        end)

      # The crash reports are there, and say what failed.
      assert log =~ "MatchError"
      assert log =~ "{:error, :invalid}"
      for which <- [:a, :b, :c, :d], do: refute(log =~ token(which))
    end

    test "not in what is logged when the process dies of a request", %{i: i, pid: pid} do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          :ok = AuthIndex.put("a", token(1), i)
          :ok = AuthIndex.put("a", token(2), i)
          ref = Process.monitor(pid)
          catch_exit(GenServer.call(pid, :not_a_request))
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
          Logger.flush()
        end)

      # The crash report shows the state and the last message.
      assert log =~ "not_a_request"
      refute log =~ token(1)
      refute log =~ token(2)
    end
  end

  describe "the application's own instance" do
    test "has the table, first among the services: after the lanes, before the pull worker" do
      order =
        Vagus.Resource.Supervisor
        |> Supervisor.which_children()
        |> Enum.reverse()
        |> Enum.map(&elem(&1, 0))

      place = fn id -> Enum.find_index(order, &(&1 == id)) end

      # A pull worker that ends takes everything after it along, and the
      # table must not be among that.
      assert place.(AuthIndex) == place.(Vagus.Resource.Lanes) + 1
      assert place.(AuthIndex) < place.(Vagus.App.Pulls)

      assert place.(Vagus.App.Pulls.tasks(Vagus.Resource)) <
               place.(Vagus.Resource.Controllers.Supervisor)

      assert AuthIndex.lookup(token(:nobody)) == :error
      assert :ets.info(AuthIndex.table(Vagus.Resource), :protection) == :protected
    end
  end

  describe "under the resource supervisor" do
    setup do
      sys = start_system(controllers: [Tokened], services: &[{AuthIndex, instance: &1}])

      for name <- ["a", "b", "c"],
          do: given_ready(sys, {:tokened, name, %{"token" => token(name)}})

      %{sys: sys}
    end

    test "stands before the controllers", %{sys: sys} do
      children =
        for {id, _pid, _type, _modules} <-
              Supervisor.which_children(Module.concat(sys.instance, Supervisor)),
            do: id

      # `which_children/1` lists the last started first.
      assert Enum.find_index(children, &(&1 == Vagus.Resource.Controllers.Supervisor)) <
               Enum.find_index(children, &(&1 == AuthIndex))

      assert Enum.find_index(children, &(&1 == AuthIndex)) <
               Enum.find_index(children, &(&1 == Vagus.Resource.Lanes))
    end

    test "a pull worker that ends leaves it, and every token, as it was" do
      sys =
        start_system(
          controllers: [Tokened],
          services: &[{AuthIndex, instance: &1}],
          pulls: [engine: [socket: Vagus.Test.FakeEngine.socket_path()]]
        )

      given_ready(sys, {:tokened, "a", %{"token" => token("kept")}})
      index = Process.whereis(AuthIndex.name(sys.instance))
      runtime = Process.whereis(Runtime.name(sys.instance, Tokened))
      worker = Process.whereis(Vagus.App.Pulls.name(sys.instance))
      :sys.suspend(index)

      TestInstance.kill_observed(worker, Process.whereis(Module.concat(sys.instance, Supervisor)))

      # The suspended index can take no put, so a row found here is the one
      # that was there before the kill, not one a restarted runtime wrote.
      assert AuthIndex.lookup(token("kept"), sys.i) == {:ok, "a"}
      assert Process.whereis(AuthIndex.name(sys.instance)) == index
      assert Process.whereis(Vagus.App.Pulls.name(sys.instance)) != worker
      assert Process.whereis(Runtime.name(sys.instance, Tokened)) != runtime
      :sys.resume(index)
      settle(sys)
    end

    test "a pass puts its resource's token, once", %{sys: sys} do
      assert Enum.sort(journal(sys)) == [{"a", :put}, {"b", :put}, {"c", :put}]
      for name <- ["a", "b", "c"], do: assert(AuthIndex.lookup(token(name), sys.i) == {:ok, name})
    end

    test "when it is replaced the runtime is too, and every token is put back unasked", %{
      sys: sys
    } do
      runtime = Process.whereis(Runtime.name(sys.instance, Tokened))
      index = Process.whereis(AuthIndex.name(sys.instance))
      supervisor = Process.whereis(Module.concat(sys.instance, Supervisor))

      TestInstance.kill_observed(index, supervisor)

      assert Process.whereis(AuthIndex.name(sys.instance)) != index
      assert Process.whereis(Runtime.name(sys.instance, Tokened)) != runtime

      # Nothing asks for these passes but the new runtime's own listing.
      settle(sys)

      for name <- ["a", "b", "c"], do: assert(AuthIndex.lookup(token(name), sys.i) == {:ok, name})

      assert Enum.frequencies(journal(sys)) == %{
               {"a", :put} => 2,
               {"b", :put} => 2,
               {"c", :put} => 2
             }
    end

    test "a resource whose token changes has only the new one known", %{sys: sys} do
      {:ok, _} = Store.update_spec(:tokened, "a", %{"token" => token(:renewed)}, sys.i)
      settle(sys)

      assert AuthIndex.lookup(token(:renewed), sys.i) == {:ok, "a"}
      assert AuthIndex.lookup(token("a"), sys.i) == :error
    end
  end

  defp collect_traces(pid) do
    delivered = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^delivered}, 2_000
    drain_traces(pid, [])
  end

  defp drain_traces(pid, seen) do
    receive do
      {:trace, ^pid, :receive, message} -> drain_traces(pid, [message | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end
end
