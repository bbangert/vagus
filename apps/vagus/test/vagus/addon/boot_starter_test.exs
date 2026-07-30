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
       ping: ping, ensure_network: fn -> :ok end, interval: 1, max_attempts: 20, name: nil}
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
       ping: fn -> :ok end, ensure_network: fn -> :ok end, interval: 1, max_attempts: 5, name: nil}
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
       ping: fn -> :ok end, ensure_network: fn -> :ok end, interval: 1, max_attempts: 5, name: nil}
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
       ping: fn -> :ok end, ensure_network: fn -> :ok end, interval: 1, max_attempts: 5, name: nil}
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
       ping: fn -> :ok end, ensure_network: fn -> :ok end, interval: 1, max_attempts: 5, name: nil}
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
       ping: fn -> :ok end, ensure_network: fn -> :ok end, interval: 1, max_attempts: 5, name: nil}
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
      {BootStarter, ping: fn -> {:error, :nope} end, interval: 1, max_attempts: 3, name: nil}
    )

    # 3 attempts * 1ms interval should exhaust well within this budget.
    Process.sleep(100)

    assert {:ok, %{state: :started}} = State.get(slug)
    assert Fake.calls_for("addon_#{slug}") == []
  end
end
