defmodule Vagus.Runtime.Engine.FakeContractTest.Leg do
  @behaviour Vagus.Test.EngineContract

  alias Vagus.Runtime.Engine.Fake
  alias Vagus.Test.EngineContract, as: C

  @image "ghcr.io/vagus/aarch64-addon-x:1.2.0"

  @impl true
  def release(_opts), do: :ok

  @impl true
  def arrange(scenario, _ctx) do
    fake = Fake.start()
    setup(scenario, fake)
    [engine: Fake, fake: fake]
  end

  defp setup(:ready, _fake), do: :ok
  defp setup(:unavailable, fake), do: Fake.fail_next(fake, :ready, :unavailable)
  defp setup(:absent, _fake), do: :ok
  defp setup(:inspect_running, fake), do: put(fake, C.running())
  defp setup(:inspect_exited, fake), do: put(fake, C.exited())

  defp setup(:list, fake) do
    Enum.each([C.running(), C.paused(), C.restarting(), C.exited(), C.core()], &put(fake, &1))
  end

  defp setup({:live, state}, fake), do: put(fake, %{C.running() | state: state})
  defp setup({:remove_live, state}, fake), do: put(fake, %{C.running() | state: state})
  defp setup({:stop_live, state}, fake), do: put(fake, %{C.running() | state: state})

  defp setup(:start_created, fake), do: put(fake, %{C.running() | state: :created})
  defp setup(:start_running, fake), do: put(fake, C.running())

  defp setup(:stop_within_grace, fake) do
    put(fake, C.running())
    Fake.delay_next(fake, :stop, 500)
  end

  defp setup(:stop_all_slow, fake) do
    put(fake, C.running())
    put(fake, %{C.running() | name: "addon_local_d"})
    Fake.delay_next(fake, :stop, 5_100)
    Fake.delay_next(fake, :stop, 5_100)
  end

  defp setup(:stop_running, fake), do: put(fake, C.running())
  defp setup(:stop_stopped, fake), do: put(fake, C.exited())
  defp setup(:restart, fake), do: put(fake, C.running())
  defp setup(:remove, fake), do: put(fake, C.exited())

  defp setup(:stop_all, fake) do
    put(fake, %{C.running() | name: "addon_local_d"})
    put(fake, C.running())
    put(fake, C.exited())
    # stop_all stops in list order, so this lands on addon_local_d.
    Fake.fail_next(fake, :stop, {:failed, :stop, "boom"})
  end

  defp setup(:create, fake) do
    Fake.put_image(fake, @image)
    Vagus.Runtime.Engine.ensure_network(C.hassio(), engine: Fake, fake: fake)
  end

  defp setup(:create_no_network, fake), do: Fake.put_image(fake, @image)

  defp setup(:inspect_slow, fake) do
    put(fake, C.running())
    Fake.delay_next(fake, :inspect, 1_500)
  end

  defp setup(:stop_slow, fake) do
    put(fake, C.running())
    Fake.delay_next(fake, :stop, 1_500)
  end

  defp setup(:hang_up, fake), do: Fake.fail_next(fake, :inspect, :unavailable)

  defp setup(:health_never_ran, fake),
    do: put(fake, %{C.running() | state: :created, health: nil, started_at: nil})

  defp setup(:create_conflict, fake) do
    Fake.put_image(fake, @image)
    put(fake, C.running())
  end

  defp setup(:create_no_image, _fake), do: :ok
  defp setup(:pull, _fake), do: :ok

  defp setup(:pull_failed, fake),
    do: Fake.fail_next(fake, :pull, {:pull_failed, "manifest unknown"})

  defp setup(:image_absent, _fake), do: :ok
  defp setup(:remove_image, fake), do: Fake.put_image(fake, @image)

  defp setup(:image_in_use, fake) do
    Fake.put_image(fake, @image)
    put(fake, C.running())
  end

  defp setup(:logs, fake), do: put(fake, C.running(), logs: C.logs())
  defp setup(:follow, fake), do: put(fake, C.running(), logs: C.logs())
  defp setup({:stamped, _timestamps}, fake), do: put(fake, C.running(), logs: C.logs())
  defp setup(:stats, fake), do: put(fake, C.running(), stats: C.stats())
  defp setup({:exec, code, output}, fake), do: put(fake, C.running(), exec: {code, output})
  defp setup(:exec_no_capture, fake), do: put(fake, C.running(), exec: {3, "ignored\n"})

  defp setup(:exec_timeout, fake) do
    put(fake, C.running())
    Fake.fail_next(fake, :exec, :timeout)
  end

  defp setup({:health, health}, fake), do: put(fake, %{C.running() | health: health})

  defp setup(:network_exists, fake),
    do: Vagus.Runtime.Engine.ensure_network(C.hassio(), engine: Fake, fake: fake)

  defp setup(:network_created, _fake), do: :ok
  defp setup(:network_race, _fake), do: :ok

  defp setup(:engine_error, fake) do
    for verb <- [:stop | C.failing_verbs()],
        do: Fake.fail_next(fake, verb, {:failed, verb, "boom"})

    Fake.fail_next(fake, :pull, {:pull_failed, "boom"})
    Fake.fail_next(fake, :follow_logs, {:failed, :follow_logs, "boom"})
  end

  defp put(fake, container, extras \\ []) do
    Fake.put_container(
      fake,
      container.name,
      Map.merge(Map.from_struct(container), Map.new(extras))
    )
  end
end

defmodule Vagus.Runtime.Engine.FakeContractTest do
  use Vagus.Test.EngineContract, leg: Vagus.Runtime.Engine.FakeContractTest.Leg, async: true

  alias Vagus.Runtime.Engine.Fake

  describe "fake-only helpers" do
    test "a call that names no instance, with no global one, says how to give it" do
      assert_raise ArgumentError, ~r/pass fake: pid, or call start_global/, fn ->
        Engine.ready(engine: Fake)
      end
    end

    test "fail_next refuses stop_all, whose result cannot carry an error" do
      assert_raise ArgumentError, fn -> Fake.fail_next(Fake.start(), :stop_all, :busy) end
    end

    test "a delay within timeout_ms still runs the call" do
      fake = Fake.start()
      Fake.put_container(fake, "addon_a")
      Fake.delay_next(fake, :stop, 100)
      assert Engine.stop("addon_a", engine: Fake, fake: fake, timeout_ms: 500) == :ok

      assert {:ok, %Container{state: :exited}} =
               Engine.inspect("addon_a", engine: Fake, fake: fake)
    end

    test "calls/1 logs verbs in order and spec/2 keeps the create spec" do
      fake = Fake.start()
      opts = [engine: Fake, fake: fake]
      spec = Vagus.Test.EngineContract.spec()

      :ok = Engine.pull(spec.image, opts)
      :ok = Engine.ensure_network(Vagus.Test.EngineContract.hassio(), opts)
      {:ok, _id} = Engine.create(spec, opts)
      :ok = Engine.start(spec.name, opts)

      assert [{:pull, [_]}, {:ensure_network, [_]}, {:create, [^spec]}, {:start, [_]}] =
               Fake.calls(fake)

      assert Fake.spec(fake, spec.name) == spec
    end

    test "list summaries and tail-limited logs" do
      fake = Fake.start()
      opts = [engine: Fake, fake: fake]
      Fake.put_container(fake, "addon_a", logs: "1\n2\n3\n")
      Fake.set_state(fake, "addon_a", :exited)

      assert Engine.list(opts) == {:ok, []}

      assert {:ok, [%Container{name: "addon_a", env: nil, ips: nil}]} =
               Engine.list([all: true] ++ opts)

      assert Engine.logs("addon_a", [tail: 2] ++ opts) == {:ok, "2\n3\n"}
    end
  end
end
