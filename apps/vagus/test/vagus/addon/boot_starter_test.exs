defmodule Vagus.Addon.BootStarterTest do
  @moduledoc """
  M4-P8-T1 boot-time reconciliation. `Vagus.Addon.Manager.start_slug/2` has
  no server-ref option of its own and always resolves via the real,
  globally-named `Vagus.Addon.State` (already running for the whole test
  suite, same as `manager_test.exs`'s lifecycle describe block) — so these
  tests seed/observe that real singleton directly rather than a private
  instance, and swap in `Vagus.Addon.Backend.Fake` via `config :vagus,
  :addon_backend` for the whole test (`async: false`), same pattern as
  `addon_lifecycle_router_test.exs`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Addon.{Backend.Fake, BootStarter, Config, State}

  setup do
    prev_backend = Application.get_env(:vagus, :addon_backend)
    Application.put_env(:vagus, :addon_backend, Fake)

    data_root =
      Path.join(System.tmp_dir!(), "vagus-bootstarter-#{System.unique_integer([:positive])}")

    prev_root = Application.get_env(:vagus, :addon_data_root)
    Application.put_env(:vagus, :addon_data_root, data_root)

    prev_boot_start = Application.get_env(:vagus, :addon_boot_start)
    Application.put_env(:vagus, :addon_boot_start, true)

    Fake.reset_calls()

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:vagus, :addon_backend, prev_backend),
        else: Application.delete_env(:vagus, :addon_backend)

      if prev_root,
        do: Application.put_env(:vagus, :addon_data_root, prev_root),
        else: Application.delete_env(:vagus, :addon_data_root)

      if prev_boot_start,
        do: Application.put_env(:vagus, :addon_boot_start, prev_boot_start),
        else: Application.delete_env(:vagus, :addon_boot_start)

      File.rm_rf(data_root)
    end)

    :ok
  end

  defp fixture_config(slug, extra \\ %{}) do
    {:ok, c} =
      Config.parse(
        Map.merge(
          %{
            "name" => "Test",
            "version" => "1",
            "slug" => slug,
            "description" => "d",
            "arch" => ["amd64"],
            "image" => "homeassistant/{arch}-addon-test",
            "host_network" => true
          },
          extra
        )
      )

    c
  end

  defp seed(slug, lifecycle_state, config) do
    :ok = State.put(config, lifecycle_state)
    on_exit(fn -> State.delete(slug) end)
    config
  end

  defp forward_forever(parent) do
    receive do: (message -> send(parent, {:listener_got, message}))
    forward_forever(parent)
  end

  # Retries `fun` (a 0-arity predicate) until it returns truthy or `attempts`
  # is exhausted — the polling GenServer under test does its work on its own
  # process/timer, so assertions can't just run once right after start.
  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(5)
        {:cont, false}
      end
    end)
  end

  test "disabled config (addon_boot_start false) -> :ignore, no process registered" do
    Application.put_env(:vagus, :addon_boot_start, false)
    assert :ignore = BootStarter.start_link([])
    assert Process.whereis(BootStarter) == nil
  end

  test "ping fails a few times then succeeds -> a started boot:auto entry is start_slug'd" do
    slug = "boot_success_#{System.unique_integer([:positive])}"
    seed(slug, :started, fixture_config(slug, %{"boot" => "auto"}))

    counter = :counters.new(1, [])

    ping = fn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if n < 3, do: {:error, :not_ready}, else: :ok
    end

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: ping,
       ensure_network: fn -> :ok end,
       interval: 1,
       max_attempts: 20,
       name: nil}
    )

    assert eventually(fn -> match?({:ok, %{state: :started}}, State.get(slug)) end)
    # This add-on WAS created + started (scoped to its id, so no cross-test bleed).
    assert eventually(fn -> {:create, "addon_#{slug}"} in Fake.calls() end)
    assert Enum.any?(Fake.calls_for("addon_#{slug}"), &match?({:start, _id}, &1))
  end

  test "on engine-ready it ensures the bridge/anchors BEFORE reconciling add-ons" do
    parent = self()
    slug = "boot_ensure_net_#{System.unique_integer([:positive])}"
    # boot: manual + :started → reconcile demotes it to :stopped (no backend
    # call), a clean observable side effect to order against.
    seed(slug, :started, fixture_config(slug, %{"boot" => "manual"}))

    # Capture the entry's lifecycle state at the instant ensure_network runs. If
    # it fires before reconcile, the entry is still :started (reconcile hasn't
    # demoted it yet) — that's the ordering proof.
    ensure_network = fn -> send(parent, {:state_at_ensure, State.get(slug)}) end

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> :ok end,
       ensure_network: ensure_network,
       interval: 1,
       max_attempts: 5,
       name: nil}
    )

    # The anchor bind must run once the engine is ready, independent of any
    # add-on — a native-only device has no container add-on to bind .2/.3 — and
    # BEFORE reconcile (so Core can reach the Supervisor as add-ons come up).
    assert_receive {:state_at_ensure, {:ok, %{state: :started}}}, 500
    # ...and reconcile then ran (demoted the manual entry), confirming the order.
    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug)) end)
  end

  # These assert the ABSENCE of backend calls for THIS test's add-on. They read
  # the shared `Backend.Fake` recorder scoped to the add-on's id (`Fake.calls_for/1`),
  # so a foreign/lingering writer for a *different* slug can't pollute them — the
  # per-test isolation that lifted the former `@tag :flaky` quarantine.
  test "a start failure demotes the entry to :stopped" do
    slug = "boot_fail_#{System.unique_integer([:positive])}"

    # An invalid baked-in default option (port out of 1..65_535) fails
    # OptionsSchema validation inside Manager.start/2's write_options step,
    # regardless of any stored user_options — deterministic start failure.
    config =
      fixture_config(slug, %{
        "boot" => "auto",
        "schema" => %{"port" => "port"},
        "options" => %{"port" => 70_000}
      })

    seed(slug, :started, config)

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> :ok end,
       ensure_network: fn -> :ok end,
       interval: 1,
       max_attempts: 5,
       name: nil}
    )

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug)) end)
    # Validation failed before create — no backend call for this add-on at all.
    assert Fake.calls_for("addon_#{slug}") == []
  end

  test "boot: manual + :started is demoted to :stopped without any backend calls" do
    slug = "boot_manual_#{System.unique_integer([:positive])}"
    seed(slug, :started, fixture_config(slug, %{"boot" => "manual"}))

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> :ok end,
       ensure_network: fn -> :ok end,
       interval: 1,
       max_attempts: 5,
       name: nil}
    )

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug)) end)
    assert Fake.calls_for("addon_#{slug}") == []
  end

  # Phase 6 chunk A (audit E1): the persisted per-install `boot` override —
  # not just `config.boot` — decides whether reconciliation restarts an
  # add-on. Before `Config.effective_boot/2` was wired in here,
  # reconciliation read `config.boot` directly and a user's explicit
  # `manual` override on an `auto`-configured add-on was silently ignored
  # on every reboot.
  test "a persisted :boot override (manual) skips a config-boot:auto add-on, and an unoverridden auto add-on still starts" do
    manual_slug = "boot_override_manual_#{System.unique_integer([:positive])}"
    auto_slug = "boot_override_auto_#{System.unique_integer([:positive])}"

    seed(manual_slug, :started, fixture_config(manual_slug, %{"boot" => "auto"}))
    :ok = State.put_setting(manual_slug, :boot, "manual")

    seed(auto_slug, :started, fixture_config(auto_slug, %{"boot" => "auto"}))

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> :ok end,
       ensure_network: fn -> :ok end,
       interval: 1,
       max_attempts: 5,
       name: nil}
    )

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(manual_slug)) end)
    assert Fake.calls_for("addon_#{manual_slug}") == []

    assert eventually(fn -> match?({:ok, %{state: :started}}, State.get(auto_slug)) end)
    assert eventually(fn -> {:create, "addon_#{auto_slug}"} in Fake.calls() end)
  end

  test "a persisted :boot override (auto) starts a config-boot:manual add-on" do
    slug = "boot_override_forces_auto_#{System.unique_integer([:positive])}"
    seed(slug, :started, fixture_config(slug, %{"boot" => "manual"}))
    :ok = State.put_setting(slug, :boot, "auto")

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> :ok end,
       ensure_network: fn -> :ok end,
       interval: 1,
       max_attempts: 5,
       name: nil}
    )

    assert eventually(fn -> match?({:ok, %{state: :started}}, State.get(slug)) end)
    assert eventually(fn -> {:create, "addon_#{slug}"} in Fake.calls() end)
  end

  test "a manual_only config always demotes, even with a persisted :boot override of auto" do
    slug = "boot_manual_only_#{System.unique_integer([:positive])}"
    seed(slug, :started, fixture_config(slug, %{"boot" => "manual_only"}))
    :ok = State.put_setting(slug, :boot, "auto")

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> :ok end,
       ensure_network: fn -> :ok end,
       interval: 1,
       max_attempts: 5,
       name: nil}
    )

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug)) end)
    assert Fake.calls_for("addon_#{slug}") == []
  end

  test "a :stopped entry is left alone" do
    slug = "boot_stopped_#{System.unique_integer([:positive])}"
    seed(slug, :stopped, fixture_config(slug, %{"boot" => "auto"}))

    pid =
      start_supervised!(
        {BootStarter,
         api_ready: fn -> true end,
         ping: fn -> :ok end,
         ensure_network: fn -> :ok end,
         interval: 1,
         max_attempts: 5,
         name: nil}
      )

    # Give the reconcile pass a moment to (not) act, then confirm nothing
    # touched this slug or the backend.
    assert eventually(fn -> Process.alive?(pid) end)
    Process.sleep(20)
    assert {:ok, %{state: :stopped}} = State.get(slug)
    assert Fake.calls_for("addon_#{slug}") == []
  end

  test "engine never ready (all pings fail) -> gives up without touching State" do
    slug = "boot_never_ready_#{System.unique_integer([:positive])}"
    seed(slug, :started, fixture_config(slug, %{"boot" => "auto"}))

    start_supervised!(
      {BootStarter,
       api_ready: fn -> true end,
       ping: fn -> {:error, :nope} end,
       interval: 1,
       max_attempts: 3,
       name: nil}
    )

    # 3 attempts * 1ms interval should exhaust well within this budget.
    Process.sleep(100)

    assert {:ok, %{state: :started}} = State.get(slug)
    assert Fake.calls_for("addon_#{slug}") == []
  end

  # The HA base image's s6 init calls /addons/self/info before the add-on's
  # own service; a refused connection kills the container for the rest of the
  # boot, so reconciliation waits for the API as well as the engine.
  describe "the API gate" do
    test "no add-on is started while the API is not accepting, and one is once it flips" do
      slug = "boot_api_gate_#{System.unique_integer([:positive])}"
      seed(slug, :started, fixture_config(slug, %{"boot" => "auto"}))

      {:ok, accepting} = Agent.start_link(fn -> false end)

      start_supervised!(
        {BootStarter,
         ping: fn -> :ok end,
         api_ready: fn -> Agent.get(accepting, & &1) end,
         ensure_network: fn -> :ok end,
         interval: 1,
         max_attempts: 500,
         name: nil}
      )

      # No backend call at all: the reconcile pass that would create/start
      # this add-on has not run while the probe says the API is closed.
      Process.sleep(30)
      assert Fake.calls_for("addon_#{slug}") == []

      Agent.update(accepting, fn _ -> true end)

      assert eventually(fn -> {:create, "addon_#{slug}"} in Fake.calls() end)
      assert eventually(fn -> match?({:ok, %{state: :started}}, State.get(slug)) end)
    end

    test "the anchors are bound while the API wait is still running" do
      parent = self()
      slug = "boot_api_anchor_#{System.unique_integer([:positive])}"
      seed(slug, :started, fixture_config(slug, %{"boot" => "manual"}))

      # Deferring ensure_network behind the API wait would deadlock: the
      # listener binds 172.30.32.2, which only exists once this has run.
      start_supervised!(
        {BootStarter,
         ping: fn -> :ok end,
         api_ready: fn -> false end,
         ensure_network: fn -> send(parent, :ensured) end,
         interval: 1,
         max_attempts: 500,
         name: nil}
      )

      assert_receive :ensured, 500
      # ...and the manual entry is still :started, i.e. reconcile did not run.
      assert {:ok, %{state: :started}} = State.get(slug)
    end

    test "an API that never accepts gives up with its own warning, distinct from the engine's" do
      slug = "boot_api_never_#{System.unique_integer([:positive])}"
      seed(slug, :started, fixture_config(slug, %{"boot" => "auto"}))

      log =
        capture_log(fn ->
          start_supervised!(
            {BootStarter,
             ping: fn -> :ok end,
             api_ready: fn -> false end,
             ensure_network: fn -> :ok end,
             interval: 1,
             max_attempts: 3,
             name: nil}
          )

          Process.sleep(100)
        end)

      assert log =~ "Supervisor API not accepting connections after 3 attempts"
      refute log =~ "engine not ready"
      assert {:ok, %{state: :started}} = State.get(slug)
      assert Fake.calls_for("addon_#{slug}") == []
    end

    test "the listener is nudged the moment the anchor is bound" do
      parent = self()

      # Nothing runs under the listener's name in `mix test`, so standing in
      # for it here is what proves the nudge is actually sent — and sent with
      # the anchor already up, since ensure_network ran first.
      assert Process.whereis(Vagus.API.Listener) == nil

      fake = spawn_link(fn -> forward_forever(parent) end)
      Process.register(fake, Vagus.API.Listener)

      start_supervised!(
        {BootStarter,
         ping: fn -> :ok end,
         api_ready: fn -> false end,
         ensure_network: fn -> send(parent, :ensured) end,
         interval: 1,
         max_attempts: 500,
         name: nil}
      )

      assert_receive :ensured, 500
      assert_receive {:listener_got, :retry_listen}, 500

      # Released here rather than in on_exit: the name is global, and the
      # sibling test asserting nothing holds it may run next.
      Process.unregister(Vagus.API.Listener)
    end

    test "reconciliation still happens with nothing listening for the nudge" do
      slug = "boot_api_no_listener_#{System.unique_integer([:positive])}"
      seed(slug, :started, fixture_config(slug, %{"boot" => "auto"}))

      # The nudge is an optimisation: with no listener registered it goes
      # nowhere, and the poll gate alone still has to get add-ons started.
      assert Process.whereis(Vagus.API.Listener) == nil

      polls = :counters.new(1, [])

      api_ready = fn ->
        n = :counters.get(polls, 1)
        :counters.add(polls, 1, 1)
        n >= 3
      end

      start_supervised!(
        {BootStarter,
         ping: fn -> :ok end,
         api_ready: api_ready,
         ensure_network: fn -> :ok end,
         interval: 1,
         max_attempts: 500,
         name: nil}
      )

      assert eventually(fn -> {:create, "addon_#{slug}"} in Fake.calls() end)
    end

    test "a slow engine does not spend the API's attempts" do
      slug = "boot_api_budget_#{System.unique_integer([:positive])}"
      seed(slug, :started, fixture_config(slug, %{"boot" => "auto"}))

      pings = :counters.new(1, [])
      api = :counters.new(1, [])

      ping = fn ->
        n = :counters.get(pings, 1)
        :counters.add(pings, 1, 1)
        if n < 4, do: {:error, :not_ready}, else: :ok
      end

      api_ready = fn ->
        n = :counters.get(api, 1)
        :counters.add(api, 1, 1)
        n >= 4
      end

      # max_attempts: 5 is exhausted by neither wait alone but would be by
      # the two sharing one counter.
      start_supervised!(
        {BootStarter,
         ping: ping,
         api_ready: api_ready,
         ensure_network: fn -> :ok end,
         interval: 1,
         max_attempts: 5,
         name: nil}
      )

      assert eventually(fn -> {:create, "addon_#{slug}"} in Fake.calls() end)
    end
  end
end
