defmodule Vagus.Addon.Backend.NativeTest do
  # async: false — drives the app-global Native.Supervisor / State and binds a
  # real TCP port for the broker subtree.
  use ExUnit.Case, async: false

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.{Config, Info, Manager, State}
  alias Vagus.Addon.Store.BuiltinFetcher

  @slug "core_mqtt"
  @id "addon_core_mqtt"

  # The store rewrites `config.slug` to the store slug on install (router
  # handle_install); mirror that so the installed add-on runs under "core_mqtt".
  defp mqtt_config do
    {:ok, config} = Config.parse(BuiltinFetcher.config(:mqtt))
    %{config | slug: @slug}
  end

  # A State stub whose `list/0` reports one :started native add-on, to exercise
  # the sentinel's init-reconcile (watch set rebuilt from State, not from watch/1).
  # Defined here (before its use) so the module alias is in scope.
  defmodule ReconcileState do
    @moduledoc false

    def list do
      {_pid, slug} = :persistent_term.get(__MODULE__)

      {:ok, config} =
        Vagus.Addon.Config.parse(%{
          "name" => "rc",
          "version" => "1",
          "slug" => slug,
          "description" => "rc",
          "arch" => ["amd64"],
          "backend" => "native"
        })

      [%{state: :started, config: config}]
    end

    def get(_slug) do
      {_pid, slug} = :persistent_term.get(__MODULE__)
      {:ok, %{config: {:reconciled, slug}}}
    end

    def put(config, state) do
      {pid, _slug} = :persistent_term.get(__MODULE__)
      send(pid, {:state_put, config, state})
      :ok
    end
  end

  describe "native add-on lifecycle (real broker subtree, Manager routes to :native)" do
    setup do
      port = free_port()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      data_root = tmp_dir()
      Application.put_env(:vagus, :addon_data_root, data_root)

      on_exit(fn ->
        Manager.uninstall(@slug, data_root: data_root)
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
      end)

      %{config: mqtt_config(), port: port, data_root: data_root}
    end

    test "install → start → state → stop → uninstall", %{
      config: config,
      port: port,
      data_root: dr
    } do
      # install routes to Native.pull (no Docker); the router persists :stopped.
      assert :ok = Manager.install(config, data_root: dr)
      :ok = State.put(config, :stopped)

      # start routes to Native → a real supervised broker subtree.
      assert {:ok, %{id: @id}} = Manager.start(config, data_root: dr)
      assert {:ok, :running} = Native.state(@id)
      assert {:ok, %{state: :started}} = State.get(@slug)

      # the listener is actually bound on the configured port.
      assert {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 1_000)
      :gen_tcp.close(sock)

      # Info.render surfaces the add-on from its Config (no backend coupling).
      info = Info.render(config, :started, config.options)
      assert info["slug"] == @slug
      assert info["name"] == config.name

      # stop tears the subtree down and records :stopped.
      assert :ok = Manager.stop(@slug, data_root: dr)
      assert {:ok, :stopped} = Native.state(@id)
      assert {:ok, %{state: :stopped}} = State.get(@slug)
      assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 500)

      # uninstall purges State.
      assert :ok = Manager.uninstall(@slug, data_root: dr)
      assert :error = State.get(@slug)
    end

    test "start is idempotent and stop tolerates an already-stopped add-on", %{
      config: config,
      data_root: dr
    } do
      assert :ok = Manager.install(config, data_root: dr)
      :ok = State.put(config, :stopped)
      assert {:ok, _} = Manager.start(config, data_root: dr)

      # Native.start on an already-running id is :ok, not a crash.
      assert :ok = Native.start(@id)
      assert {:ok, :running} = Native.state(@id)

      assert :ok = Manager.stop(@slug, data_root: dr)
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
      dr = tmp_dir()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      # Align the Provider's data dir (config) with the Manager's (opt) so the
      # persisted broker_state.json rides in the backup tar.
      Application.put_env(:vagus, :addon_data_root, dr)

      backups = :"backups_#{System.unique_integer([:positive])}"
      start_supervised!({Vagus.Backups, name: backups, dir: Path.join(dr, "backup")})

      config = mqtt_config()
      assert :ok = Manager.install(config, data_root: dr)
      :ok = State.put(config, :stopped)
      assert {:ok, _} = Manager.start(config, data_root: dr)

      on_exit(fn ->
        Manager.uninstall(@slug, data_root: dr)
        Vagus.Services.delete_by_slug(@slug)
        Vagus.Discovery.delete_by_slug(@slug)
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
      end)

      %{port: port, dr: dr, backups: backups}
    end

    test "publishes the mqtt service with the add-on slug + addons credentials" do
      assert {:ok, data} = Vagus.Services.get("mqtt")
      assert data["addon"] == @slug
      assert data["host"] == "127.0.0.1"
      assert data["protocol"] == "3.1.1"
      assert data["username"] == "addons"
      assert is_binary(data["password"]) and data["password"] != ""
    end

    test "the published addons credentials authenticate a client", %{port: port} do
      {:ok, %{"password" => pass}} = Vagus.Services.get("mqtt")
      assert connected_within?(connect_auth(port, "addons", pass))
    end

    test "adds an mqtt discovery message for the add-on" do
      assert Enum.any?(Vagus.Discovery.list(), &(&1.service == "mqtt" and &1.addon == @slug))
    end

    test "retained message + QoS1 round-trip through the broker", %{port: port} do
      {:ok, %{"password" => pass}} = Vagus.Services.get("mqtt")
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
      {:ok, %{"password" => pass0}} = Vagus.Services.get("mqtt")

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
          fn -> Vagus.Services.get("mqtt") end,
          &match?({:ok, %{"password" => ^pass0}}, &1)
        )

      assert {:ok, %{"password" => ^pass0}} = creds
    end
  end

  describe "native runtime surfaces (stats / logs / DNS / watchdog liveness, MQ-P3)" do
    setup do
      port = free_port()
      prev_port = Application.get_env(:vagus, :mqtt_broker_port)
      prev_root = Application.get_env(:vagus, :addon_data_root)
      Application.put_env(:vagus, :mqtt_broker_port, port)
      dr = tmp_dir()
      Application.put_env(:vagus, :addon_data_root, dr)

      # A DNS server under the global name so Manager.register_dns finds it
      # (the app doesn't start one in :test — dns_enabled is false).
      start_supervised!(
        {Vagus.DNS, name: Vagus.DNS, ip: {127, 0, 0, 1}, port: free_port(), upstream: nil}
      )

      config = mqtt_config()
      assert :ok = Manager.install(config, data_root: dr)
      :ok = State.put(config, :stopped)
      assert {:ok, _} = Manager.start(config, data_root: dr)

      on_exit(fn ->
        Manager.uninstall(@slug, data_root: dr)
        Vagus.Services.delete_by_slug(@slug)
        Vagus.Discovery.delete_by_slug(@slug)
        restore_env(:mqtt_broker_port, prev_port)
        restore_env(:addon_data_root, prev_root)
      end)

      %{port: port, dr: dr}
    end

    test "stats are process-derived while running and zero when stopped", %{dr: dr} do
      stats = Native.stats(@id)
      assert stats.memory_usage > 0
      assert stats.cpu_percent == 0.0
      assert stats.memory_limit == 0
      assert Enum.sort(Map.keys(stats)) == Enum.sort(Map.keys(Vagus.Runtime.Stats.zero()))

      assert :ok = Manager.stop(@slug, data_root: dr)
      assert Native.stats(@id) == Vagus.Runtime.Stats.zero()
    end

    test "watchdog liveness follows the broker subtree", %{dr: dr} do
      assert Native.running?(@id)
      assert :ok = Manager.stop(@slug, data_root: dr)
      refute Native.running?(@id)
    end

    test "DNS advertises the broker at the supervisor anchor IP" do
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

  describe "backend routing (Manager.put_backend, incl. native allowlist)" do
    # Records which backend module's `pull/1` the Manager actually invoked.
    defmodule FakeBackend do
      @moduledoc false
      @behaviour Vagus.Addon.Backend
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

    test "a container add-on routes to the default backend", %{dr: dr} do
      assert :ok = Manager.install(container_config("plain_c"), data_root: dr)
      assert_receive {:fake_pull, "addon_plain_c"}
    end

    test "a non-allowlisted native add-on falls back to the default (container) backend",
         %{dr: dr} do
      # SECURITY: an untrusted store add-on declaring `backend: native` on a
      # non-allowlisted slug must NOT reach Backend.Native — it routes to the
      # default, so it can't run un-sandboxed or impersonate the broker.
      assert :ok = Manager.install(rogue_native_config("rogue_native"), data_root: dr)
      assert_receive {:fake_pull, "addon_rogue_native"}
    end

    test "an allowlisted native add-on routes to Backend.Native (not the default)", %{dr: dr} do
      assert :ok = Manager.install(mqtt_config(), data_root: dr)
      refute_receive {:fake_pull, "addon_core_mqtt"}
    end
  end

  describe "Sentinel (native lifecycle → State sync, MQ-P2-T3)" do
    defmodule FakeState do
      @moduledoc false
      # Empty catalog so init-reconcile is a no-op for these unit tests.
      def list, do: []
      def get(_slug), do: {:ok, %{config: :fake_config}}

      def put(config, state) do
        send(:persistent_term.get(__MODULE__), {:state_put, config, state})
        :ok
      end
    end

    setup do
      :persistent_term.put(FakeState, self())
      on_exit(fn -> :persistent_term.erase(FakeState) end)
      name = :"sentinel_#{System.unique_integer([:positive])}"
      start_supervised!({Native.Sentinel, name: name, state_mod: FakeState, recheck_ms: 100})
      %{sentinel: name}
    end

    test "demotes to :stopped when a watched broker does not restart", %{sentinel: sentinel} do
      id = unique_id()
      {:ok, dummy} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      watch_sync(sentinel, id)
      Agent.stop(dummy)

      # No process re-registers broker_name(id) → permanent death → demote.
      assert_receive {:state_put, :fake_config, :stopped}, 1_000
    end

    test "does NOT demote when the broker is restarted before the recheck", %{sentinel: sentinel} do
      id = unique_id()
      {:ok, dummy1} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      watch_sync(sentinel, id)
      Agent.stop(dummy1)
      # Re-register under the same name before the recheck fires — simulates OTP
      # bringing the broker back; the sentinel must re-monitor, not demote.
      {:ok, _dummy2} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      refute_receive {:state_put, _config, :stopped}, 400
    end

    test "does NOT demote after an intentional unwatch (manual stop)", %{sentinel: sentinel} do
      id = unique_id()
      {:ok, dummy} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      watch_sync(sentinel, id)
      Native.Sentinel.unwatch(id, sentinel)
      # A synchronous state read flushes the unwatch cast before we kill the pid.
      :sys.get_state(sentinel)
      Agent.stop(dummy)

      refute_receive {:state_put, _config, :stopped}, 400
    end

    test "reconciles a running native broker from State at init (no watch/1 call)" do
      slug = "rc_#{System.unique_integer([:positive])}"
      id = "addon_#{slug}"
      {:ok, _broker} = Agent.start(fn -> :ok end, name: Native.broker_name(id))

      :persistent_term.put(ReconcileState, {self(), slug})
      on_exit(fn -> :persistent_term.erase(ReconcileState) end)

      name = :"sentinel_rc_#{System.unique_integer([:positive])}"
      # Distinct child id — the describe's setup already supervises a Sentinel
      # under the default (module) id.
      start_supervised!(
        Supervisor.child_spec(
          {Native.Sentinel, name: name, state_mod: ReconcileState, recheck_ms: 100},
          id: name
        )
      )

      # Flush init + the {:continue, :reconcile} that rebuilds the watch set.
      :sys.get_state(name)

      Agent.stop(Process.whereis(Native.broker_name(id)))
      assert_receive {:state_put, {:reconciled, ^slug}, :stopped}, 1_000
    end
  end

  describe "Sentinel revive (native watchdog for boot:auto add-ons)" do
    # A stateful fake: demote's put/2 updates the entry the later revive
    # re-reads, so the skip-if-changed logic is exercised for real.
    defmodule ReviveState do
      @moduledoc false
      def list, do: []
      def get(_slug), do: :persistent_term.get({__MODULE__, :entry}, {:error, :not_found})

      def put(config, s) do
        send(:persistent_term.get(__MODULE__), {:state_put, config, s})
        :persistent_term.put({__MODULE__, :entry}, {:ok, %{state: s, config: config}})
        :ok
      end
    end

    defp start_revive_sentinel(ctx_name, config, revive_fun) do
      :persistent_term.put(ReviveState, self())
      :persistent_term.put({ReviveState, :entry}, {:ok, %{state: :started, config: config}})

      on_exit(fn ->
        :persistent_term.erase(ReviveState)
        :persistent_term.erase({ReviveState, :entry})
      end)

      start_supervised!(
        Supervisor.child_spec(
          {Native.Sentinel,
           name: ctx_name,
           state_mod: ReviveState,
           recheck_ms: 50,
           revive_delay_ms: 50,
           revive_retry_ms: 50,
           revive_fun: revive_fun},
          id: ctx_name
        )
      )

      ctx_name
    end

    defp kill_watched_broker(sentinel, id) do
      {:ok, dummy} = Agent.start(fn -> :ok end, name: Native.broker_name(id))
      watch_sync(sentinel, id)
      Agent.stop(dummy)
    end

    test "revives a boot:auto add-on after demotion (watch re-armed by Manager path)" do
      test = self()
      id = unique_id()
      slug = Native.slug_from_id(id)
      config = %{boot: "auto", slug: slug}

      sentinel =
        start_revive_sentinel(:"rv_#{System.unique_integer([:positive])}", config, fn cfg ->
          send(test, {:revive_called, cfg})
          {:ok, %{id: id}}
        end)

      kill_watched_broker(sentinel, id)

      assert_receive {:state_put, ^config, :stopped}, 1_000
      assert_receive {:revive_called, ^config}, 1_000
    end

    test "a failed revive retries on the fixed interval" do
      test = self()
      id = unique_id()
      config = %{boot: "auto", slug: Native.slug_from_id(id)}

      sentinel =
        start_revive_sentinel(:"rv_#{System.unique_integer([:positive])}", config, fn _cfg ->
          send(test, :revive_attempt)
          {:error, :port_busy}
        end)

      kill_watched_broker(sentinel, id)

      assert_receive :revive_attempt, 1_000
      # No cap, fixed interval: further attempts keep coming.
      assert_receive :revive_attempt, 1_000
      assert_receive :revive_attempt, 1_000
    end

    test "no revive when the add-on was manually started before the delay fired" do
      test = self()
      id = unique_id()
      config = %{boot: "auto", slug: Native.slug_from_id(id)}

      sentinel =
        start_revive_sentinel(:"rv_#{System.unique_integer([:positive])}", config, fn cfg ->
          send(test, {:revive_called, cfg})
          {:ok, %{}}
        end)

      kill_watched_broker(sentinel, id)
      assert_receive {:state_put, ^config, :stopped}, 1_000

      # Someone starts it manually before the revive delay elapses.
      :persistent_term.put({ReviveState, :entry}, {:ok, %{state: :started, config: config}})
      refute_receive {:revive_called, _}, 400
    end

    test "no revive when boot flipped to manual after the demotion scheduled it" do
      test = self()
      id = unique_id()
      config = %{boot: "auto", slug: Native.slug_from_id(id)}

      sentinel =
        start_revive_sentinel(:"rv_#{System.unique_integer([:positive])}", config, fn cfg ->
          send(test, {:revive_called, cfg})
          {:ok, %{}}
        end)

      kill_watched_broker(sentinel, id)
      assert_receive {:state_put, ^config, :stopped}, 1_000

      # Config edited (e.g. re-install) to boot: manual before the revive
      # delay elapses — the CURRENT config must win.
      manual = %{config | boot: "manual"}
      :persistent_term.put({ReviveState, :entry}, {:ok, %{state: :stopped, config: manual}})
      refute_receive {:revive_called, _}, 400
    end

    test "no revive for a non-auto add-on" do
      test = self()
      id = unique_id()
      config = %{boot: "manual", slug: Native.slug_from_id(id)}

      sentinel =
        start_revive_sentinel(:"rv_#{System.unique_integer([:positive])}", config, fn cfg ->
          send(test, {:revive_called, cfg})
          {:ok, %{}}
        end)

      kill_watched_broker(sentinel, id)

      assert_receive {:state_put, ^config, :stopped}, 1_000
      refute_receive {:revive_called, _}, 400
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

  # Watch, then flush the cast with a synchronous state read so the monitor is
  # established before the test kills the process (no Process.sleep race).
  defp watch_sync(sentinel, id) do
    Native.Sentinel.watch(id, sentinel)
    :sys.get_state(sentinel)
    :ok
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

  defp unique_id, do: "addon_sentinel_#{System.unique_integer([:positive])}"

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
