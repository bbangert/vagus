defmodule Vagus.AppTest do
  # Seeds the global `Vagus.Addon.State` and briefly stops the global Registry.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures

  alias Vagus.Addon.{Backend, Config, Registry}
  alias Vagus.App
  alias Vagus.App.Directory

  defp config(overrides \\ %{}) do
    slug = "app_test_#{System.unique_integer([:positive])}"

    {:ok, config} =
      %{
        "name" => "App Test",
        "version" => "1.0",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "host_network" => true
      }
      |> Map.merge(overrides)
      |> Config.parse()

    config
  end

  defp track(config, opts \\ []), do: install_app(config, opts).slug

  describe "set/2" do
    test "writes options and settings" do
      slug = track(config())

      assert :ok = App.set(slug, options: %{"a" => 1}, watchdog: true)
      assert {:ok, %{user_options: %{"a" => 1}, watchdog: true}} = app_info(slug)
    end

    test "an unknown key raises before anything is written" do
      slug = track(config())

      assert_raise ArgumentError, fn -> App.set(slug, watchdog: true, bogus: 1) end
      assert {:ok, %{watchdog: false}} = app_info(slug)
    end

    test "an untracked slug is :error" do
      assert :error = App.set("app_test_untracked", boot: "manual")
    end

    test "an untracked slug is :error even with nothing to write" do
      assert :error = App.set("app_test_untracked", [])
    end
  end

  describe "identity_for_token/1" do
    setup do
      config = config()
      %{token: register_app_token(config), slug: config.slug}
    end

    test "resolves a registered token", %{token: token, slug: slug} do
      assert {:ok, %{slug: ^slug}} = App.identity_for_token(token)
      assert :error = App.identity_for_token("app-test-unknown")
    end

    test "is :error while the Registry is not running", %{token: token} do
      :ok = Supervisor.terminate_child(Vagus.Supervisor, Registry)
      on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Vagus.Supervisor, Registry) end)

      assert :error = App.identity_for_token(token)
    end
  end

  describe "install/1" do
    setup do
      prev = Application.get_env(:vagus, :addon_backend)
      Application.put_env(:vagus, :addon_backend, Backend.Fake)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:vagus, :addon_backend, prev),
          else: Application.delete_env(:vagus, :addon_backend)
      end)
    end

    test "records the app as :stopped" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)

      assert :ok = App.install(config)
      assert {:ok, %{state: :stopped}} = app_info(config.slug)
    end

    test "an installed slug is refused before the pull" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      assert :ok = App.install(config)
      Backend.Fake.reset_calls()

      assert {:error, :already_installed} = App.install(config)
      refute Enum.any?(Backend.Fake.calls_for("addon_#{config.slug}"), &match?({:pull, _}, &1))
    end

    test "uninstall stops the app's process" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      :ok = App.install(config)
      [{pid, _}] = Elixir.Registry.lookup(Vagus.App.Directory, {:slug, config.slug})
      ref = Process.monitor(pid)

      assert :ok = App.uninstall(config.slug)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
      refute App.installed?(config.slug)
    end

    test "the same slug installs again right after an uninstall" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      :ok = App.install(config)
      :ok = App.uninstall(config.slug)

      assert :ok = App.install(config)
      assert {:ok, %{state: :stopped}} = app_info(config.slug)
    end

    test "a process outliving its entry does not block a reinstall" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      :ok = App.install(config)
      :ok = Vagus.Addon.State.delete(config.slug)

      assert :ok = App.install(config)
      assert {:ok, %{state: :stopped}} = app_info(config.slug)
    end

    test "an install whose process does not start is still installed" do
      stop_instances()
      config = config()
      on_exit(fn -> forget_app(config.slug) end)

      assert :ok = App.install(config)
      assert App.installed?(config.slug)
    end

    test "an install issued during an uninstall waits and keeps its process" do
      config = config()
      slug = config.slug
      on_exit(fn -> forget_app(slug) end)
      :ok = App.install(config)
      [{old, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})

      # A suspended app supervisor parks the uninstall in its process stop,
      # after the entry is gone: the window a reinstall must not get into.
      sup = Process.whereis(Vagus.App.Instances)
      :erlang.trace(sup, true, [:receive])
      :ok = :sys.suspend(sup)
      on_exit(fn -> :sys.resume(sup) end)

      uninstall = Task.async(fn -> App.uninstall(slug) end)
      assert_receive {:trace, ^sup, :receive, {:"$gen_call", _, {:terminate_child, ^old}}}, 5_000

      install = Task.async(fn -> App.install(config) end)
      assert Task.yield(install, 200) == nil
      refute App.installed?(slug)

      :erlang.trace(sup, false, [:receive])
      :ok = :sys.resume(sup)
      assert :ok = Task.await(uninstall)
      assert :ok = Task.await(install)

      assert [{pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
      assert Process.alive?(pid)
      assert {:ok, %{state: :stopped, config: %{slug: ^slug}}} = App.info(slug)
    end

    test "concurrent installs of one slug pull once" do
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      Backend.Fake.reset_calls()

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> App.install(config) end) end)
        |> Task.await_many()

      assert Enum.sort(results) ==
               Enum.sort([:ok | List.duplicate({:error, :already_installed}, 3)])

      pulls = Enum.filter(Backend.Fake.calls_for("addon_#{config.slug}"), &match?({:pull, _}, &1))
      assert length(pulls) == 1
    end

    test "a refused install records nothing" do
      config = %{config() | slug: "vagus"}

      assert {:error, {:reserved_slug, "vagus"}} = App.install(config)
      assert :error = app_info("vagus")
    end
  end

  describe "ingress_target/1" do
    # A host-network app is reached without a docker inspect.
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      on_exit(fn -> :gen_tcp.close(listen) end)
      {:ok, port} = :inet.port(listen)
      %{port: port}
    end

    test "the config's static port", %{port: port} do
      slug = track(config(%{"ingress" => true, "ingress_port" => port}))
      assert {:ok, {"127.0.0.1", ^port, false}} = App.ingress_target(slug)
    end

    test "the allocated port wins over the 0 sentinel", %{port: port} do
      slug = track(config(%{"ingress" => true, "ingress_port" => 0}), ingress_port: port)

      assert {:ok, {"127.0.0.1", ^port, false}} = App.ingress_target(slug)
    end

    test "the 0 sentinel with nothing allocated has no target" do
      slug = track(config(%{"ingress" => true, "ingress_port" => 0}))
      assert {:error, :no_ingress_port} = App.ingress_target(slug)
    end

    test "carries ingress_stream", %{port: port} do
      slug =
        track(config(%{"ingress" => true, "ingress_port" => port, "ingress_stream" => true}))

      assert {:ok, {_ip, ^port, true}} = App.ingress_target(slug)
    end

    test "an untracked slug is not found" do
      assert {:error, :not_found} = App.ingress_target("app_test_untracked")
    end
  end

  describe "ask/3" do
    test "no process for the slug is :absent" do
      assert :absent = App.ask("app_test_nobody", :info)
    end

    test "a process that stopped is :absent" do
      slug = track(config())
      [{pid, _}] = Elixir.Registry.lookup(Vagus.App.Directory, {:slug, slug})
      :ok = :gen_statem.stop(pid)

      assert :absent = App.ask(slug, :info)
    end

    test "a process that does not answer in time is :absent" do
      slug = track(config())
      [{pid, _}] = Elixir.Registry.lookup(Vagus.App.Directory, {:slug, slug})
      :ok = :sys.suspend(pid)
      on_exit(fn -> :sys.resume(pid) end)

      assert :absent = App.ask(slug, :info, 50)
    end
  end

  describe "installed?/1" do
    test "answers from the entry while the process is stuck" do
      slug = track(config())
      suspend(slug)

      assert App.installed?(slug)
    end

    test "an entry with no process is installed without starting one" do
      slug = track(config(), process: false)

      assert App.installed?(slug)
      assert [] = Elixir.Registry.lookup(Directory, {:slug, slug})
    end
  end

  describe "Instances.ensure/1" do
    test "is {:error, :unavailable} while the app supervisor is down" do
      stop_instances()
      config = config()
      on_exit(fn -> forget_app(config.slug) end)
      :ok = Vagus.Addon.State.put(config, :stopped)

      assert {:error, :unavailable} = Vagus.App.Instances.ensure(config.slug)
    end
  end

  describe "list/0" do
    test "apps that do not answer share one deadline and are listed :unknown" do
      answering = track(config(), state: :started)
      stuck = for _ <- 1..3, do: track(config(), state: :started)
      Enum.each(stuck, &suspend/1)

      started = System.monotonic_time(:millisecond)
      listed = Map.new(App.list(), &{&1.config.slug, &1.state})
      elapsed = System.monotonic_time(:millisecond) - started

      assert listed[answering] == :started
      for slug <- stuck, do: assert(listed[slug] == :unknown)
      assert elapsed < 2 * 1_000
    end

    test "an entry with no process is listed :unknown and info/1 brings it back" do
      slug =
        track(config(), state: :started, process: false, options: %{"a" => 1}, watchdog: true)

      assert [] = Elixir.Registry.lookup(Directory, {:slug, slug})

      assert [%{state: :unknown}] = Enum.filter(App.list(), &(&1.config.slug == slug))

      assert {:ok, %{state: :started, config: %{slug: ^slug}}} = App.info(slug)
      assert [{pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
      assert Process.alive?(pid)
    end

    test "gather/2 answers every app under one deadline" do
      answering = track(config())
      stuck = for _ <- 1..3, do: track(config())
      pids = Enum.map(stuck, &suspend/1)

      started = System.monotonic_time(:millisecond)
      answers = Map.new(App.gather(:installed?, 1_000))
      elapsed = System.monotonic_time(:millisecond) - started

      assert answers[answering] == {:ok, true}
      for slug <- stuck, do: assert(answers[slug] == :absent)
      assert elapsed < 2 * 1_000

      # The stuck apps answer once resumed; the abandoned requests' replies
      # must not land in the caller's mailbox. `get_state` returns only after
      # the queued call has been handled.
      for pid <- pids, do: :ok = :sys.resume(pid)
      for pid <- pids, do: _ = :sys.get_state(pid)
      refute_received _late_reply
    end
  end

  # A child stopped through `terminate_child/2` stays down until restarted;
  # every app process goes with it.
  defp stop_instances do
    :ok = Supervisor.terminate_child(Vagus.App.Supervisor, Vagus.App.Instances)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Vagus.App.Supervisor, Vagus.App.Instances)
    end)
  end

  defp suspend(slug) do
    [{pid, _}] = Elixir.Registry.lookup(Directory, {:slug, slug})
    :ok = :sys.suspend(pid)
    on_exit(fn -> :sys.resume(pid) end)
    pid
  end
end
