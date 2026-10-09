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

    test "an ingress token its file lacked is saved before it is registered, so it holds" do
      {slug, pid} = installed(%{"ingress" => true})
      :ok = Instances.stop(slug)
      path = Path.join(AppFile.dir(), slug <> ".json")

      File.write!(
        path,
        path |> File.read!() |> Jason.decode!() |> Map.delete("ingress_token") |> Jason.encode!()
      )

      refute Process.alive?(pid)

      {:ok, pid} = Instances.ensure(slug)
      token = data(pid).ingress_token
      assert [{^pid, ^slug}] = lookup({:ingress_token, Policy.hash(token)})
      assert %{"ingress_token" => ^token} = path |> File.read!() |> Jason.decode!()

      :ok = Instances.stop(slug)
      {:ok, pid} = Instances.ensure(slug)
      assert %{ingress_token: ^token} = data(pid)
    end

    test "a file that needs a rewrite it cannot get starts nothing and registers nothing" do
      {slug, pid} = installed(%{"ingress" => true})
      :ok = Instances.stop(slug)
      refute Process.alive?(pid)
      path = Path.join(AppFile.dir(), slug <> ".json")

      File.write!(
        path,
        path |> File.read!() |> Jason.decode!() |> Map.delete("ingress_token") |> Jason.encode!()
      )

      blocker = path <> ".tmp"
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ignore = Instances.ensure(slug) end)

      assert log =~ "could not be rewritten"
      assert [] = lookup({:slug, slug})

      assert [] =
               Registry.select(Vagus.App.Directory, [
                 {{{:ingress_token, :_}, :_, :"$1"}, [{:==, :"$1", slug}], [true]}
               ])
    end

    test "a saved dynamic port another app holds is dropped and saved so; the holder keeps it" do
      ingress = %{"ingress" => true, "ingress_port" => 0}
      {a, pa} = installed(ingress, ingress_port: 62_124)
      b = slug()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          install_app(app_config(b, ingress), ingress_port: 62_124)
        end)

      assert log =~ "held by another app"
      assert [{^pa, ^a}] = lookup({:ingress_port, 62_124})
      assert %{ingress_port: nil} = data(pid_of(b))
      assert {:ok, %{ingress_port: nil, rewrite: false}} = AppFile.read(b)
      assert {:ok, %{ingress_port: 62_124}} = AppFile.read(a)
    end
  end

  describe "settings" do
    test "a write is on disk before the reply, and refused with no app installed" do
      {slug, pid} = installed()

      assert :ok = :gen_statem.call(pid, {:set, [options: %{"a" => 1}, watchdog: true]})
      assert {:ok, %{user_options: %{"a" => 1}, watchdog: true}} = AppFile.read(slug)
      assert :error = :gen_statem.call(pid, {:set, [nope: 1]})

      {:ok, new} = Instances.ensure(slug())
      assert {:error, :not_installed} = :gen_statem.call(new, {:set, [watchdog: true]})
    end

    test "a write while the install pulls is refused, not a crash" do
      slug = slug()
      on_exit(fn -> forget_app(slug) end)
      {:ok, pid} = Instances.ensure(slug)
      t = op(pid, {:install, %{config: app_config(slug)}})
      {_input, task} = step(:pull)

      assert {:error, :not_installed} = :gen_statem.call(pid, {:set, [watchdog: true]})
      send(task, {:outcome, {:ok, "x/y:1"}})
      assert :ok = Task.await(t)
    end

    test "a write once an uninstall began is refused, so the file stays gone" do
      {slug, pid} = started()
      t = op(pid, {:uninstall, %{}})
      answer(:stop, {:ok, %{was_running: true}})
      {_input, task} = step(:remove_app)

      assert {:error, :not_installed} = :gen_statem.call(pid, {:set, [watchdog: true]})
      assert :error = AppFile.read(slug)
      send(task, {:outcome, {:ok, :ok}})
      assert :ok = Task.await(t)
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
      app_deadlines(%{stop: 1_000, start: 1_000})
      {_slug, pid} = started()
      t = op(pid, {:restart, %{}})

      for {name, outcome} <- [stop: {:ok, %{was_running: true}}, start: {:ok, @started}] do
        {_input, task} = step(name)
        Process.send_after(self(), {:waited, name}, 600)
        assert_receive {:waited, ^name}, 1_000
        send(task, {:outcome, outcome})
      end

      assert :ok = Task.await(t)
    end

    test "an EXIT a killed task queued before its unlink is dropped, not taken for the directory" do
      app_deadlines(%{start: 100})
      {_slug, pid} = installed()
      t = op(pid, {:start, %{}})
      {_input, task} = step(:start)
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 1_000

      send(pid, {:EXIT, task, :killed})
      answer(:stop, {:ok, %{was_running: false}})
      assert {:error, :timeout} = Task.await(t)
      assert %{killed: []} = data(pid)
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

    test "halt answers with its stop's result" do
      {_slug, pid} = installed(%{}, state: :started)
      halt = op(pid, {:halt, %{}})
      answer(:halt_stop, {:error, :engine_gone})

      assert {:error, :engine_gone} = Task.await(halt)
      assert :shutting_down = state(pid)
    end

    test "halt during an install ends the process and answers both callers" do
      slug = slug()
      on_exit(fn -> forget_app(slug) end)
      {:ok, pid} = Instances.ensure(slug)
      ref = Process.monitor(pid)
      install = op(pid, {:install, %{config: app_config(slug)}})
      step(:pull)

      assert :ok = :gen_statem.call(pid, {:halt, %{}})
      assert {:error, :shutting_down} = Task.await(install)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :error = AppFile.read(slug)
    end

    test "a halt during an uninstall's stop leaves an app that takes its own posts after resume" do
      {slug, pid} = started()
      uninstall = op(pid, {:uninstall, %{}})
      step(:stop)
      halt = op(pid, {:halt, %{}})
      assert {:error, :shutting_down} = Task.await(uninstall)
      answer(:halt_stop, {:ok, :stopped})
      assert :ok = Task.await(halt)

      assert :ok = :gen_statem.call(pid, {:resume, %{}})
      assert :ok = :gen_statem.call(pid, {:provide_service, "svc_#{slug}", %{}})
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

    test "an install asked to be wanted started is saved so, for boot to start it" do
      slug = slug()
      on_exit(fn -> forget_app(slug) end)
      {:ok, pid} = Instances.ensure(slug)
      t = op(pid, {:install, %{config: app_config(slug), wanted: :started}})
      answer(:pull, {:ok, "x/y:1"})

      assert :ok = Task.await(t)
      assert {:ok, %{wanted: :started}} = AppFile.read(slug)
      assert {:ok, %{state: :stopped}} = App.info(slug)
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

    test "uninstall drops every key before its task and deletes the file before the removal" do
      capture_discovery_pushes()
      {slug, pid} = started()
      token_key = {:token, data(pid).token_hash}
      assert [{^pid, ^slug}] = lookup(token_key)
      :ok = :gen_statem.call(pid, {:provide_service, "svc_#{slug}", %{}})
      {:ok, %{uuid: uuid}, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})
      drain_discovery_pushes()
      ref = Process.monitor(pid)

      t = op(pid, {:uninstall, %{}})
      {_input, task} = step(:stop)
      assert_receive {:discovery_push, :delete, %{uuid: ^uuid}}

      keys = [
        token_key,
        {:service, "svc_#{slug}"},
        {:discovery, uuid},
        {:dns, Policy.dns_name(slug)}
      ]

      for key <- keys, do: assert([] = lookup(key))

      assert {:error, :unavailable} = :gen_statem.call(pid, {:add_discovery, "x", %{}})
      assert {:ok, _} = AppFile.read(slug)
      send(task, {:outcome, {:ok, %{was_running: true}}})
      {_input, task} = step(:remove_app)
      assert :error = AppFile.read(slug)
      send(task, {:outcome, {:ok, :ok}})

      assert :ok = Task.await(t)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :error = AppFile.read(slug)
    end

    test "an uninstall whose file cannot be deleted fails before the removal; the app stays" do
      {slug, pid} = installed(%{"ingress" => true})
      token_key = {:ingress_token, Policy.hash(data(pid).ingress_token)}
      File.chmod!(AppFile.dir(), 0o555)
      on_exit(fn -> File.chmod!(AppFile.dir(), 0o755) end)

      ExUnit.CaptureLog.capture_log(fn ->
        t = op(pid, {:uninstall, %{}})
        answer(:stop, {:ok, %{was_running: false}})
        assert {:error, {:delete_file, :eacces}} = Task.await(t)
      end)

      refute_received {:step, :remove_app, _input, _task}
      assert :idle = state(pid)
      assert %{gone: false, retired: false} = data(pid)
      assert {:ok, _saved} = AppFile.read(slug)
      assert [{^pid, ^slug}] = lookup(token_key)
      assert :gen_statem.call(pid, :installed?) == true
    end

    test "an uninstall whose data dir cannot be removed replies why; the file stays gone" do
      {slug, pid} = installed()
      ref = Process.monitor(pid)
      failure = {:remove_data_dir, "/data/addons/data/#{slug}/locked", :eacces}

      t = op(pid, {:uninstall, %{}})
      answer(:stop, {:ok, %{was_running: false}})
      answer(:remove_app, {:error, failure})

      assert {:error, ^failure} = Task.await(t)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :error = AppFile.read(slug)
    end

    test "a halt once the file is gone ends the process; the slug comes back new" do
      {slug, pid} = started()
      ref = Process.monitor(pid)
      uninstall = op(pid, {:uninstall, %{}})
      answer(:stop, {:ok, %{was_running: true}})
      step(:remove_app)

      halt = op(pid, {:halt, %{}})
      assert {:error, :shutting_down} = Task.await(uninstall)
      answer(:halt_stop, {:ok, :stopped})
      assert :ok = Task.await(halt)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert :error = AppFile.read(slug)
      assert {:ok, new} = Instances.ensure(slug)
      assert :new = state(new)
    end

    test "late events of a container it stopped are ignored and cost no attempt" do
      {slug, pid} = started(%{}, watchdog: true)
      t = op(pid, {:stop, %{}})
      {_input, task} = step(:stop)

      send(pid, {:docker_event, %{id: "c1", action: "start"}})
      send(pid, {:docker_event, %{id: "c1", action: "die", exit_code: 137}})
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert :ok = Task.await(t)

      assert %{container_id: nil, attempt: 0, last_event: :stopped} = data(pid)
      assert {:ok, %{state: :stopped}} = App.info(slug)
    end

    test "a restart pending when a user start fails is not run" do
      app_deadlines(%{retry: 150})
      {_slug, pid} = started(%{}, watchdog: true)
      send(pid, {:docker_event, %{id: "c1", action: "die", exit_code: 1}})
      assert %{attempt: 1} = data(pid)

      t = op(pid, {:start, %{}})
      answer(:start, {:error, :boom})
      assert {:error, :boom} = Task.await(t)
      refute_receive {:step, :start, _, _}, 400
    end

    test "a restart that came due during an operation which started the app again is dropped" do
      app_deadlines(%{retry: 100})
      {slug, pid} = started(%{"version" => "1"}, watchdog: true)
      send(pid, {:docker_event, %{id: "c1", action: "die", exit_code: 1}})
      t = op(pid, {:update, %{config: app_config(slug, %{"version" => "2"})}})
      {_input, task} = step(:pull)
      Process.send_after(self(), :due, 300)
      assert_receive :due, 1_000

      send(task, {:outcome, {:ok, "x/y:2"}})
      answer(:stop, {:ok, %{was_running: true}})
      answer(:start, {:ok, %{@started | container_id: "c2"}})
      answer(:reclaim_image, {:ok, :ok})
      assert {:ok, %{to: "2"}} = Task.await(t)

      refute_receive {:step, :start, _, _}, 300
      assert %{container_id: "c2"} = data(pid)
    end

    test "an update's commit moves the ingress keys: ingress off, dynamic port to fixed" do
      dynamic = %{"version" => "1", "ingress" => true, "ingress_port" => 0}
      {slug, pid} = installed(dynamic, ingress_port: 62_125)
      hashed = {:ingress_token, Policy.hash(data(pid).ingress_token)}
      assert [{^pid, ^slug}] = lookup(hashed)

      target = %{"version" => "2", "ingress" => false, "ingress_port" => 8123}
      t = op(pid, {:update, %{config: app_config(slug, target)}})
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: false}})
      answer(:reclaim_image, {:ok, :ok})
      assert {:ok, %{to: "2"}} = Task.await(t)

      assert [] = lookup(hashed)
      assert [] = lookup({:ingress_port, 62_125})
      assert {:ok, %{ingress_port: nil}} = AppFile.read(slug)
    end

    test "an install whose file cannot be written fails and leaves no process" do
      slug = slug()
      blocker = Path.join(AppFile.dir(), slug <> ".json.tmp")
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)
      {:ok, pid} = Instances.ensure(slug)
      ref = Process.monitor(pid)

      t = op(pid, {:install, %{config: app_config(slug)}})
      answer(:pull, {:ok, "x/y:1"})

      assert {:error, {:persist, :eperm}} = Task.await(t)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert :error = AppFile.read(slug)
    end

    test "a stop whose file cannot be written still stops the container and replies the failure" do
      {slug, pid} = started()
      blocker = Path.join(AppFile.dir(), slug <> ".json.tmp")
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          t = op(pid, {:stop, %{}})
          answer(:stop, {:ok, %{was_running: true}})
          assert {:error, {:persist, :eperm}} = Task.await(t)
        end)

      assert log =~ "not saved"
      assert :idle = state(pid)
      assert %{wanted: :stopped, container_id: nil} = data(pid)
      assert {:ok, %{wanted: :started}} = AppFile.read(slug)
    end

    test "an update whose commit cannot be saved keeps the new container, no rollback" do
      {slug, pid} = started(%{"version" => "1"})
      blocker = Path.join(AppFile.dir(), slug <> ".json.tmp")
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)

      ExUnit.CaptureLog.capture_log(fn ->
        t = op(pid, {:update, %{config: app_config(slug, %{"version" => "2"})}})
        answer(:pull, {:ok, "x/y:2"})
        answer(:stop, {:ok, %{was_running: true}})

        assert %{config: %{version: "2"}} =
                 answer(:start, {:ok, %{@started | container_id: "c2"}})

        answer(:reclaim_image, {:ok, :ok})
        assert {:error, {:persist, :eperm}} = Task.await(t)
      end)

      refute_received {:step, :start, _input, _task}
      assert %{container_id: "c2", config: %{version: "2"}} = data(pid)
      assert {:ok, %{config: %{version: "1"}}} = AppFile.read(slug)
    end

    test "an error reply is not masked by a save that failed during the op" do
      {slug, pid} = started(%{"version" => "1"})
      blocker = Path.join(AppFile.dir(), slug <> ".json.tmp")
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)

      ExUnit.CaptureLog.capture_log(fn ->
        t = op(pid, {:update, %{config: app_config(slug, %{"version" => "2"})}})
        answer(:pull, {:ok, "x/y:2"})
        answer(:stop, {:ok, %{was_running: true}})
        answer(:start, {:error, :boom})
        answer(:start, {:ok, %{@started | container_id: "c2"}})
        assert {:error, {:rolled_back, :boom}} = Task.await(t)
      end)
    end

    test "a save that fails mid-op and succeeds at its end replies success" do
      {slug, pid} = started(%{"version" => "1"})
      blocker = Path.join(AppFile.dir(), slug <> ".json.tmp")
      File.mkdir_p!(blocker)
      on_exit(fn -> File.rm_rf!(blocker) end)

      ExUnit.CaptureLog.capture_log(fn ->
        t = op(pid, {:update, %{config: app_config(slug, %{"version" => "2"})}})
        answer(:pull, {:ok, "x/y:2"})
        answer(:stop, {:ok, %{was_running: false}})
        {_input, task} = step(:reclaim_image)
        File.rm_rf!(blocker)
        send(task, {:outcome, {:ok, :ok}})
        assert {:ok, %{to: "2"}} = Task.await(t)
      end)

      assert {:ok, %{config: %{version: "2"}}} = AppFile.read(slug)
    end

    test "a file that does not decode starts no process, and is logged" do
      slug = slug()
      path = Path.join(AppFile.dir(), slug <> ".json")
      File.mkdir_p!(AppFile.dir())
      File.write!(path, "{{{")
      on_exit(fn -> File.rm(path) end)

      assert ExUnit.CaptureLog.capture_log(fn -> assert :ignore = Instances.ensure(slug) end) =~
               "cannot be read"
    end

    test "two apps that picked one dynamic port: the second to claim it fails its start" do
      ingress = %{"ingress" => true, "ingress_port" => 0}
      {a, pa} = installed(ingress)
      {b, pb} = installed(ingress)
      ta = op(pa, {:start, %{}})
      assert_receive {:step, :port, %{slug: ^a}, port_a}, 2_000
      tb = op(pb, {:start, %{}})
      assert_receive {:step, :port, %{slug: ^b}, port_b}, 2_000

      send(port_a, {:outcome, {:ok, 62_011}})
      assert_receive {:step, :start, %{slug: ^a}, start_a}, 2_000
      send(port_b, {:outcome, {:ok, 62_011}})

      assert {:error, {:ingress_port, {:port_taken, {:ingress_port, 62_011}}}} =
               Task.await(tb, 2_000)

      send(start_a, {:outcome, {:ok, @started}})
      assert :ok = Task.await(ta)
      assert [{^pa, ^a}] = lookup({:ingress_port, 62_011})
    end

    test "a hot snapshot killed at its deadline fails the backup" do
      app_deadlines(%{snapshot: 100})
      {_slug, pid} = started()
      t = op(pid, {:backup, %{staging_dir: "/nonexistent"}})
      {_input, task} = step(:snapshot)
      ref = Process.monitor(task)

      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 1_000
      assert {:error, :timeout} = Task.await(t)
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

  describe "restore" do
    test "revokes the old token before the stop and saves the options before the start" do
      {slug, pid} = started()
      old = data(pid).token_hash
      args = %{staging_dir: "/s", options: %{"greeting" => "restored"}, start?: true}
      t = op(pid, {:restore, args})

      {_input, task} = step(:stop)
      assert lookup({:token, old}) == []
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert %{staging_dir: "/s"} = answer(:swap_data, {:ok, "/data"})
      assert %{options: %{"greeting" => "restored"}} = answer(:set_options, {:ok, args.options})

      {input, task} = step(:start)
      assert {:ok, %{user_options: %{"greeting" => "restored"}}} = AppFile.read(slug)
      assert [{^pid, ^slug}] = lookup({:token, Policy.hash(input.token)})
      send(task, {:outcome, {:ok, @started}})

      assert :ok = Task.await(t)
      assert {:ok, %{state: :started, user_options: %{"greeting" => "restored"}}} = App.info(slug)
    end

    test "an options write during a restore is applied at once and survives it" do
      {slug, pid} = started()
      args = %{staging_dir: "/s", options: %{"greeting" => "restored"}, start?: true}
      t = op(pid, {:restore, args})
      {_input, stopping} = step(:stop)

      # Answered while the stop is still held, not after the restore.
      assert :ok = App.set(slug, options: %{"greeting" => "mine"})
      assert {:ok, %{user_options: %{"greeting" => "mine"}}} = AppFile.read(slug)

      send(stopping, {:outcome, {:ok, %{was_running: true}}})
      answer(:swap_data, {:ok, "/data"})
      answer(:set_options, {:ok, args.options})
      assert %{user_options: %{"greeting" => "mine"}} = answer(:start, {:ok, @started})

      assert :ok = Task.await(t)
      assert {:ok, %{state: :started, user_options: %{"greeting" => "mine"}}} = App.info(slug)
      assert {:ok, %{user_options: %{"greeting" => "mine"}}} = AppFile.read(slug)
    end

    test "a mid-restore write of the options it began with still wins" do
      {slug, pid} =
        started(%{"options" => %{"greeting" => "hi"}, "schema" => %{"greeting" => "str"}})

      assert :ok = App.set(slug, options: %{"greeting" => "before"})
      before = data(pid)
      args = %{staging_dir: "/s", options: %{"greeting" => "restored"}, start?: true}
      t = op(pid, {:restore, args})
      {_input, stopping} = step(:stop)

      assert :ok = App.set(slug, options: before.user_options)

      send(stopping, {:outcome, {:ok, %{was_running: true}}})
      answer(:swap_data, {:ok, "/data"})
      answer(:set_options, {:ok, args.options})
      assert %{user_options: %{"greeting" => "before"}} = answer(:start, {:ok, @started})

      assert :ok = Task.await(t)
      assert data(pid).options_rev == before.options_rev + 1
      assert {:ok, %{user_options: %{"greeting" => "before"}}} = App.info(slug)
      assert {:ok, %{user_options: %{"greeting" => "before"}}} = AppFile.read(slug)
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

    test "a backup is snapshotted into the caller's staging dir between the stop and the start" do
      {slug, pid} = started(@v1)
      t = op(pid, {:update, %{config: target(slug), backup: true, staging_dir: "/s"}})
      answer(:pull, {:ok, "x/y:2"})
      answer(:stop, {:ok, %{was_running: true}})

      assert %{staging_dir: "/s", state: "started", config: %{version: "1"}} =
               answer(:snapshot, {:ok, "/s/#{slug}.tar.gz"})

      answer(:start, {:ok, @started})
      answer(:reclaim_image, {:ok, :ok})
      assert {:ok, %{from: "1", to: "2"}} = Task.await(t)
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

  describe "boot_start" do
    # `state: :started` is the engine reporting a running container, which
    # the process adopts without having started it.
    test "a wanted auto app running a container it did not start is recreated with a token" do
      {_slug, pid} = installed(%{}, state: :started)
      assert %{container_id: "fixture-" <> _, token_hash: nil} = data(pid)

      boot = op(pid, {:boot_start, %{}})
      assert %{token: token} = answer(:start, {:ok, @started})
      assert is_binary(token)
      assert :ok = Task.await(boot)
      assert %{container_id: "c1"} = data(pid)
    end

    test "a wanted manual app is recreated if it runs, and demoted if not" do
      {_slug, pid} = installed(%{"boot" => "manual"}, state: :started)
      boot = op(pid, {:boot_start, %{}})
      assert %{token: token} = answer(:start, {:ok, @started})
      assert is_binary(token)
      assert :ok = Task.await(boot)
      assert %{wanted: :started, container_id: "c1"} = data(pid)

      # Wanted started, and the engine lists no container.
      slug = slug()
      install_app(app_config(slug, %{"boot" => "manual"}), state: :started, process: false)
      {:ok, pid} = Instances.ensure(slug)
      assert :ok = :gen_statem.call(pid, {:boot_start, %{running?: false}})
      assert %{wanted: :stopped} = data(pid)
      refute_received {:step, :start, _, _}
    end

    test "a restarted process whose container the engine reports running starts it again" do
      slug = slug()
      install_app(app_config(slug, %{"boot" => "manual"}), state: :started, process: false)
      {:ok, pid} = Instances.ensure(slug)
      assert %{container_id: nil, token_hash: nil} = data(pid)

      boot = op(pid, {:boot_start, %{running?: true}})
      assert %{token: token} = answer(:start, {:ok, @started})
      assert is_binary(token)
      assert :ok = Task.await(boot)
    end

    test "a manual app the engine could not be asked about is left as it is" do
      slug = slug()
      install_app(app_config(slug, %{"boot" => "manual"}), state: :started, process: false)
      {:ok, pid} = Instances.ensure(slug)

      assert :ok = :gen_statem.call(pid, {:boot_start, %{running?: :unknown}})
      assert %{wanted: :started} = data(pid)
      refute_received {:step, :start, _, _}
    end

    test "an app halted by a shutdown that did not happen is resumed, and booted" do
      {slug, pid} = installed(%{}, state: :started)
      halt = op(pid, {:halt, %{}})
      answer(:halt_stop, {:ok, :stopped})
      assert :ok = Task.await(halt)
      assert :shutting_down = state(pid)

      boot = Task.async(fn -> App.boot_start(slug) end)
      answer(:start, {:ok, @started})
      assert :ok = Task.await(boot)
      assert :idle = state(pid)
    end

    test "an app wanted stopped is left stopped" do
      {_slug, pid} = installed()
      assert :ok = :gen_statem.call(pid, {:boot_start, %{}})
      refute_received {:step, :start, _, _}
      assert %{wanted: :stopped} = data(pid)
    end
  end

  describe "the URL probe" do
    # Real timers, shortened: the 120 s interval runs in 50 ms.
    setup do
      stub_app_probe()
      app_deadlines(%{probe: 50, probe_deadline: 100})
    end

    @watched %{"watchdog" => "http://[HOST]:[PORT:8080]/health"}

    defp probed do
      assert_receive {:probe, template, input, task}, 2_000
      {template, input, task}
    end

    test "runs on its interval against the app's address, and a healthy app is left be" do
      {_slug, pid} = started(@watched, watchdog: true)
      {template, input, task} = probed()
      assert template == "http://[HOST]:[PORT:8080]/health"
      assert input.ip == "172.30.33.9"
      send(task, {:result, :healthy})

      {_template, _input, task} = probed()
      send(task, {:result, :healthy})
      _ = :sys.get_state(pid)
      refute_received {:step, :start, _, _}
    end

    test "two misses in a row restart the app with a new token" do
      {_slug, pid} = started(@watched, watchdog: true)
      %{token: old} = data(pid)
      {_template, _input, task} = probed()
      send(task, {:result, :unhealthy})
      {_template, _input, task} = probed()
      send(task, {:result, :unhealthy})

      input = answer(:start, {:ok, @started})
      assert input.token != old
      assert %{attempt: 1, strikes: 0} = data(pid)
    end

    test "a probe in flight when an operation begins is killed, and its result dropped" do
      {_slug, pid} = started(@watched, watchdog: true)
      {_template, _input, task} = probed()
      %{probe: {^task, ref}} = data(pid)
      monitor = Process.monitor(task)

      _stop = op(pid, {:stop, %{}})
      step(:stop)
      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
      send(pid, {:probe, ref, :unhealthy})
      assert %{probe: nil, strikes: 0} = data(pid)
    end

    test "a probe past its deadline is a miss" do
      {_slug, pid} = started(@watched, watchdog: true)
      {_template, _input, task} = probed()
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 1_000
      assert %{strikes: 1} = data(pid)
    end

    test "is off with the watchdog off, and never runs while an operation does" do
      {_slug, pid} = started(@watched)
      refute_receive {:probe, _, _, _}, 200

      :ok = :gen_statem.call(pid, {:set, [watchdog: true]})
      _stop = op(pid, {:stop, %{}})
      step(:stop)
      refute_receive {:probe, _, _, _}, 200
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
        {{:call, from}, {:restore, %{staging_dir: "/s", options: %{"password" => "p"}}}},
        {{:call, from}, :info}
      ]

      status = Server.format_status(%{data: %{}, queue: queue, postponed: queue})
      refute inspect(status) =~ ~s("p")
      assert {{:call, ^from}, :info} = List.last(status.queue)
    end

    test "a crash reason keeps its shape and frames, not the arguments; the debug log is dropped" do
      stack = [{Vagus.App.Policy, :advance, [%{token: "t0k"}, []], [line: 1]}]

      reason =
        {%FunctionClauseError{
           module: Vagus.App.Policy,
           function: :advance,
           arity: 2,
           args: ["t0k"]
         }, stack}

      status =
        Server.format_status(%{data: %{}, reason: reason, log: [{:in, {:set, [options: "t0k"]}}]})

      refute inspect(status) =~ "t0k"
      assert {FunctionClauseError, [{Vagus.App.Policy, :advance, 2, [line: 1]}]} = status.reason
      assert status.log == []
    end

    test "a step that dies is logged by the shape of its reason, never its terms" do
      {_slug, pid} = installed()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          t = op(pid, {:start, %{}})
          {_input, task} = step(:start)
          Process.exit(task, {:badarg, "t0k-s3cret"})
          answer(:stop, {:ok, %{was_running: false}})
          assert {:error, :died} = Task.await(t)
        end)

      assert log =~ "died: :badarg"
      refute log =~ "t0k-s3cret"
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
