defmodule Vagus.App.ServerTest do
  # Starts app processes under the global `Vagus.App.Instances`, with real
  # timers and a stub for the steps.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures

  alias Vagus.App
  alias Vagus.App.File, as: AppFile
  alias Vagus.App.{Instances, Policy, Server}

  @started %{container_id: "c1", ip: "172.30.33.9"}

  setup do
    stub_app_steps()
    app_deadlines(%{})
  end

  defp slug, do: "app_server_#{System.unique_integer([:positive])}"

  defp lookup(key), do: Registry.lookup(Vagus.App.Directory, key)

  defp pid_of(slug) do
    [{pid, _}] = lookup({:slug, slug})
    pid
  end

  defp op(pid, command), do: Task.async(fn -> :gen_statem.call(pid, command, :infinity) end)

  defp step(name) do
    assert_receive {:step, ^name, input, task}, 2_000
    {input, task}
  end

  defp answer(name, outcome) do
    {input, task} = step(name)
    send(task, {:outcome, outcome})
    input
  end

  defp state(pid), do: pid |> :sys.get_state() |> elem(0)
  defp data(pid), do: pid |> :sys.get_state() |> elem(1)

  defp installed(overrides \\ %{}, opts \\ []) do
    slug = slug()
    install_app(app_config(slug, overrides), opts)
    {slug, pid_of(slug)}
  end

  defp started(overrides \\ %{}, opts \\ []) do
    {slug, pid} = installed(overrides, opts)
    t = op(pid, {:start, %{}})
    answer(:start, {:ok, @started})
    assert :ok = Task.await(t)
    {slug, pid}
  end

  describe "the process" do
    test "ensure/1 twice gives the same process" do
      {slug, pid} = installed()
      assert {:ok, ^pid} = Instances.ensure(slug)
    end

    test "with no file it waits in :new for an install, answers nothing, and expires" do
      app_deadlines(%{new: 100})
      slug = slug()
      {:ok, pid} = Instances.ensure(slug)
      ref = Process.monitor(pid)

      assert :new = state(pid)
      assert :error = :gen_statem.call(pid, :info)
      assert {:error, :not_installed} = :gen_statem.call(pid, {:start, %{}})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "killed, it comes back from its file under the same key" do
      slug = slug()
      install_app(app_config(slug), process: false)

      sup =
        start_supervised!(
          {DynamicSupervisor, strategy: :one_for_one, max_restarts: 10, max_seconds: 60}
        )

      {:ok, pid} = DynamicSupervisor.start_child(sup, {Server, slug})
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert new_pid = wait_for_new(slug, pid)
      assert {:ok, %{config: %{slug: ^slug}}} = :gen_statem.call(new_pid, :info)
    end

    test "an EXIT from a linked process that is not its task stops it, to be restarted" do
      {slug, pid} = installed()
      ref = Process.monitor(pid)

      spawn(fn ->
        Process.link(pid)
        exit(:partition_gone)
      end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :partition_gone}
      assert wait_for_new(slug, pid)
    end

    test "an unknown question is answered, not a crash" do
      {_slug, pid} = installed()
      assert {:error, :unknown_question} = :gen_statem.call(pid, :no_such_question)
      assert Process.alive?(pid)
    end

    test "registers the ingress token hash and a dynamic port from its file" do
      config = %{"ingress" => true, "ingress_port" => 0}
      {slug, pid} = installed(config, ingress_port: 62_123)
      {:ok, %{ingress_token: token}} = AppFile.read(slug)

      assert [{^pid, ^slug}] = lookup({:ingress_token, Policy.hash(token)})
      assert [{^pid, ^slug}] = lookup({:ingress_port, 62_123})
    end
  end

  describe "settings" do
    test "a write is on disk before the reply, and refused with no app installed" do
      {slug, pid} = installed()

      assert :ok = :gen_statem.call(pid, {:set, [options: %{"a" => 1}, watchdog: true]})
      assert {:ok, %{user_options: %{"a" => 1}, watchdog: true}} = AppFile.read(slug)
      assert :error = :gen_statem.call(pid, {:set, [nope: 1]})

      {:ok, new} = Instances.ensure(slug())
      assert :error = :gen_statem.call(new, {:set, [watchdog: true]})
    end
  end

  describe "operations" do
    test "start registers the token before its task, then the DNS name and the file" do
      {slug, pid} = installed()
      t = op(pid, {:start, %{}})
      {input, task} = step(:start)

      assert [{^pid, ^slug}] = lookup({:token, Policy.hash(input.token)})
      assert {:busy, :start} = state(pid)
      send(task, {:outcome, {:ok, @started}})
      assert :ok = Task.await(t)

      assert [{^pid, "172.30.33.9"}] = lookup({:dns, Policy.dns_name(slug)})
      assert {:ok, %{state: :started, wanted: :started}} = App.info(slug)
      assert {:ok, %{wanted: :started}} = AppFile.read(slug)
      assert :idle = state(pid)
    end

    test "each change of the reported state is pushed to Core as an addon event" do
      pusher = Process.whereis(Vagus.Core.EventPusher)
      :erlang.trace(pusher, true, [:receive])
      on_exit(fn -> :erlang.trace(pusher, false, [:receive]) end)
      {slug, pid} = installed()

      t = op(pid, {:start, %{}})
      answer(:start, {:ok, @started})
      assert :ok = Task.await(t)
      event = %{"event" => "addon", "slug" => slug, "state" => "started"}
      assert_receive {:trace, ^pusher, :receive, {:"$gen_cast", {:push, ^event}}}, 1_000

      t = op(pid, {:stop, %{}})
      answer(:stop, {:ok, %{was_running: true}})
      assert :ok = Task.await(t)
      event = %{event | "state" => "stopped"}
      assert_receive {:trace, ^pusher, :receive, {:"$gen_cast", {:push, ^event}}}, 1_000
    end

    test "stop drops the token and DNS name before its task" do
      {slug, pid} = started()
      token = data(pid).token
      t = op(pid, {:stop, %{}})
      {_input, task} = step(:stop)

      assert [] = lookup({:token, Policy.hash(token)})
      assert [] = lookup({:dns, Policy.dns_name(slug)})
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert :ok = Task.await(t)

      assert {:ok, %{state: :stopped, wanted: :stopped}} = App.info(slug)
      assert {:ok, %{wanted: :stopped}} = AppFile.read(slug)
    end

    test "restart stops, then starts with a new token" do
      {_slug, pid} = started()
      old = data(pid).token
      t = op(pid, {:restart, %{}})
      answer(:stop, {:ok, %{was_running: true}})
      input = answer(:start, {:ok, %{@started | container_id: "c2"}})

      assert :ok = Task.await(t)
      refute input.token == old
      assert %{container_id: "c2", wanted: :started} = data(pid)
    end

    test "a second command while one runs is busy; questions are still answered" do
      {slug, pid} = installed()
      t = op(pid, {:start, %{}})
      {_input, task} = step(:start)

      assert {:error, :busy} = :gen_statem.call(pid, {:start, %{}})
      assert {:ok, %{config: %{slug: ^slug}}} = :gen_statem.call(pid, :info)
      send(task, {:outcome, {:ok, @started}})
      assert :ok = Task.await(t)
    end

    test "a result carrying another step's ref is dropped" do
      {_slug, pid} = installed()
      t = op(pid, {:start, %{}})
      {_input, task} = step(:start)

      send(pid, {:done, make_ref(), {:error, :stale}})
      assert {:busy, :start} = state(pid)
      send(task, {:outcome, {:ok, @started}})
      assert :ok = Task.await(t)
    end

    test "the deadline is per step: two steps may together outlast one" do
      app_deadlines(%{stop: 300, start: 300})
      {_slug, pid} = started()
      t = op(pid, {:restart, %{}})

      for {name, outcome} <- [stop: {:ok, %{was_running: true}}, start: {:ok, @started}] do
        {_input, task} = step(name)
        Process.sleep(200)
        send(task, {:outcome, outcome})
      end

      assert :ok = Task.await(t)
    end

    test "a step past its deadline is killed and cleaned up by name" do
      app_deadlines(%{start: 100})
      {slug, pid} = installed()
      t = op(pid, {:start, %{}})
      {_input, task} = step(:start)
      ref = Process.monitor(task)

      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 1_000
      answer(:stop, {:ok, %{was_running: false}})
      assert {:error, :timeout} = Task.await(t)
      assert {:ok, %{state: :error}} = App.info(slug)
    end

    test "a step that dies is the same failure, as :died" do
      {_slug, pid} = installed()
      t = op(pid, {:start, %{}})
      {_input, task} = step(:start)
      Process.exit(task, :boom)

      answer(:stop, {:ok, %{was_running: false}})
      assert {:error, :died} = Task.await(t)
      assert :idle = state(pid)
    end

    test "halt kills the step in flight, answers its caller, and stops by name" do
      {_slug, pid} = installed()
      start = op(pid, {:start, %{}})
      {_input, task} = step(:start)
      ref = Process.monitor(task)

      halt = op(pid, {:halt, %{}})
      assert {:error, :shutting_down} = Task.await(start)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}
      answer(:halt_stop, {:ok, :stopped})
      assert :ok = Task.await(halt)

      assert :shutting_down = state(pid)
      assert {:error, :shutting_down} = :gen_statem.call(pid, {:stop, %{}})
      assert :ok = :gen_statem.call(pid, {:resume, %{}})
      assert :idle = state(pid)
    end

    test "install in :new pulls, then writes the file and waits stopped" do
      slug = slug()
      on_exit(fn -> forget_app(slug) end)
      {:ok, pid} = Instances.ensure(slug)
      t = op(pid, {:install, %{config: app_config(slug)}})
      answer(:pull, {:ok, "x/y:1"})

      assert :ok = Task.await(t)
      assert {:ok, %{wanted: :stopped}} = AppFile.read(slug)
      assert {:ok, %{state: :stopped}} = App.info(slug)
      assert {:error, :already_installed} = :gen_statem.call(pid, {:install, %{}})
    end

    test "a failed install leaves no file and no process" do
      slug = slug()
      {:ok, pid} = Instances.ensure(slug)
      ref = Process.monitor(pid)
      t = op(pid, {:install, %{config: app_config(slug)}})
      answer(:pull, {:error, :no_such_image})

      assert {:error, :no_such_image} = Task.await(t)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :error = AppFile.read(slug)
    end

    test "uninstall drops every key before its task and deletes the file last" do
      capture_discovery_pushes()
      {slug, pid} = started()
      :ok = :gen_statem.call(pid, {:provide_service, "svc_#{slug}", %{}})
      {:ok, %{uuid: uuid}, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})
      drain_discovery_pushes()
      ref = Process.monitor(pid)

      t = op(pid, {:uninstall, %{}})
      {_input, task} = step(:stop)
      assert_receive {:discovery_push, :delete, %{uuid: ^uuid}}

      for key <- [{:service, "svc_#{slug}"}, {:discovery, uuid}, {:dns, Policy.dns_name(slug)}],
          do: assert([] = lookup(key))

      assert {:error, :unavailable} = :gen_statem.call(pid, {:add_discovery, "x", %{}})
      assert {:ok, _} = AppFile.read(slug)
      send(task, {:outcome, {:ok, %{was_running: true}}})
      {_input, task} = step(:remove_app)
      assert {:ok, _} = AppFile.read(slug)
      send(task, {:outcome, {:ok, :ok}})

      assert :ok = Task.await(t)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :error = AppFile.read(slug)
    end

    test "a container event during an operation is handled once, after it" do
      {slug, pid} = started(%{}, watchdog: true)
      t = op(pid, {:backup, %{staging_dir: "/nonexistent"}})
      {_input, task} = step(:snapshot)

      send(pid, {:docker_event, %{id: "c1", action: "die", exit_code: 1}})
      assert {:ok, %{state: :started}} = App.info(slug)
      send(task, {:outcome, {:ok, "/nonexistent/a.tar.gz"}})
      assert {:ok, "/nonexistent/a.tar.gz"} = Task.await(t)

      # The watchdog's first retry is immediate; a second replay would count two.
      step(:start)
      assert %{attempt: 1} = data(pid)
    end

    test "a dynamic port the directory gives another app fails the start" do
      {slug, pid} = installed(%{"ingress" => true, "ingress_port" => 0})
      holder = hold_key({:ingress_port, 62_001})
      t = op(pid, {:start, %{}})
      answer(:port, {:ok, 62_001})

      assert {:error, {:ingress_port, {:port_taken, {:ingress_port, 62_001}}}} = Task.await(t)
      assert [{^holder, _}] = lookup({:ingress_port, 62_001})
      assert {:ok, %{ingress_port: nil}} = App.info(slug)
    end
  end

  describe "update" do
    @v1 %{
      "version" => "1",
      "options" => %{"greeting" => "hi"},
      "schema" => %{"greeting" => "str"}
    }

    defp target(slug), do: app_config(slug, %{@v1 | "version" => "2"})

    test "options saved while it pulls reach its start and survive it" do
      {slug, pid} = started(@v1)
      t = op(pid, {:update, %{config: target(slug), job: "job-1"}})
      {input, task} = step(:pull)

      assert :ok = App.set(slug, options: %{"greeting" => "new"})
      assert {input.job, input.stage} == {"job-1", {"pull_image", 20}}
      send(task, {:outcome, {:ok, "x/y:2"}})
      assert %{stage: {"stop", 70}} = answer(:stop, {:ok, %{was_running: true}})
      input = answer(:start, {:ok, @started})
      answer(:reclaim_image, {:ok, :ok})

      assert input.stage == {"start", 90}
      assert input.user_options == %{"greeting" => "new"}
      assert {:ok, %{from: "1", to: "2"}} = Task.await(t)

      assert {:ok, %{config: %{version: "2"}, user_options: %{"greeting" => "new"}}} =
               App.info(slug)
    end

    test "a start that fails on the new version rolls back to the old one" do
      {slug, pid} = started(@v1)
      t = op(pid, {:update, %{config: target(slug)}})
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})
      assert %{config: %{version: "2"}} = answer(:start, {:error, :boom})
      assert %{config: %{version: "1"}} = answer(:start, {:ok, @started})

      assert {:error, {:rolled_back, :boom}} = Task.await(t)
      assert {:ok, %{config: %{version: "1"}, state: :started}} = App.info(slug)
      assert {:ok, %{config: %{version: "1"}}} = AppFile.read(slug)
    end

    test "a rollback that fails too leaves the old version, in error" do
      {slug, pid} = started(@v1)
      t = op(pid, {:update, %{config: target(slug)}})
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})
      answer(:start, {:error, :boom})
      answer(:start, {:error, :boom_again})

      assert {:error, {:rollback_failed, :boom_again}} = Task.await(t)
      assert {:ok, %{config: %{version: "1"}, state: :error}} = App.info(slug)
    end

    test "a stopped app is updated without being started" do
      {slug, pid} = installed(@v1)
      t = op(pid, {:update, %{config: target(slug)}})
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: false}})
      answer(:reclaim_image, {:ok, :ok})

      assert {:ok, %{to: "2"}} = Task.await(t)
      refute_received {:step, :start, _, _}
    end
  end

  describe "format_status/1" do
    test "redacts credentials in the data" do
      data = %{
        slug: "s",
        token: "t0k",
        token_hash: "h",
        user_options: %{"password" => "p"},
        services: %{"mqtt" => %{"password" => "p"}},
        discovery: %{"u" => %{}}
      }

      assert %{data: redacted} = Server.format_status(%{state: :idle, data: data})
      assert redacted.slug == "s"
      refute inspect(redacted) =~ ~s("p")
      refute inspect(redacted) =~ "t0k"
    end

    test "redacts the payload of an event being handled or postponed" do
      from = {self(), make_ref()}

      queue = [
        {{:call, from}, {:provide_service, "mqtt", %{"password" => "p"}}},
        {{:call, from}, {:add_discovery, "mqtt", %{"password" => "p"}}},
        {{:call, from}, {:set, [options: %{"password" => "p"}]}},
        {{:call, from}, :info}
      ]

      status = Server.format_status(%{data: %{}, queue: queue, postponed: queue})
      refute inspect(status) =~ ~s("p")
      assert {{:call, ^from}, :info} = List.last(status.queue)
    end

    test "a live process's status shows no token, option or service payload" do
      {slug, pid} = started()
      :ok = App.set(slug, options: %{"greeting" => "0pt-s3cret"})
      :ok = :gen_statem.call(pid, {:provide_service, "svc_#{slug}", %{"password" => "s3cret"}})
      status = inspect(:sys.get_status(pid))

      refute status =~ "s3cret"
      refute status =~ data(pid).token
    end
  end

  describe "services" do
    setup do
      {slug, pid} = installed()
      %{slug: slug, pid: pid, name: "svc_#{slug}"}
    end

    test "a provided service is held and keyed in the directory under its provider",
         %{slug: slug, pid: pid, name: name} do
      assert :ok = :gen_statem.call(pid, {:provide_service, name, %{"host" => "h"}})

      assert {:ok, %{"host" => "h"}} = :gen_statem.call(pid, {:service, name})
      assert [{^pid, ^slug}] = lookup({:service, name})
    end

    test "a second provider is refused, and so is the provider's own re-post",
         %{pid: pid, name: name} do
      {_other, other_pid} = installed()
      :ok = :gen_statem.call(pid, {:provide_service, name, %{"host" => "a"}})

      assert {:error, :already_provided} =
               :gen_statem.call(other_pid, {:provide_service, name, %{"host" => "b"}})

      assert {:error, :already_provided} =
               :gen_statem.call(pid, {:provide_service, name, %{"host" => "c"}})

      assert :error = :gen_statem.call(other_pid, {:service, name})
      assert {:ok, %{"host" => "a"}} = :gen_statem.call(pid, {:service, name})
    end

    test "a withdrawn service leaves the directory and can be provided again",
         %{pid: pid, name: name} do
      :ok = :gen_statem.call(pid, {:provide_service, name, %{}})

      assert :ok = :gen_statem.call(pid, {:withdraw_service, name})
      assert {:error, :not_found} = :gen_statem.call(pid, {:withdraw_service, name})
      assert :error = :gen_statem.call(pid, {:service, name})
      assert [] = lookup({:service, name})
      assert :ok = :gen_statem.call(pid, {:provide_service, name, %{}})
    end

    test "every key goes with the process", %{slug: slug, pid: pid, name: name} do
      :ok = :gen_statem.call(pid, {:provide_service, name, %{}})
      {:ok, %{uuid: uuid}, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})
      ref = Process.monitor(pid)

      :ok = Instances.stop(slug)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # The directory drops a dead process's keys when its partition handles
      # the exit, asynchronously to the DOWN the test sees.
      assert gone?({:service, name})
      assert gone?({:discovery, uuid})
    end
  end

  describe "discovery" do
    setup do
      {slug, pid} = installed()
      %{slug: slug, pid: pid}
    end

    test "a new message gets a uuid and a directory key, a repeat keeps both",
         %{slug: slug, pid: pid} do
      assert {:ok, %{uuid: uuid, addon: ^slug, service: "mqtt", config: %{"a" => 1}} = message,
              :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{"a" => 1}})

      assert uuid =~ ~r/\A[0-9a-f]{32}\z/
      assert [{^pid, ^slug}] = lookup({:discovery, uuid})

      assert {:ok, ^message, :existing} =
               :gen_statem.call(pid, {:add_discovery, "mqtt", %{"a" => 1}})

      assert {:ok, %{uuid: ^uuid, config: %{"a" => 2}}, :updated} =
               :gen_statem.call(pid, {:add_discovery, "mqtt", %{"a" => 2}})

      assert {:ok, %{config: %{"a" => 2}}} = :gen_statem.call(pid, {:discovery, uuid})
      assert [%{uuid: ^uuid}] = :gen_statem.call(pid, :discovery_list)
    end

    test "another service is another message", %{pid: pid} do
      {:ok, %{uuid: a}, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})
      {:ok, %{uuid: b}, :new} = :gen_statem.call(pid, {:add_discovery, "other", %{}})

      refute a == b
      assert length(:gen_statem.call(pid, :discovery_list)) == 2
    end

    test "a deleted message leaves the directory", %{pid: pid} do
      {:ok, %{uuid: uuid} = message, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})

      assert {:ok, ^message} = :gen_statem.call(pid, {:delete_discovery, uuid})
      assert {:error, :not_found} = :gen_statem.call(pid, {:delete_discovery, uuid})
      assert :error = :gen_statem.call(pid, {:discovery, uuid})
      assert [] = :gen_statem.call(pid, :discovery_list)
      assert [] = lookup({:discovery, uuid})
    end
  end

  # A key held by a process of the test's, not by any app.
  defp hold_key(key) do
    test = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Vagus.App.Directory, key, "someone")
        send(test, :held)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :held
    holder
  end

  defp gone?(key, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      lookup(key) == [] -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> gone?(key, deadline)
    end
  end

  # The restart is the DynamicSupervisor's, asynchronous to the DOWN the test
  # sees; poll the directory against a deadline rather than sleeping.
  defp wait_for_new(slug, old, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    case lookup({:slug, slug}) do
      [{pid, _}] when pid != old ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: nil,
          else: wait_for_new(slug, old, deadline)
    end
  end
end
