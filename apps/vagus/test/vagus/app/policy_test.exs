defmodule Vagus.App.PolicyTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Policy

  @mqtt %{uuid: "u1", addon: "mosq", service: "mqtt", config: %{"host" => "a"}}

  describe "discover/5" do
    test "an unseen app and service is new, under the fresh uuid" do
      assert {:new, %{uuid: "u2", addon: "mosq", service: "other", config: %{}}} =
               Policy.discover([@mqtt], "mosq", "other", %{}, "u2")

      assert {:new, %{uuid: "u2", addon: "zigbee"}} =
               Policy.discover([@mqtt], "zigbee", "mqtt", %{"host" => "a"}, "u2")
    end

    test "the same app, service and config is the existing message, untouched" do
      assert {:existing, @mqtt} ==
               Policy.discover([@mqtt], "mosq", "mqtt", %{"host" => "a"}, "u2")
    end

    test "a changed config keeps the uuid" do
      assert {:updated, %{@mqtt | config: %{"host" => "b"}}} ==
               Policy.discover([@mqtt], "mosq", "mqtt", %{"host" => "b"}, "u2")
    end
  end

  describe "service roles" do
    @roles %{"mqtt" => "provide", "zigbee" => "want", "db" => "need"}

    test "only the provide role may provide" do
      caller = {:addon, %{slug: "a", services_role: @roles}}

      assert Policy.may_provide?(caller, "mqtt")
      refute Policy.may_provide?(caller, "zigbee")
      refute Policy.may_provide?(caller, "unknown")
      refute Policy.may_provide?(:supervisor, "mqtt")
      refute Policy.may_provide?(nil, "mqtt")
    end

    test "Core always reads; an app with any role for the service reads it" do
      caller = {:addon, %{slug: "a", services_role: @roles}}

      assert Policy.may_read_service?(:supervisor, "anything")

      for service <- ["mqtt", "zigbee", "db"],
          do: assert(Policy.may_read_service?(caller, service))

      refute Policy.may_read_service?(caller, "unknown")
      refute Policy.may_read_service?(nil, "mqtt")
    end
  end

  describe "services_view/1" do
    test "lists every known service, provided or not" do
      assert [%{slug: "mqtt", available: false, providers: []}] = Policy.services_view([])

      assert [%{slug: "mqtt", available: true, providers: ["mosq"]}] =
               Policy.services_view([{"mqtt", "mosq"}, {"unknown", "x"}])
    end
  end

  alias Vagus.Addon.Config

  @ip "172.30.33.5"

  defp app_config(extra \\ %{}) do
    {:ok, config} =
      %{
        "name" => "App One",
        "version" => "1.0.0",
        "slug" => "app_one",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/{arch}-app"
      }
      |> Map.merge(extra)
      |> Config.parse()

    config
  end

  defp native_config,
    do:
      app_config(%{"slug" => "core_mqtt", "backend" => "native", "boot" => "auto"})
      |> Map.put(:image, nil)

  defp app(extra \\ %{}) do
    "app_one"
    |> Policy.init_data(%{config: app_config(), wanted: :started, watchdog: true})
    |> Map.merge(extra)
  end

  defp running(extra \\ %{}),
    do: app(Map.merge(%{container_id: "c1", ip: @ip, last_event: {:running, false}}, extra))

  defp begin(op, args, data), do: Policy.next(Policy.plan(op, args, data), :begin, data)
  defp step(data, outcome), do: Policy.next(data.run, outcome, data)

  describe "derive/2" do
    test "from the last event, upstream's mapping" do
      for {event, state} <- [
            {nil, :stopped},
            {:stopped, :stopped},
            {{:running, true}, :startup},
            {{:running, false}, :started},
            {:healthy, :started},
            {:unhealthy, :started},
            {{:exited, 0}, :stopped},
            {{:exited, 137}, :error},
            {{:exited, :down}, :error},
            {{:failed, :boom}, :error}
          ],
          do: assert(Policy.derive(:idle, app(%{last_event: event})) == state, inspect(event))
    end

    test "a process with no file yet reports unknown" do
      assert Policy.derive(:new, running()) == :unknown
    end

    test "a once app's clean exit is stopped" do
      once = app(%{config: app_config(%{"startup" => "once"}), last_event: {:exited, 0}})
      assert Policy.derive(:idle, once) == :stopped
    end
  end

  describe "on_event/2" do
    test "a start of the app's container while none is known adopts it" do
      data = app(%{wanted: :stopped})
      {adopted, effects} = Policy.on_event(%{action: "start", id: "c9"}, data)

      assert %{container_id: "c9", last_event: {:running, false}} = adopted
      assert effects == [{:emit, :started}]
    end

    test "a start event for a known container changes nothing" do
      data = running(%{last_event: {:running, true}})
      assert Policy.on_event(%{action: "start", id: "c1"}, data) == {data, []}
      assert Policy.on_event(%{action: "start", id: "c2"}, data) == {data, []}
    end

    test "an exit of a container other than the current one is ignored" do
      data = running()
      assert Policy.on_event(%{action: "die", id: "old", exit_code: 1}, data) == {data, []}
    end

    test "a late start and exit of a container this process stopped change nothing" do
      {data, _} = begin(:stop, %{}, running(%{token_hash: "h"}))
      {stopped, _} = step(data, {:ok, %{was_running: true}})
      assert stopped.released == ["c1"]

      for event <- [%{action: "start", id: "c1"}, %{action: "die", id: "c1", exit_code: 1}],
          do: assert(Policy.on_event(event, stopped) == {stopped, []})

      assert {%{container_id: "c9"}, _} = Policy.on_event(%{action: "start", id: "c9"}, stopped)
    end

    test "an exit after a stop (no current container) is ignored" do
      data = app(%{wanted: :stopped})
      assert Policy.on_event(%{action: "die", id: "c1", exit_code: 0}, data) == {data, []}
    end

    test "a crash with the watchdog on drops the run keys and restarts at once" do
      data = running(%{token_hash: "h"})

      assert {after_crash, effects} =
               Policy.on_event(%{action: "die", id: "c1", exit_code: 1}, data)

      assert effects == [
               {:emit, :error},
               {:keys, [], [{:token, "h"}, {:dns, "app-one"}]},
               {:cancel, :probe},
               {:cancel, :settled},
               {:timer, :retry, 0, {:retry, "c1"}}
             ]

      assert %{attempt: 1, ip: nil, token_hash: nil, container_id: "c1"} = after_crash
    end

    test "a clean exit of a long-running app is restarted too, as upstream does" do
      {_data, effects} = Policy.on_event(%{action: "die", id: "c1", exit_code: 0}, running())
      assert {:timer, :retry, 0, {:retry, "c1"}} in effects
      assert {:emit, :stopped} in effects
    end

    test "a once app's clean exit completes it: no restart, wanted kept" do
      data = running(%{config: app_config(%{"startup" => "once"})})
      {after_exit, effects} = Policy.on_event(%{action: "die", id: "c1", exit_code: 0}, data)
      refute Enum.any?(effects, &match?({:timer, :retry, _, _}, &1))
      assert after_exit.wanted == :started
      assert after_exit.attempt == 0
    end

    test "a crash with the watchdog off reports error and does nothing more" do
      data = running(%{watchdog: false})
      {after_crash, effects} = Policy.on_event(%{action: "die", id: "c1", exit_code: 2}, data)
      assert {:emit, :error} in effects
      refute Enum.any?(effects, &match?({:timer, :retry, _, _}, &1))
      assert after_crash.attempt == 0
    end

    test "nothing is restarted while the host shuts down" do
      data = running(%{shutting_down: true})
      {_data, effects} = Policy.on_event(%{action: "die", id: "c1", exit_code: 2}, data)
      refute Enum.any?(effects, &match?({:timer, :retry, _, _}, &1))
    end

    test "healthy moves startup to started" do
      data = running(%{last_event: {:running, true}})

      assert {%{last_event: :healthy}, [{:emit, :started}]} =
               Policy.on_event(%{action: "health_status: healthy", id: "c1"}, data)
    end

    test "unhealthy keeps started and restarts on the ladder" do
      {data, effects} =
        Policy.on_event(%{action: "health_status: unhealthy", id: "c1"}, running())

      assert effects == [{:timer, :retry, 0, {:retry, "c1"}}]
      assert data.last_event == :unhealthy
    end

    test "the native broker going down is revived after 5 s, watchdog flag or not" do
      data = running(%{config: native_config(), slug: "core_mqtt", watchdog: false})
      {data, effects} = Policy.on_event({:broker_down, :killed}, data)
      assert {:timer, :retry, 5_000, {:retry, "c1"}} in effects
      assert {:emit, :error} in effects
      assert data.attempt == 1
    end

    test "a broker DOWN for an app that is not running is ignored" do
      data = app(%{config: native_config()})
      assert Policy.on_event({:broker_down, :normal}, data) == {data, []}
    end

    test "a restart that stays up resets the ladder" do
      assert {%{attempt: 0}, []} = Policy.on_event(:settled, running(%{attempt: 4}))
    end

    test "unknown events change nothing" do
      data = running()
      assert Policy.on_event(%{action: "exec_start", id: "c1"}, data) == {data, []}
    end
  end

  describe "restart?/2 and backoff/1" do
    test "the container ladder: at once, then 10 s doubling, five attempts" do
      delays =
        for attempt <- 0..4 do
          data = running(%{attempt: attempt})
          assert Policy.restart?(data, false)
          Policy.backoff(data)
        end

      assert delays == [0, 10_000, 20_000, 40_000, 80_000]
      refute Policy.restart?(running(%{attempt: 5}), false)
    end

    test "watchdog off, not wanted, or shutting down: no restart" do
      refute Policy.restart?(running(%{watchdog: false}), false)
      refute Policy.restart?(running(%{wanted: :stopped}), false)
      refute Policy.restart?(running(), true)
    end

    test "native: boot auto revives forever, 5 s then every 30 s" do
      data = running(%{config: native_config(), watchdog: false})
      assert Policy.restart?(%{data | attempt: 50}, false)
      assert Policy.backoff(%{data | attempt: 0}) == 5_000
      assert Policy.backoff(%{data | attempt: 7}) == 30_000
      refute Policy.restart?(%{data | boot: "manual"}, false)
      refute Policy.restart?(data, true)
    end

    test "a native-declared app outside the allowlist is a container app" do
      config = app_config(%{"backend" => "native"})
      data = running(%{config: config, watchdog: false})
      refute Policy.restart?(data, false)
    end
  end

  describe "strike/2" do
    test "one miss is a strike; a hit clears it" do
      assert {%{strikes: 1}, [{:timer, :probe, _, :probe}]} = Policy.strike(:unhealthy, running())

      assert {%{strikes: 0}, [{:timer, :probe, _, :probe}]} =
               Policy.strike(:healthy, running(%{strikes: 1}))

      assert {%{strikes: 1}, [{:timer, :probe, _, :probe}]} =
               Policy.strike(:skip, running(%{strikes: 1}))
    end

    test "the second miss is a restart on the crash ladder" do
      {data, effects} = Policy.strike(:unhealthy, running(%{strikes: 1, attempt: 2}))
      assert effects == [{:timer, :retry, 20_000, {:retry, "c1"}}]
      assert %{strikes: 0, attempt: 3} = data
    end

    test "with the ladder spent the app reports error and the probe stops" do
      {data, effects} = Policy.strike(:unhealthy, running(%{strikes: 1, attempt: 5}))
      assert effects == [{:emit, :error}]
      assert data.last_event == {:failed, :unhealthy}
    end
  end

  describe "admit/2" do
    test "per state" do
      table = [
        {:install, :new, :ok},
        {:start, :new, {:error, :not_installed}},
        {:halt, :new, {:error, :not_installed}},
        {{:install, %{}}, :idle, {:error, :already_installed}},
        {:start, :idle, :ok},
        {{:update, %{}}, :idle, :ok},
        {:halt, :idle, :ok},
        {:resume, :idle, :noop},
        {:start, {:busy, :update}, {:error, :busy}},
        {:uninstall, {:busy, :start}, {:error, :busy}},
        {:halt, {:busy, :update}, :ok},
        {:halt, {:busy, :halt}, {:error, :busy}},
        {:start, :shutting_down, {:error, :shutting_down}},
        {:halt, :shutting_down, :noop},
        {:resume, :shutting_down, :ok}
      ]

      for {command, state, expected} <- table,
          do: assert(Policy.admit(command, state) == expected, inspect({command, state}))
    end
  end

  describe "boot/2 with app data" do
    test "a stopped wanted app starts on auto; manual demotes; a container it did not start is started again" do
      assert Policy.boot(app(), false) == :start
      assert Policy.boot(app(%{boot: "manual"}), false) == :demote
      assert Policy.boot(app(), :unknown) == :start
      assert Policy.boot(app(%{boot: "manual"}), :unknown) == :none
      assert Policy.boot(app(), true) == :start
      assert Policy.boot(app(%{boot: "manual"}), true) == :start
      assert Policy.boot(app(), :managed) == :none
      assert Policy.boot(app(%{wanted: :stopped}), true) == :none
      assert Policy.boot(app(%{wanted: :stopped}), false) == :none
    end
  end

  describe "keys/1" do
    test "a running bridged app: slug, token, DNS name with its IP" do
      assert Policy.keys(running(%{token_hash: "h"})) ==
               [{:slug, "app_one"}, {:token, "h"}, {{:dns, "app-one"}, @ip}]
    end

    test "a host-network app has no DNS record" do
      data = running(%{config: app_config(%{"host_network" => true})})
      assert Policy.keys(data) == [{:slug, "app_one"}]
    end

    test "a native app's record is the supervisor IP it was started with" do
      data = running(%{config: native_config(), slug: "core_mqtt", ip: "172.30.32.2"})
      assert {{:dns, "core-mqtt"}, "172.30.32.2"} in Policy.keys(data)
    end

    test "only a dynamic ingress port is a key; the ingress token is, hashed" do
      dynamic = app_config(%{"ingress" => true, "ingress_port" => 0})
      static = app_config(%{"ingress" => true, "ingress_port" => 8099})
      data = app(%{config: dynamic, ingress_token: "it", ingress_port: 62_001})

      assert Policy.keys(data) ==
               [{:slug, "app_one"}, {:ingress_token, Policy.hash("it")}, {:ingress_port, 62_001}]

      assert Policy.keys(%{data | config: static}) ==
               [{:slug, "app_one"}, {:ingress_token, Policy.hash("it")}]
    end

    test "services and discovery carry the owner's slug" do
      data = app(%{services: %{"mqtt" => %{}}, discovery: %{"u1" => %{}}})

      assert Policy.keys(data) == [
               {:slug, "app_one"},
               {{:service, "mqtt"}, "app_one"},
               {{:discovery, "u1"}, "app_one"}
             ]
    end

    test "the DNS name lowercases and dashes" do
      assert Policy.dns_name("Foo_Bar") == "foo-bar"
    end
  end

  describe "answer/2 and snapshot/1" do
    test "info is the State-entry shape with the reported state" do
      data = running(%{user_options: %{"a" => 1}})
      assert {:ok, entry} = Policy.answer(:info, data)
      assert %{state: :started, wanted: :started, user_options: %{"a" => 1}} = entry
      assert entry.config == data.config
      refute Map.has_key?(entry, :token)
      refute Map.has_key?(entry, :container_id)
    end

    test "identity carries the service roles" do
      data = app(%{config: %{app_config() | services: ["mqtt:provide", "bad"]}})

      assert {:ok, %{slug: "app_one", services_role: %{"mqtt" => "provide"}}} =
               Policy.answer(:identity, data)
    end

    test "ingress target: the dynamic port wins, a host-network app names no address" do
      config = app_config(%{"ingress" => true, "ingress_port" => 0, "ingress_stream" => true})
      data = running(%{config: config, ingress_port: 62_001})
      assert Policy.answer(:ingress_target, data) == {:ok, {@ip, 62_001, true}}

      host = %{data | config: %{config | host_network: true}}
      assert Policy.answer(:ingress_target, host) == {:ok, {:host_network, 62_001, true}}

      assert Policy.answer(:ingress_target, %{data | ip: nil}) == {:error, :no_container_ip}

      assert Policy.answer(:ingress_target, %{data | ingress_port: nil}) ==
               {:error, :no_ingress_port}
    end

    test "a process with no file yet answers as an app that is not installed" do
      data = Policy.init_data("app_one", nil)

      for {question, answer} <- [
            info: :error,
            snapshot: :error,
            identity: :error,
            installed?: false,
            discovery_list: [],
            ingress_target: {:error, :not_found},
            service: :error
          ] do
        question = if question == :service, do: {:service, "mqtt"}, else: question
        assert Policy.answer(question, data) == answer, inspect(question)
      end
    end

    test "services, discovery, and an unknown question" do
      data = app(%{services: %{"mqtt" => %{"p" => 1}}, discovery: %{"u" => %{uuid: "u"}}})
      assert Policy.answer({:service, "mqtt"}, data) == {:ok, %{"p" => 1}}
      assert Policy.answer({:service, "x"}, data) == :error
      assert Policy.answer({:discovery, "u"}, data) == {:ok, %{uuid: "u"}}
      assert Policy.answer(:discovery_list, data) == [%{uuid: "u"}]
      assert Policy.answer(:what, data) == {:error, :unknown_question}
    end
  end

  describe "plan/3" do
    test "the step list per op" do
      table = [
        {:install, %{config: app_config()}, [{:pull, nil}, {:port?, nil}, {:commit, nil}]},
        {:start, %{}, [{:port?, nil}, {:mint_token, nil}, {:start, nil}]},
        {:stop, %{}, [{:stop, nil}]},
        {:restart, %{}, [{:stop, nil}, {:port?, nil}, {:mint_token, nil}, {:start, nil}]},
        {:uninstall, %{}, [{:stop, nil}, {:delete_file, nil}, {:remove_app, nil}]},
        {:halt, %{}, [{:halt_stop, nil}]},
        {:restore, %{start?: false},
         [{:stop, nil}, {:swap_data, nil}, {:set_options, nil}, {:drop_aside, nil}]},
        {:restore, %{start?: true},
         [
           {:stop, nil},
           {:swap_data, nil},
           {:set_options, nil},
           {:port?, nil},
           {:mint_token, nil},
           {:start, nil},
           {:drop_aside, nil}
         ]},
        {:update, %{config: app_config(%{"version" => "2"})},
         [{:pull, nil}, {:stop, nil}, {:commit, nil}, {:start?, nil}, {:reclaim_image, nil}]},
        {:update, %{config: app_config(%{"version" => "2"}), backup: true},
         [
           {:pull, nil},
           {:stop, nil},
           {:snapshot, nil},
           {:commit, nil},
           {:start?, nil},
           {:reclaim_image, nil}
         ]}
      ]

      for {op, args, steps} <- table,
          do: assert(%{op: ^op, steps: ^steps} = Policy.plan(op, args, running()))
    end

    test "backups: cold stops; hot runs the hooks only while running; native only snapshots" do
      cold = running(%{config: app_config(%{"backup" => "cold"})})

      assert Policy.plan(:backup, %{}, cold).steps ==
               [{:stop, nil}, {:snapshot, nil}, {:start?, nil}]

      hooks = app_config(%{"backup_pre" => "pre", "backup_post" => "post"})

      assert Policy.plan(:backup, %{}, running(%{config: hooks})).steps ==
               [{:exec_hook, :pre}, {:snapshot, nil}, {:exec_hook, :post}]

      assert Policy.plan(:backup, %{}, app(%{config: hooks})).steps == [{:snapshot, nil}]

      native = running(%{config: %{native_config() | backup_pre: "pre"}})
      assert Policy.plan(:backup, %{}, native).steps == [{:snapshot, nil}]
    end

    test "an update needs a new version whose schema takes the saved options" do
      assert Policy.plan(:update, %{config: app_config()}, running()) ==
               {:error, :no_update_available}

      strict = app_config(%{"version" => "2", "schema" => %{"port" => "port"}})
      data = running(%{user_options: %{"port" => 70_000}})
      assert {:error, {:invalid_options, _}} = Policy.plan(:update, %{config: strict}, data)
    end

    test "installing a reserved slug is refused before any step" do
      reserved = %{app_config() | slug: "vagus"}

      assert Policy.plan(:install, %{config: reserved}, Policy.init_data("vagus", nil)) ==
               {:error, {:reserved_slug, "vagus"}}
    end
  end

  describe "next/3, the decision table (sizing-after-review §3)" do
    test "1. start/port: the port is kept and keyed, the token minted before the start task" do
      config = app_config(%{"ingress" => true, "ingress_port" => 0})
      {data, [{:step, {:port, nil}}]} = begin(:start, %{}, app(%{config: config}))

      {data, effects} = step(data, {:ok, 62_123})
      hash = data.token_hash

      assert effects == [
               {:keys, [{:ingress_port, 62_123}], []},
               :persist,
               {:keys, [{:token, hash}], []},
               {:step, {:start, nil}}
             ]

      assert data.ingress_port == 62_123
      assert Policy.hash(data.token) == hash
      assert byte_size(data.token) == 112
    end

    test "1b. start/port refused by the directory: the start fails, nothing kept" do
      config = app_config(%{"ingress" => true, "ingress_port" => 0})
      {data, [{:step, {:port, nil}}]} = begin(:start, %{}, app(%{config: config}))
      taken = {:port_taken, {:ingress_port, 62_123}}

      {data, effects} = step(data, {:error, taken})

      assert effects == [:persist, {:reply, {:error, {:ingress_port, taken}}}, :idle]
      assert %{ingress_port: nil, token_hash: nil} = data
    end

    test "2. start/start ok: container, IP, DNS key, wanted started, persisted before the reply" do
      {data, [{:keys, [{:token, _}], []}, {:step, {:start, nil}}]} =
        begin(:start, %{}, app(%{wanted: :stopped, attempt: 3}))

      {data, effects} = step(data, {:ok, %{container_id: "c1", ip: @ip}})

      assert effects == [
               {:emit, :started},
               {:keys, [{{:dns, "app-one"}, @ip}], [{:dns, "app-one"}]},
               :persist,
               {:reply, :ok},
               :idle
             ]

      assert %{container_id: "c1", ip: @ip, wanted: :started, attempt: 0} = data
    end

    test "3. start/start timed out: token revoked, one cleanup stop by name, then the ladder" do
      {data, _} = begin(:start, %{retry: true}, app(%{attempt: 1}))
      hash = data.token_hash

      {data, effects} = step(data, {:error, :timeout})

      assert effects == [
               {:emit, :error},
               {:keys, [], [{:token, hash}]},
               {:cancel, :probe},
               {:cancel, :settled},
               {:cancel, :retry},
               {:step, {:stop, :by_name}}
             ]

      assert data.token_hash == nil

      {data, effects} = step(data, {:ok, %{was_running: false}})

      assert effects == [
               :persist,
               {:reply, {:error, :timeout}},
               {:timer, :retry, 10_000, {:retry, nil}},
               :idle
             ]

      assert data.attempt == 2
    end

    test "4. stop/stop: keys go before the task, wanted stopped, then persist and reply" do
      {data, effects} = begin(:stop, %{}, running(%{token_hash: "h"}))

      assert effects == [
               {:keys, [], [{:token, "h"}, {:dns, "app-one"}]},
               {:cancel, :probe},
               {:cancel, :settled},
               {:cancel, :retry},
               {:step, {:stop, nil}}
             ]

      assert %{wanted: :stopped, token_hash: nil, ip: nil} = data

      {data, effects} = step(data, {:ok, %{was_running: true}})
      assert effects == [{:emit, :stopped}, :persist, {:reply, :ok}, :idle]
      assert data.container_id == nil
    end

    test "restore: stop, swap the staged data in, save the options, then start with them" do
      args = %{staging_dir: "/s", options: %{"o" => 2}, start?: true}

      {data, effects} =
        begin(:restore, args, running(%{token_hash: "h", user_options: %{"o" => 1}}))

      assert List.last(effects) == {:step, {:stop, nil}}
      assert %{wanted: :stopped, token_hash: nil} = data

      {data, effects} = step(data, {:ok, %{was_running: true}})
      assert List.last(effects) == {:step, {:swap_data, nil}}
      assert %{staging_dir: "/s"} = Policy.task_input({:swap_data, nil}, data)

      {data, effects} = step(data, {:ok, "/data/addons/data/app_one"})
      assert effects == [{:step, {:set_options, nil}}]

      assert %{options: %{"o" => 2}, config: %{slug: "app_one"}} =
               Policy.task_input({:set_options, nil}, data)

      {data, effects} = step(data, {:ok, %{"o" => 2}})
      assert [:persist, {:keys, [{:token, _hash}], []}, {:step, {:start, nil}}] = effects
      assert %{user_options: %{"o" => 2}} = Policy.task_input({:start, nil}, data)

      {data, effects} = step(data, {:ok, %{container_id: "c2", ip: @ip}})
      assert List.last(effects) == {:step, {:drop_aside, nil}}
      assert %{staging_dir: "/s"} = Policy.task_input({:drop_aside, nil}, data)
      assert data.wanted == :started

      {data, effects} = step(data, {:ok, :ok})
      assert effects == [:persist, {:reply, :ok}, :idle]
      assert data.wanted == :started
    end

    # The data is restored by then; the aside is only disk.
    test "restore: an old data dir that is not dropped does not fail the op" do
      for outcome <- [{:ok, :kept}, {:error, :died}, {:error, :timeout}] do
        args = %{staging_dir: "/s", options: nil, start?: false}
        {data, _} = begin(:restore, args, running())
        {data, _} = step(data, {:ok, %{was_running: true}})
        {data, [{:step, {:drop_aside, nil}}]} = step(data, {:ok, "/data/addons/data/app_one"})
        {_data, effects} = step(data, outcome)
        assert effects == [:persist, {:reply, :ok}, :idle], inspect(outcome)
      end
    end

    test "restore without options or a start keeps the options and leaves the app stopped" do
      args = %{staging_dir: "/s", options: nil, start?: false}
      {data, _} = begin(:restore, args, running(%{user_options: %{"o" => 1}}))
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, effects} = step(data, {:ok, "/data/addons/data/app_one"})
      assert effects == [{:step, {:drop_aside, nil}}]
      {data, effects} = step(data, {:ok, :ok})

      assert effects == [:persist, {:reply, :ok}, :idle]
      assert %{wanted: :stopped, user_options: %{"o" => 1}} = data
    end

    test "restore: options the step rejects keep the current ones" do
      args = %{staging_dir: "/s", options: %{"o" => "bad"}, start?: false}
      {data, _} = begin(:restore, args, running(%{user_options: %{"o" => 1}}))
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, [{:step, {:set_options, nil}}]} = step(data, {:ok, "/data/addons/data/app_one"})
      {data, [{:step, {:drop_aside, nil}}]} = step(data, {:ok, nil})
      {data, effects} = step(data, {:ok, :ok})

      assert effects == [:persist, {:reply, :ok}, :idle]
      assert data.user_options == %{"o" => 1}
    end

    test "restore: a failed swap ends it before the options are touched" do
      args = %{staging_dir: "/s", options: %{"o" => 2}, start?: true}
      {data, _} = begin(:restore, args, running(%{user_options: %{"o" => 1}}))
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, effects} = step(data, {:error, :exdev})

      assert effects == [:persist, {:reply, {:error, :exdev}}, :idle]
      assert %{user_options: %{"o" => 1}, wanted: :stopped} = data
    end

    test "5-8. update with a backup: pull, stop, snapshot, commit, start fails, rollback" do
      old = running().config
      target = app_config(%{"version" => "2"})
      {data, [{:step, {:pull, nil}}]} = begin(:update, %{config: target, backup: true}, running())

      {data, [{:keys, [], [{:dns, "app-one"}]} | _] = effects} = step(data, {:ok, "img:2"})
      assert List.last(effects) == {:step, {:stop, nil}}
      assert data.wanted == :started

      # 5. the stop records was_running and goes on to the snapshot
      {data, effects} = step(data, {:ok, %{was_running: true}})
      assert effects == [{:emit, :stopped}, {:step, {:snapshot, nil}}]
      assert data.run.acc.was_running

      # 6. snapshot, commit (local) and the token minted for the new start
      {data, effects} = step(data, {:ok, "/stage/app_one.tar.gz"})
      h2 = data.token_hash
      assert effects == [:persist, {:keys, [{:token, h2}], []}, {:step, {:start, nil}}]
      assert data.config == target
      assert data.run.acc.old == old

      # 7. the new version fails to start: config rolled back, a fresh token
      {data, effects} = step(data, {:error, :crashloop})
      h3 = data.token_hash

      assert effects == [
               :persist,
               {:keys, [{:token, h3}], [{:token, h2}]},
               {:step, {:start, nil}}
             ]

      assert data.config == old
      assert h3 != h2

      # 8. the old version starts: rolled back, the image is not reclaimed
      {data, effects} = step(data, {:ok, %{container_id: "c3", ip: @ip}})

      assert effects == [
               {:emit, :started},
               {:keys, [{{:dns, "app-one"}, @ip}], [{:dns, "app-one"}]},
               :persist,
               {:reply, {:error, {:rolled_back, :crashloop}}},
               :idle
             ]

      assert data.container_id == "c3"
    end

    test "update success reclaims the old image and reports the versions" do
      target = app_config(%{"version" => "2"})
      {data, _} = begin(:update, %{config: target}, running())
      {data, _} = step(data, {:ok, "img"})
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, _} = step(data, {:ok, %{container_id: "c2", ip: @ip}})
      assert data.run.step == {:reclaim_image, nil}

      {_data, effects} = step(data, {:ok, :ok})

      assert Enum.take(effects, -3) ==
               [:persist, {:reply, {:ok, %{slug: "app_one", from: "1.0.0", to: "2"}}}, :idle]
    end

    test "update of a stopped app commits and does not start it" do
      target = app_config(%{"version" => "2"})
      data = app(%{wanted: :stopped})
      {data, _} = begin(:update, %{config: target}, data)
      {data, _} = step(data, {:ok, "img"})
      {data, effects} = step(data, {:ok, %{was_running: false}})
      assert effects == [:persist, {:step, {:reclaim_image, nil}}]
      assert data.config == target
    end

    test "an update's commit moves the ingress keys with the config" do
      dynamic = %{"ingress" => true, "ingress_port" => 0}
      itok = {:ingress_token, Policy.hash("itok")}

      commit = fn from, to ->
        data =
          app(%{
            config: app_config(from),
            wanted: :stopped,
            ingress_token: "itok",
            ingress_port: 62_000
          })

        {data, _} = begin(:update, %{config: app_config(Map.put(to, "version", "2"))}, data)
        {data, _} = step(data, {:ok, "img"})
        step(data, {:ok, %{was_running: false}})
      end

      {data, effects} = commit.(dynamic, %{"ingress" => false, "ingress_port" => 0})
      assert [{:keys, [], [^itok]}, :persist | _] = effects
      assert data.ingress_port == 62_000

      {_data, effects} = commit.(%{"ingress" => false, "ingress_port" => 0}, dynamic)
      assert [{:keys, [^itok], []}, :persist | _] = effects

      {data, effects} = commit.(dynamic, %{"ingress" => true, "ingress_port" => 8123})
      assert [{:keys, [], [{:ingress_port, 62_000}]}, :persist | _] = effects
      assert data.ingress_port == nil
      assert {:ok, {_ip, 8123, false}} = Policy.answer(:ingress_target, %{data | ip: @ip})
    end

    test "a rollback restores the ingress token key; a dropped dynamic port is picked afresh" do
      data =
        running(%{
          config: app_config(%{"ingress" => true, "ingress_port" => 0}),
          ingress_token: "itok",
          ingress_port: 62_000
        })

      target = app_config(%{"version" => "2", "ingress" => false, "ingress_port" => 8123})
      dropped = [{:ingress_token, Policy.hash("itok")}, {:ingress_port, 62_000}]
      {data, _} = begin(:update, %{config: target}, data)
      {data, _} = step(data, {:ok, "img"})
      {data, effects} = step(data, {:ok, %{was_running: true}})
      assert {:keys, [], ^dropped} = Enum.find(effects, &match?({:keys, [], [_ | _]}, &1))
      assert data.ingress_port == nil

      {data, effects} = step(data, {:error, :crashloop})
      itok = hd(dropped)
      assert {:keys, [^itok], []} = Enum.find(effects, &match?({:keys, [_ | _], []}, &1))
      assert data.ingress_port == nil
      assert List.last(effects) == {:step, {:port, nil}}
    end

    test "update: a failed pull changes nothing" do
      data = running()
      {data, _} = begin(:update, %{config: app_config(%{"version" => "2"})}, data)
      {after_pull, effects} = step(data, {:error, :no_network})
      assert effects == [:persist, {:reply, {:error, {:pull, :no_network}}}, :idle]
      assert after_pull.container_id == "c1"
    end

    test "update: a failed rollback says so" do
      {data, _} = begin(:update, %{config: app_config(%{"version" => "2"})}, running())
      {data, _} = step(data, {:ok, "img"})
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, _} = step(data, {:error, :new_broken})
      {data, effects} = step(data, {:error, :old_broken})
      assert {:reply, {:error, {:rollback_failed, :old_broken}}} in effects
      assert data.last_event == {:failed, :old_broken}
    end

    test "update: a failed snapshot restarts the old version and fails the update" do
      {data, _} =
        begin(:update, %{config: app_config(%{"version" => "2"}), backup: true}, running())

      {data, _} = step(data, {:ok, "img"})
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, effects} = step(data, {:error, :enospc})
      assert List.last(effects) == {:step, {:start, nil}}
      assert data.config.version == "1.0.0"

      {_data, effects} = step(data, {:ok, %{container_id: "c2", ip: @ip}})

      assert Enum.take(effects, -3) ==
               [:persist, {:reply, {:error, {:backup_failed, :enospc}}}, :idle]
    end

    # A failed tar's own unpause may have failed too, so a paused one is thawed.
    test "9. backup hot: a failed snapshot thaws, then runs the post hook, and the error is the result" do
      hooks = app_config(%{"backup_pre" => "pre", "backup_post" => "post"})
      {data, [{:step, {:exec_hook, :pre}}]} = begin(:backup, %{}, running(%{config: hooks}))
      {data, [{:step, {:snapshot, nil}}]} = step(data, {:ok, :ok})
      {data, effects} = step(data, {:error, :enospc})
      assert effects == [{:step, {:unpause, nil}}]
      assert data.run.acc.result == {:error, :enospc}
      {data, effects} = step(data, {:ok, :ok})
      assert effects == [{:step, {:exec_hook, :post}}]

      {_data, effects} = step(data, {:error, {:exec, 1}})
      assert effects == [:persist, {:reply, {:error, :enospc}}, :idle]
    end

    test "backup hot: a snapshot killed at its deadline thaws the container, then runs the post hook" do
      hooks = app_config(%{"backup_post" => "post"})
      {data, [{:step, {:snapshot, nil}}]} = begin(:backup, %{}, running(%{config: hooks}))
      {data, [{:step, {:unpause, nil}}]} = step(data, {:error, :timeout})
      {data, [{:step, {:exec_hook, :post}}]} = step(data, {:ok, :not_paused})
      {_data, effects} = step(data, {:ok, :ok})
      assert effects == [:persist, {:reply, {:error, :timeout}}, :idle]

      {data, _} = begin(:backup, %{}, app(%{config: hooks, wanted: :stopped}))
      {_data, effects} = step(data, {:error, :timeout})
      assert effects == [:persist, {:reply, {:error, :timeout}}, :idle]
    end

    test "backup hot: a snapshot whose own unpause failed is thawed again, then the post hook" do
      hooks = app_config(%{"backup_post" => "post"})
      {data, [{:step, {:snapshot, nil}}]} = begin(:backup, %{}, running(%{config: hooks}))
      {data, [{:step, {:unpause, nil}}]} = step(data, {:ok, {:still_paused, "/s/a.tar.gz"}})
      {data, [{:step, {:exec_hook, :post}}]} = step(data, {:ok, :ok})
      {_data, effects} = step(data, {:ok, :ok})
      assert effects == [:persist, {:reply, {:ok, "/s/a.tar.gz"}}, :idle]
    end

    # Frozen, the app is neither healthy nor able to answer its post hook.
    test "backup hot: a recovery unpause that fails is cleaned up by name and restarted, no post hook" do
      hooks = app_config(%{"backup_post" => "post"})

      for {snapshot, reply} <- [
            {{:ok, {:still_paused, "/s/a.tar.gz"}}, {:error, {:unpause, :engine_gone}}},
            {{:error, :enospc}, {:error, :enospc}}
          ] do
        {data, _} = begin(:backup, %{}, running(%{config: hooks, token_hash: "h"}))
        {data, [{:step, {:unpause, nil}}]} = step(data, snapshot)
        {data, effects} = step(data, {:error, :engine_gone})

        assert List.last(effects) == {:step, {:stop, :by_name}}
        assert {:keys, [], [{:token, "h"}, {:dns, "app-one"}]} in effects
        refute {:step, {:exec_hook, :post}} in effects
        assert data.last_event == {:failed, {:unpause, :engine_gone}}

        {data, effects} = step(data, {:ok, %{was_running: true}})

        assert effects == [
                 :persist,
                 {:reply, reply},
                 {:timer, :retry, 0, {:retry, nil}},
                 :idle
               ]

        assert %{container_id: nil, wanted: :started} = data
      end
    end

    test "backup hot: a failed pre hook ends it before the snapshot" do
      hooks = app_config(%{"backup_pre" => "pre", "backup_post" => "post"})
      {data, _} = begin(:backup, %{}, running(%{config: hooks}))
      {_data, effects} = step(data, {:error, {:exec, 2}})
      assert effects == [:persist, {:reply, {:error, {:backup_pre_failed, {:exec, 2}}}}, :idle]
    end

    test "backup cold: a snapshot error still starts a running app again" do
      cold = running(%{config: app_config(%{"backup" => "cold"})})
      {data, _} = begin(:backup, %{staging_dir: "/s"}, cold)
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, effects} = step(data, {:error, :enospc})
      assert List.last(effects) == {:step, {:start, nil}}

      {data, effects} = step(data, {:ok, %{container_id: "c2", ip: @ip}})
      assert Enum.take(effects, -3) == [:persist, {:reply, {:error, :enospc}}, :idle]
      assert data.wanted == :started
    end

    test "backup cold of a crashed app that should run starts it, so its cancelled restart is not lost" do
      cold = app(%{config: app_config(%{"backup" => "cold"}), last_event: {:exited, 1}})
      {data, effects} = begin(:backup, %{staging_dir: "/s"}, cold)
      assert {:cancel, :retry} in effects
      {data, _} = step(data, {:ok, %{was_running: false}})
      assert Policy.task_input({:snapshot, nil}, data).state == "started"

      {data, effects} = step(data, {:ok, "/s/app_one.tar.gz"})
      assert List.last(effects) == {:step, {:start, nil}}
      {_data, effects} = step(data, {:ok, %{container_id: "c2", ip: @ip}})
      assert Enum.take(effects, -3) == [:persist, {:reply, {:ok, "/s/app_one.tar.gz"}}, :idle]
    end

    test "backup cold of a stopped app does not start it" do
      cold = app(%{config: app_config(%{"backup" => "cold"}), wanted: :stopped})
      {data, _} = begin(:backup, %{staging_dir: "/s"}, cold)
      {data, _} = step(data, {:ok, %{was_running: false}})
      {_data, effects} = step(data, {:ok, "/s/app_one.tar.gz"})
      assert effects == [:persist, {:reply, {:ok, "/s/app_one.tar.gz"}}, :idle]
    end

    test "10. uninstall: every key dropped first, the file deleted before the removal, reply then exit" do
      ingress = app_config(%{"ingress" => true, "ingress_port" => 0})

      data =
        running(%{
          config: ingress,
          token_hash: "h",
          ingress_token: "it",
          ingress_port: 62_001,
          services: %{"mqtt" => %{}},
          discovery: %{"u1" => %{uuid: "u1"}}
        })

      {data, [{:keys, [], drop} | _] = effects} = begin(:uninstall, %{}, data)

      assert drop == [
               {:token, "h"},
               {:dns, "app-one"},
               {:ingress_token, Policy.hash("it")},
               {:ingress_port, 62_001},
               {:service, "mqtt"},
               {:discovery, "u1"}
             ]

      assert List.last(effects) == {:step, {:stop, nil}}
      assert data.discovery == %{}

      {data, [{:emit, :stopped}, :delete_file]} = step(data, {:ok, %{was_running: true}})
      refute data.gone
      {data, [{:step, {:remove_app, nil}}]} = step(data, {:ok, nil})
      assert data.gone

      {_data, effects} = step(data, {:ok, :ok})
      assert effects == [{:reply, :ok}, :exit]
    end

    test "uninstall: a file that cannot be deleted fails it before the removal, still installed" do
      data = running(%{config: app_config(%{"ingress" => true}), ingress_token: "it"})
      {data, _} = begin(:uninstall, %{}, data)
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, effects} = step(data, {:error, {:delete_file, :eacces}})

      refute data.gone
      assert {:keys, [{:ingress_token, Policy.hash("it")}], []} in effects
      assert {:reply, {:error, {:delete_file, :eacces}}} in effects
      assert List.last(effects) == :idle
      refute Enum.any?(effects, &match?({:step, _}, &1))
    end

    test "uninstall: a refused removal after the file is gone ends the process, unsaved" do
      {data, _} = begin(:uninstall, %{}, running())
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, _} = step(data, {:ok, nil})
      {_data, effects} = step(data, {:error, {:invalid_slug, "x"}})
      assert effects == [{:reply, {:error, {:invalid_slug, "x"}}}, :exit]
    end

    test "uninstall: a halt once the file is gone ends the process rather than waiting to resume" do
      {data, _} = begin(:uninstall, %{}, running())
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, _} = step(data, {:ok, nil})
      {data, effects} = begin(:halt, %{}, data)
      assert List.last(effects) == {:step, {:halt_stop, nil}}
      {_data, effects} = step(data, {:ok, :stopped})
      assert effects == [{:reply, :ok}, :exit]
    end

    test "update: a failed snapshot whose restart of the old version fails, fails without a rollback" do
      {data, _} =
        begin(:update, %{config: app_config(%{"version" => "2"}), backup: true}, running())

      {data, _} = step(data, {:ok, "img"})
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, _} = step(data, {:error, :enospc})
      {data, effects} = step(data, {:error, :old_broken})

      assert Enum.take(effects, -3) == [:persist, {:reply, {:error, :old_broken}}, :idle]
      assert data.config.version == "1.0.0"
    end

    test "install: pull, port, commit; nothing persisted until the commit" do
      config = app_config(%{"ingress" => true, "ingress_port" => 0})
      data = Policy.init_data("app_one", nil)
      {data, [{:step, {:pull, nil}}]} = begin(:install, %{config: config}, data)
      assert Policy.task_input({:pull, nil}, data).config == config

      {data, [{:step, {:port, nil}}]} = step(data, {:ok, "img"})
      {data, effects} = step(data, {:ok, 62_002})

      assert effects == [
               {:keys, [{:ingress_port, 62_002}], []},
               {:keys, [{:ingress_token, Policy.hash(data.ingress_token)}], []},
               :persist,
               {:reply, :ok},
               :idle
             ]

      assert %{config: ^config, wanted: :stopped, ingress_port: 62_002} = data
    end

    test "install: a failed pull replies and ends the process" do
      data = Policy.init_data("app_one", nil)
      {data, _} = begin(:install, %{config: app_config()}, data)

      assert step(data, {:error, :not_found}) |> elem(1) == [
               {:reply, {:error, :not_found}},
               :exit
             ]
    end

    test "restart keeps wanted; native mints no token and monitors its broker" do
      {data, effects} = begin(:restart, %{}, running(%{wanted: :stopped}))
      assert List.last(effects) == {:step, {:stop, nil}}
      {data, _} = step(data, {:ok, %{was_running: true}})
      {data, _} = step(data, {:ok, %{container_id: "c2", ip: @ip}})
      assert data.wanted == :stopped

      native = app(%{config: native_config(), slug: "core_mqtt"})
      {data, [{:step, {:start, nil}}]} = begin(:start, %{}, native)
      pid = self()

      {data, effects} =
        step(data, {:ok, %{container_id: "addon_core_mqtt", ip: "172.30.32.2", pid: pid}})

      assert :monitor_broker in effects
      assert data.broker_pid == pid
      assert data.token_hash == nil
    end

    test "a start with the URL watchdog on arms the probe; a retry arms the settle timer" do
      config = app_config(%{"watchdog" => "http://[HOST]:[PORT:80]/"})
      {data, _} = begin(:start, %{retry: true}, app(%{config: config, attempt: 2}))
      {data, effects} = step(data, {:ok, %{container_id: "c2", ip: @ip, healthcheck: true}})
      assert {:timer, :probe, 120_000, :probe} in effects
      assert {:timer, :settled, 120_000, :settled} in effects
      assert hd(effects) == {:emit, :startup}
      assert data.attempt == 2
    end

    test "a user start that fails does not join the ladder" do
      {data, _} = begin(:start, %{}, app())
      {data, effects} = step(data, {:error, {:invalid_options, "x"}})
      refute Enum.any?(effects, &match?({:timer, :retry, _, _}, &1))
      assert {:reply, {:error, {:invalid_options, "x"}}} in effects
      assert data.last_event == {:failed, {:invalid_options, "x"}}
    end

    test "a stop step that died is cleaned up and the stop fails" do
      {data, _} = begin(:stop, %{}, running())
      {data, effects} = step(data, {:error, :died})
      assert List.last(effects) == {:step, {:stop, :by_name}}
      {_data, effects} = step(data, {:ok, %{was_running: false}})
      assert effects == [:persist, {:reply, {:error, {:stop, :died}}}, :idle]
    end

    test "halt: stop by name, reply its result, shutting down, nothing persisted" do
      {data, effects} = begin(:halt, %{}, running(%{token_hash: "h"}))
      assert List.last(effects) == {:step, {:halt_stop, nil}}
      {after_ok, effects} = step(data, {:ok, :stopped})
      assert effects == [{:emit, :stopped}, {:reply, :ok}, :shutting_down]
      assert after_ok.wanted == :started

      {_data, effects} = step(data, {:error, :timeout})
      assert effects == [{:emit, :stopped}, {:reply, {:error, :timeout}}, :shutting_down]
    end

    test "an outcome no clause plans for fails the op instead of raising" do
      {data, _} = begin(:stop, %{}, running())
      {_data, effects} = step(data, {:ok, :garbage})

      assert effects == [
               :persist,
               {:reply, {:error, {:unplanned, :stop, {:stop, nil}, {:ok, :garbage}}}},
               :idle
             ]
    end
  end

  describe "task_input/2 and deadline/1" do
    test "a start step reads the options current at its spawn" do
      {data, _} = begin(:start, %{}, app(%{user_options: %{"a" => 1}}))
      data = %{data | user_options: %{"a" => 2}}
      input = Policy.task_input({:start, nil}, data)
      assert input.user_options == %{"a" => 2}
      assert input.token == data.token
      assert input.protected == true
    end

    test "an update's steps report job stages" do
      args = %{config: app_config(%{"version" => "2"}), job: "j1"}
      {data, _} = begin(:update, args, running())
      assert %{job: "j1", stage: {"pull_image", 20}} = Policy.task_input({:pull, nil}, data)
      assert Policy.task_input({:pull, nil}, data).config.version == "2"
    end

    test "a hot snapshot of a running container pauses it; cold, stopped and native do not" do
      opts = %{"o" => 1}
      hot = running(%{user_options: opts})
      {data, [{:step, {:snapshot, nil}}]} = begin(:backup, %{staging_dir: "/s"}, hot)

      assert %{staging_dir: "/s", user_options: ^opts, state: "started", pause: true} =
               Policy.task_input({:snapshot, nil}, data)

      cold = running(%{config: app_config(%{"backup" => "cold"})})
      {data, _} = begin(:backup, %{staging_dir: "/s"}, cold)
      {data, effects} = step(data, {:ok, %{was_running: true}})
      assert List.last(effects) == {:step, {:snapshot, nil}}
      assert %{state: "started", pause: false} = Policy.task_input({:snapshot, nil}, data)

      {data, _} = begin(:backup, %{staging_dir: "/s"}, app(%{wanted: :stopped}))
      assert %{state: "stopped", pause: false} = Policy.task_input({:snapshot, nil}, data)

      {data, _} = begin(:backup, %{staging_dir: "/s"}, running(%{config: native_config()}))
      assert %{state: "started", pause: false} = Policy.task_input({:snapshot, nil}, data)
    end

    test "a container whose last-seen state lags the engine is still paused around the tar" do
      lagging = app(%{container_id: "c1", last_event: :stopped})
      {data, [{:step, {:snapshot, nil}}]} = begin(:backup, %{staging_dir: "/s"}, lagging)
      assert %{pause: true} = Policy.task_input({:snapshot, nil}, data)
    end

    test "a hot backup of a crashed app that should run records it started, as a cold one does" do
      crashed = app(%{last_event: {:exited, 1}})
      {data, [{:step, {:snapshot, nil}}]} = begin(:backup, %{staging_dir: "/s"}, crashed)
      assert %{state: "started", pause: true} = Policy.task_input({:snapshot, nil}, data)
    end

    # A restarted process holds no container id until its adoption inspect
    # answers, while the old container may still be running and writing.
    test "an app wanted started but not yet adopted is paused by name, and thawed after a failure" do
      unadopted = app(%{container_id: nil, wanted: :started, last_event: nil})
      {data, [{:step, {:snapshot, nil}}]} = begin(:backup, %{staging_dir: "/s"}, unadopted)
      assert %{pause: true} = Policy.task_input({:snapshot, nil}, data)

      {data, effects} = step(data, {:error, {:pause, :engine_gone}})
      assert effects == [{:step, {:unpause, nil}}]
      {_data, effects} = step(data, {:ok, :not_paused})
      assert effects == [:persist, {:reply, {:error, {:pause, :engine_gone}}}, :idle]
    end

    test "an update's snapshot takes the staging dir and the state before the stop" do
      args = %{config: app_config(%{"version" => "2"}), backup: true, staging_dir: "/s"}
      {data, _} = begin(:update, args, running())
      {data, _} = step(data, {:ok, "img"})
      {data, effects} = step(data, {:ok, %{was_running: true}})
      assert List.last(effects) == {:step, {:snapshot, nil}}

      assert %{staging_dir: "/s", state: "started", pause: false} =
               Policy.task_input({:snapshot, nil}, data)
    end

    test "every task step has a deadline" do
      for name <- [
            :pull,
            :port,
            :start,
            :stop,
            :halt_stop,
            :snapshot,
            :exec_hook,
            :unpause,
            :swap_data,
            :set_options,
            :drop_aside,
            :remove_app,
            :reclaim_image
          ],
          do: assert(Policy.deadline(name) > 0)
    end

    # Removing a large old data dir is a walk as long as a snapshot's.
    test "dropping the aside has a snapshot's deadline, not the swap's" do
      assert Policy.deadline(:drop_aside) == Policy.deadline(:snapshot)
      assert Policy.deadline(:drop_aside) > Policy.deadline(:swap_data)
    end
  end
end
