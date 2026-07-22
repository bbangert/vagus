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

    start_supervised!({BootStarter, ping: ping, interval: 1, max_attempts: 20, name: nil})

    assert eventually(fn -> match?({:ok, %{state: :started}}, State.get(slug)) end)
    assert eventually(fn -> :create in Fake.calls() end)
    assert Enum.any?(Fake.calls(), &match?({:start, _id}, &1))
  end

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

    start_supervised!({BootStarter, ping: fn -> :ok end, interval: 1, max_attempts: 5, name: nil})

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug)) end)
    refute :create in Fake.calls()
  end

  test "boot: manual + :started is demoted to :stopped without any backend calls" do
    slug = "boot_manual_#{System.unique_integer([:positive])}"
    seed(slug, :started, fixture_config(slug, %{"boot" => "manual"}))

    start_supervised!({BootStarter, ping: fn -> :ok end, interval: 1, max_attempts: 5, name: nil})

    assert eventually(fn -> match?({:ok, %{state: :stopped}}, State.get(slug)) end)
    assert Fake.calls() == []
  end

  test "a :stopped entry is left alone" do
    slug = "boot_stopped_#{System.unique_integer([:positive])}"
    seed(slug, :stopped, fixture_config(slug, %{"boot" => "auto"}))

    pid =
      start_supervised!(
        {BootStarter, ping: fn -> :ok end, interval: 1, max_attempts: 5, name: nil}
      )

    # Give the reconcile pass a moment to (not) act, then confirm nothing
    # touched this slug or the backend.
    assert eventually(fn -> Process.alive?(pid) end)
    Process.sleep(20)
    assert {:ok, %{state: :stopped}} = State.get(slug)
    assert Fake.calls() == []
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
    assert Fake.calls() == []
  end
end
