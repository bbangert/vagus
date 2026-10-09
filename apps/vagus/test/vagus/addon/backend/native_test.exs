defmodule Vagus.Addon.Backend.NativeTest do
  # async: false — drives the app-global Native.Supervisor and app processes,
  # and binds a real TCP port for the broker subtree.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures,
    only: [app_deadlines: 1, forget_app: 1, install_app: 1, stub_app_steps: 0]

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.{Config, Info}
  alias Vagus.Addon.Store.BuiltinFetcher
  alias Vagus.App
  alias Vagus.App.Steps

  @slug "core_mqtt"
  @id "addon_core_mqtt"

  # The store rewrites `config.slug` to the store slug on install (router
  # handle_install); mirror that so the installed app runs under "core_mqtt".
  defp mqtt_config do
    {:ok, config} = Config.parse(BuiltinFetcher.config(:mqtt))
    %{config | slug: @slug}
  end

  # Installs and starts the real broker through its app process.
  defp start_broker do
    assert :ok = App.install(mqtt_config())
    on_exit(fn -> forget_app(@slug) end)
    assert {:ok, %{slug: @slug}} = App.start(@slug)
  end

  describe "native app lifecycle (real broker subtree, the steps route to :native)" do
    setup do
      port = free_port()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      data_root = tmp_dir()
      Application.put_env(:vagus, :addon_data_root, data_root)

      on_exit(fn ->
        Native.stop(@id)
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
      end)

      %{config: mqtt_config(), port: port}
    end

    test "install → start → state → stop → uninstall", %{config: config, port: port} do
      # install pulls through Native.pull (no Docker) and records it stopped.
      assert :ok = App.install(config)
      on_exit(fn -> forget_app(@slug) end)
      assert {:ok, %{state: :stopped}} = App.info(@slug)

      # start routes to Native → a real supervised broker subtree.
      assert {:ok, %{slug: @slug}} = App.start(@slug)
      assert {:ok, :running} = Native.state(@id)
      assert {:ok, %{state: :started}} = App.info(@slug)

      # the listener is actually bound on the configured port.
      assert {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 1_000)
      :gen_tcp.close(sock)

      # Info.render surfaces the app from its Config (no backend coupling).
      info = Info.render(config, :started, config.options)
      assert info["slug"] == @slug
      assert info["name"] == config.name

      # stop tears the subtree down and reports stopped.
      assert :ok = App.stop(@slug)
      assert {:ok, :stopped} = Native.state(@id)
      assert {:ok, %{state: :stopped}} = App.info(@slug)
      assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 500)

      assert :ok = App.uninstall(@slug)
      assert :error = App.info(@slug)
    end

    test "start is idempotent and stop tolerates an already-stopped app" do
      start_broker()

      # Native.start on an already-running id is :ok, not a crash.
      assert :ok = Native.start(@id)
      assert {:ok, :running} = Native.state(@id)

      assert :ok = App.stop(@slug)
      # Native.stop/remove on an unstarted id is idempotent.
      assert :ok = Native.stop(@id)
      assert :ok = Native.remove(@id)
      assert {:ok, :stopped} = Native.state(@id)
    end
  end

  # Forwards received MQTT messages to the owning test process.
  defmodule Collector do
    @moduledoc false
    def handle_mqtt_event(:message, {topic, payload, _packet}, %{pid: pid} = state) do
      send(pid, {:mqtt_message, topic, payload})
      state
    end

    def handle_mqtt_event(_event, _data, state), do: state
  end

  describe "services / discovery / backup (MQ-P4)" do
    setup do
      port = free_port()
      # Nested, so the backup staging root beside it is inside this test's tmp dir.
      dr = Path.join(tmp_dir(), "data")
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      # The Provider's data dir is the app's, so the persisted
      # broker_state.json rides in the backup tar.
      Application.put_env(:vagus, :addon_data_root, dr)

      backups = :"backups_#{System.unique_integer([:positive])}"
      start_supervised!({Vagus.Backups, name: backups, dir: Path.join(dr, "backup")})

      on_exit(fn ->
        Native.stop(@id)
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
      end)

      start_broker()
      %{port: port, dr: dr, backups: backups}
    end

    test "publishes the mqtt service with the app slug + addons credentials" do
      assert {:ok, @slug, data} = Vagus.App.service("mqtt")
      assert data["host"] == "127.0.0.1"
      assert data["protocol"] == "3.1.1"
      assert data["username"] == "addons"
      assert is_binary(data["password"]) and data["password"] != ""
    end

    test "the published addons credentials authenticate a client", %{port: port} do
      {:ok, @slug, %{"password" => pass}} = Vagus.App.service("mqtt")
      assert connected_within?(connect_auth(port, "addons", pass))
    end

    test "adds an mqtt discovery message for the app" do
      assert Enum.any?(Vagus.App.discoveries(), &(&1.service == "mqtt" and &1.addon == @slug))
    end

    test "retained message + QoS1 round-trip through the broker", %{port: port} do
      {:ok, @slug, %{"password" => pass}} = Vagus.App.service("mqtt")
      pub = connect_auth(port, "addons", pass)
      assert connected_within?(pub)
      :ok = MqttX.Client.publish(pub, "sensor/room", "21.5", qos: 1, retain: true)

      # A subscriber that connects AFTER the retained publish still receives it.
      sub = connect_collector(port, "addons", pass)
      assert connected_within?(sub)
      {:ok, _} = MqttX.Client.subscribe(sub, "sensor/room", qos: 1)
      assert_receive {:mqtt_message, ["sensor", "room"], "21.5"}, 1_000
    end

    test "hot backup then restore preserves the addons password + re-publishes",
         %{dr: dr, backups: backups} do
      {:ok, @slug, %{"password" => pass0}} = Vagus.App.service("mqtt")

      assert {:ok, backup_slug} =
               Vagus.Backups.create_partial(nil, [@slug], server: backups, data_root: dr)

      # Drift the on-disk state so a plain restart would mint a NEW password —
      # only a working restore brings pass0 back.
      state_path = Path.join([dr, "addons", "data", @slug, "broker_state.json"])
      File.write!(state_path, Jason.encode!(%{"addons_password" => "DRIFTED"}))

      # Restore stops the broker, stages the backed-up data dir, and restarts it.
      assert :ok =
               Vagus.Backups.restore_partial(backup_slug, [@slug], server: backups, data_root: dr)

      # The restarted broker re-published the service with the RESTORED password.
      creds =
        eventually(
          fn -> Vagus.App.service("mqtt") end,
          &match?({:ok, @slug, %{"password" => ^pass0}}, &1)
        )

      assert {:ok, @slug, %{"password" => ^pass0}} = creds
    end
  end

  describe "native runtime surfaces (stats / logs / DNS / liveness, MQ-P3)" do
    setup do
      port = free_port()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      dr = tmp_dir()
      Application.put_env(:vagus, :addon_data_root, dr)

      start_supervised!(
        {Vagus.DNS, name: Vagus.DNS, ip: {127, 0, 0, 1}, port: free_port(), upstream: nil}
      )

      on_exit(fn ->
        Native.stop(@id)
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
      end)

      start_broker()
      %{port: port, dr: dr}
    end

    test "stats are process-derived while running and zero when stopped" do
      stats = Native.stats(@id)
      assert stats.memory_usage > 0
      assert stats.cpu_percent == 0.0
      assert stats.memory_limit == 0
      assert Enum.sort(Map.keys(stats)) == Enum.sort(Map.keys(Vagus.Runtime.Stats.zero()))

      assert :ok = App.stop(@slug)
      assert Native.stats(@id) == Vagus.Runtime.Stats.zero()
    end

    test "liveness follows the broker subtree" do
      assert Native.running?(@id)
      assert :ok = App.stop(@slug)
      refute Native.running?(@id)
    end

    test "DNS advertises the broker at the supervisor anchor IP, and a stop withdraws it" do
      assert {:ok, {172, 30, 32, 2}} = Vagus.DNS.resolve("core-mqtt", Vagus.DNS)
      assert :ok = App.stop(@slug)
      assert :error = Vagus.DNS.resolve("core-mqtt", Vagus.DNS)
    end

    # The name is the app process's key, not the DNS server's: a DNS restart
    # loses nothing.
    test "a DNS restart keeps the running app's name" do
      {:ok, test_sup} = ExUnit.fetch_test_supervisor()
      :ok = Supervisor.terminate_child(test_sup, Vagus.DNS)
      assert {:ok, _pid} = Supervisor.restart_child(test_sup, Vagus.DNS)
      assert {:ok, {172, 30, 32, 2}} = Vagus.DNS.resolve("core-mqtt", Vagus.DNS)
    end

    test "logs capture broker activity as text/plain lines", %{port: port} do
      # An anonymous CONNECT is rejected by auth, but mqttx emits the connect
      # telemetry BEFORE auth runs — enough to prove the buffer is wired.
      {:ok, _client} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: port,
          client_id: "logs-probe",
          protocol_version: 4,
          retry_interval: 500
        )

      lines = eventually(fn -> Native.logs(@id) end, &(&1 != []))
      assert is_list(lines)
      assert Enum.any?(lines, &String.contains?(&1, "CONNECT"))
    end
  end

  describe "store catalog" do
    test "the builtin fetcher exposes the native add-on as core_mqtt" do
      catalog = Vagus.Addon.Store.build_catalog([%{slug: "core", builtin: :mqtt}], BuiltinFetcher)
      assert %{"core_mqtt" => %{config: %Config{backend: :native, slug: "mqtt"}}} = catalog
    end
  end

  describe "backend routing (the steps' backend choice, incl. native allowlist)" do
    # Records which backend module's `pull/1` the pull step actually invoked.
    defmodule FakeBackend do
      @moduledoc false
      @behaviour Vagus.Addon.Backend
      @impl true
      def remove_image(_image, _opts \\ []), do: :ok
      @impl true
      def pull(%{name: name}) do
        send(:persistent_term.get(FakeBackend), {:fake_pull, name})
        :ok
      end

      @impl true
      def create(%{name: name}), do: {:ok, name}
      @impl true
      def start(_id), do: :ok
      @impl true
      def stop(_id, _opts \\ []), do: :ok
      @impl true
      def remove(_id, _opts \\ []), do: :ok
      @impl true
      def state(_id), do: {:ok, :stopped}
    end

    setup do
      :persistent_term.put(FakeBackend, self())
      prev = Application.get_env(:vagus, :addon_backend)
      Application.put_env(:vagus, :addon_backend, FakeBackend)
      Application.put_env(:vagus, :native_addon_slugs, ["core_mqtt"])

      on_exit(fn ->
        :persistent_term.erase(FakeBackend)
        Application.delete_env(:vagus, :native_addon_slugs)

        if prev,
          do: Application.put_env(:vagus, :addon_backend, prev),
          else: Application.delete_env(:vagus, :addon_backend)
      end)

      %{dr: tmp_dir()}
    end

    test "a container app routes to the default backend", %{dr: dr} do
      assert {:ok, _image} = pull(container_config("plain_c"), dr)
      assert_receive {:fake_pull, "addon_plain_c"}
    end

    test "a non-allowlisted native app falls back to the default (container) backend",
         %{dr: dr} do
      # SECURITY: an untrusted store app declaring `backend: native` on a
      # non-allowlisted slug must NOT reach Backend.Native — it routes to the
      # default, so it can't run un-sandboxed or impersonate the broker.
      assert {:ok, _image} = pull(rogue_native_config("rogue_native"), dr)
      assert_receive {:fake_pull, "addon_rogue_native"}
    end

    test "an allowlisted native app routes to Backend.Native (not the default)", %{dr: dr} do
      assert {:ok, nil} = pull(mqtt_config(), dr)
      refute_receive {:fake_pull, "addon_core_mqtt"}
    end

    # Host-networked so the pull does not stand up the bridge.
    defp pull(config, dr),
      do:
        Steps.run(:pull, %{
          slug: config.slug,
          config: %{config | host_network: true},
          data_root: dr
        })
  end

  describe "native revive (the app process's rule for a broker that died)" do
    # The process monitors the broker pid its start reported; the steps are
    # stubbed, so the "broker" is a process the test owns. Retry timers run at
    # a hundredth of their real length: 5 s becomes 50 ms, 30 s 300 ms.
    setup do
      stub_app_steps()
      app_deadlines(%{retry: &div(&1, 100), start: 5_000})
      Application.put_env(:vagus, :native_addon_slugs, ["core_mqtt"])
      on_exit(fn -> Application.delete_env(:vagus, :native_addon_slugs) end)
      :ok
    end

    defp running_broker(attrs \\ %{}) do
      install_app(Map.merge(mqtt_config(), attrs))
      [{pid, _}] = Registry.lookup(Vagus.App.Directory, {:slug, @slug})
      start = Task.async(fn -> App.start(@slug) end)
      broker = answer_start()
      assert {:ok, _} = Task.await(start)
      {pid, broker}
    end

    defp answer_start(outcome \\ :ok) do
      assert_receive {:step, :start, _input, task}, 2_000

      case outcome do
        :ok ->
          broker = spawn(fn -> Process.sleep(:infinity) end)
          send(task, {:outcome, {:ok, %{container_id: @id, ip: "172.30.32.2", pid: broker}}})
          broker

        error ->
          send(task, {:outcome, error})
      end
    end

    test "a broker that dies is started again after 5 s, then every 30 s" do
      {_pid, broker} = running_broker()
      died = System.monotonic_time(:millisecond)
      Process.exit(broker, :kill)

      assert_receive {:step, :start, _input, task}, 2_000
      first = System.monotonic_time(:millisecond)
      assert first - died >= 50
      send(task, {:outcome, {:error, :eaddrinuse}})

      answer_start()
      assert System.monotonic_time(:millisecond) - first >= 300
    end

    test "a broker stopped by the user is not revived" do
      {pid, broker} = running_broker()
      stop = Task.async(fn -> App.stop(@slug) end)
      assert_receive {:step, :stop, _input, task}, 2_000
      Process.exit(broker, :kill)
      send(task, {:outcome, {:ok, %{was_running: true}}})
      assert :ok = Task.await(stop)

      _ = :sys.get_state(pid)
      refute_receive {:step, :start, _input, _task}, 300
    end

    test "a manual-boot broker is not revived" do
      {_pid, broker} = running_broker(%{boot: "manual"})
      Process.exit(broker, :kill)
      refute_receive {:step, :start, _input, _task}, 300
      assert {:ok, %{state: :error}} = App.info(@slug)
    end
  end

  # ---------- helpers ----------

  defp container_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "c",
        "version" => "1",
        "slug" => slug,
        "description" => "c",
        "arch" => ["amd64"],
        "image" => "example/{arch}-thing"
      })

    config
  end

  defp rogue_native_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "r",
        "version" => "1",
        "slug" => slug,
        "description" => "r",
        "arch" => ["amd64"],
        "backend" => "native"
      })

    config
  end

  defp connect_auth(port, user, pass), do: connect(port, user, pass, [])

  defp connect_collector(port, user, pass),
    do: connect(port, user, pass, handler: Collector, handler_state: %{pid: self()})

  defp connect(port, user, pass, extra) do
    {:ok, client} =
      MqttX.Client.connect(
        [
          host: "127.0.0.1",
          port: port,
          client_id: "c-#{System.unique_integer([:positive])}",
          protocol_version: 4,
          username: user,
          password: pass,
          retry_interval: 300
        ] ++ extra
      )

    client
  end

  defp connected_within?(client, tries \\ 60) do
    cond do
      MqttX.Client.connected?(client) -> true
      tries == 0 -> false
      true -> Process.sleep(25) && connected_within?(client, tries - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:vagus, key)
  defp restore_env(key, value), do: Application.put_env(:vagus, key, value)

  # Poll `fun` until `pred` holds (or the budget runs out); returns the last value.
  defp eventually(fun, pred, tries \\ 50) do
    value = fun.()

    cond do
      pred.(value) -> value
      tries == 0 -> value
      true -> Process.sleep(20) && eventually(fun, pred, tries - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "vagus_native_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
