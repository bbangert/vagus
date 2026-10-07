defmodule Vagus.App.Backend.NativeTest do
  # Not async: each test runs a real broker, which registers names and
  # binds a port.
  use ExUnit.Case, async: false

  alias Vagus.App.Backend.Native
  alias Vagus.Resource.TestInstance

  @moduletag :capture_log

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp connects?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _reason} -> false
    end
  end

  setup do
    # As the application's: a DynamicSupervisor of `:temporary` subtrees.
    supervisor =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_restarts: 5, max_seconds: 30}
      )

    slug = "native_#{System.unique_integer([:positive])}"
    port = free_port()
    %{slug: slug, port: port, opts: [supervisor: supervisor, port: port, provider: nil]}
  end

  test "nothing started is :absent", %{slug: slug, opts: opts} do
    assert Native.observe(slug, opts) == {:ok, :absent}
  end

  test "start/2 runs the broker under the supervisor, and observe/2 sees it", %{
    slug: slug,
    port: port,
    opts: opts
  } do
    assert Native.start(slug, opts) == :ok

    assert {:ok, %{state: :running, id: "native:" <> _, health: :none, address: nil}} =
             Native.observe(slug, opts)

    assert [{_id, pid, :supervisor, _modules}] =
             DynamicSupervisor.which_children(opts[:supervisor])

    assert Process.whereis(Native.broker_name(slug)) == pid
    assert connects?(port)
  end

  test "start/2 of a running broker is :ok and leaves the instance as it is", %{
    slug: slug,
    opts: opts
  } do
    :ok = Native.start(slug, opts)
    {:ok, %{id: id}} = Native.observe(slug, opts)

    assert Native.start(slug, opts) == :ok
    assert {:ok, %{id: ^id}} = Native.observe(slug, opts)
    assert %{active: 1} = DynamicSupervisor.count_children(opts[:supervisor])
  end

  test "stop/3 ends the broker, and is :ok again when it is gone", %{
    slug: slug,
    port: port,
    opts: opts
  } do
    :ok = Native.start(slug, opts)

    assert Native.stop(slug, 10, opts) == :ok
    assert Native.observe(slug, opts) == {:ok, :absent}
    assert %{active: 0, specs: 0} = DynamicSupervisor.count_children(opts[:supervisor])
    refute connects?(port)

    assert Native.stop(slug, 10, opts) == :ok
  end

  test "remove/2 ends a running broker too", %{slug: slug, opts: opts} do
    :ok = Native.start(slug, opts)

    assert Native.remove(slug, opts) == :ok
    assert Native.observe(slug, opts) == {:ok, :absent}
    assert Native.remove(slug, opts) == :ok
  end

  test "an instance started again has another id", %{slug: slug, opts: opts} do
    :ok = Native.start(slug, opts)
    {:ok, %{id: first}} = Native.observe(slug, opts)
    :ok = Native.stop(slug, nil, opts)
    :ok = Native.start(slug, opts)

    assert {:ok, %{id: second}} = Native.observe(slug, opts)
    assert second != first
  end

  test "a broker that is killed is :absent, and is not started again by anyone", %{
    slug: slug,
    opts: opts
  } do
    :ok = Native.start(slug, opts)
    broker = Process.whereis(Native.broker_name(slug))

    # Returns once the supervisor has dealt with the exit.
    TestInstance.kill_observed(broker, opts[:supervisor])

    assert DynamicSupervisor.which_children(opts[:supervisor]) == []
    assert %{active: 0, specs: 0} = DynamicSupervisor.count_children(opts[:supervisor])
    assert Native.observe(slug, opts) == {:ok, :absent}
  end

  test "the holding supervisor outlives ten brokers killed in a row", %{opts: opts} do
    holding = opts[:supervisor]

    for n <- 1..10 do
      # Each its own name and port: what a killed broker leaves dying must
      # not be what fails the next start.
      slug = "killed_#{n}_#{System.unique_integer([:positive])}"
      opts = Keyword.put(opts, :port, free_port())
      :ok = Native.start(slug, opts)

      TestInstance.kill_observed(Process.whereis(Native.broker_name(slug)), holding)

      assert Native.observe(slug, opts) == {:ok, :absent}
    end

    assert Process.alive?(holding)
    assert DynamicSupervisor.which_children(holding) == []
  end

  test "a process under the broker's name that the supervisor does not hold is not the instance",
       %{
         slug: slug,
         opts: opts
       } do
    impostor = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(impostor, Native.broker_name(slug))
    on_exit(fn -> Process.exit(impostor, :kill) end)

    assert Native.observe(slug, opts) == {:ok, :absent}
  end

  test "start/2 under a name another process holds is an error, and nothing is started", %{
    slug: slug,
    opts: opts
  } do
    impostor = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(impostor, Native.broker_name(slug))
    on_exit(fn -> Process.exit(impostor, :kill) end)

    assert Native.start(slug, opts) ==
             {:error, {:other, {:name_taken, Native.broker_name(slug)}}}

    assert Native.observe(slug, opts) == {:ok, :absent}
    assert %{active: 0} = DynamicSupervisor.count_children(opts[:supervisor])
    assert Process.whereis(Native.broker_name(slug)) == impostor
  end

  test "with the supervisor away, observe/2 is unavailable", %{slug: slug, opts: opts} do
    opts = Keyword.put(opts, :supervisor, :"no_supervisor_#{slug}")
    assert Native.observe(slug, opts) == {:unavailable, :native_supervisor_down}
  end

  test "with the supervisor away, start/2 exits", %{slug: slug, opts: opts} do
    opts = Keyword.put(opts, :supervisor, :"no_supervisor_#{slug}")
    assert {:noproc, _call} = catch_exit(Native.start(slug, opts))
  end

  test "with the supervisor away, stop/3 of something registered exits and of nothing is :ok",
       %{slug: slug, opts: opts} do
    opts = Keyword.put(opts, :supervisor, :"no_supervisor_#{slug}")
    assert Native.stop(slug, nil, opts) == :ok

    holder = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(holder, Native.broker_name(slug))
    on_exit(fn -> Process.exit(holder, :kill) end)

    assert {:noproc, _call} = catch_exit(Native.stop(slug, nil, opts))
  end

  test "asking after a name nothing was started under makes no atom of it", %{opts: opts} do
    slug = "never_#{System.unique_integer([:positive])}"

    assert Native.observe(slug, opts) == {:ok, :absent}
    assert Native.stop(slug, nil, opts) == :ok
    assert Native.remove(slug, opts) == :ok

    assert_raise ArgumentError, fn ->
      String.to_existing_atom("Elixir.Vagus.Mqtt.Broker.addon_" <> slug)
    end
  end

  describe "defaults" do
    setup %{slug: slug, port: port, opts: opts} do
      root = Path.join(System.tmp_dir!(), "vagus-native-#{System.pid()}-#{slug}")

      previous =
        for key <- [:mqtt_broker_port, :addon_data_root],
            do: {key, Application.fetch_env(:vagus, key)}

      Application.put_env(:vagus, :mqtt_broker_port, port)
      Application.put_env(:vagus, :addon_data_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        for {key, value} <- previous do
          case value do
            {:ok, value} -> Application.put_env(:vagus, key, value)
            :error -> Application.delete_env(:vagus, key)
          end
        end
      end)

      %{opts: Keyword.take(opts, [:supervisor])}
    end

    test "the port is the configured broker port", %{slug: slug, port: port, opts: opts} do
      :ok = Native.start(slug, [provider: nil] ++ opts)
      assert connects?(port)
    end

    test "the broker announces its service unless told not to", %{slug: slug, opts: opts} do
      provider = Module.concat(Native.broker_name(slug), "Provider")

      :ok = Native.start(slug, [provider: nil] ++ opts)
      assert Process.whereis(provider) == nil
      :ok = Native.stop(slug, nil, opts)

      :ok = Native.start(slug, opts)
      assert is_pid(Process.whereis(provider))
      assert {:ok, %{"addon" => ^slug}} = Vagus.Services.get("mqtt")

      :ok = Native.stop(slug, nil, opts)
      assert Process.whereis(provider) == nil
      assert Vagus.Services.get("mqtt") == :error
    end
  end

  test "a broker that cannot start is an error, and nothing is left behind", %{
    slug: slug,
    opts: opts
  } do
    {:ok, taken} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(taken)
    on_exit(fn -> :gen_tcp.close(taken) end)

    assert {:error, {:other, _reason}} = Native.start(slug, Keyword.put(opts, :port, port))
    assert Native.observe(slug, opts) == {:ok, :absent}
  end

  test "create/3 and remove_image/2 do nothing, and the image is always there", %{
    slug: slug,
    opts: opts
  } do
    assert Native.create(slug, %{}, opts) == :ok
    assert Native.observe(slug, opts) == {:ok, :absent}

    assert Native.image_present?("any:1", opts) == {:ok, true}
    assert Native.remove_image("any:1", opts) == :ok
  end

  test "no action runs in a lane" do
    for action <- [:create, :start, :stop, :remove, :remove_image],
        do: assert(Native.lane(action) == nil)
  end

  describe "under the application's own supervisor" do
    @supervisor Vagus.Addon.Backend.Native.Supervisor

    setup %{slug: slug, port: port} do
      opts = [port: port, provider: nil]
      on_exit(fn -> Native.stop(slug, nil, opts) end)
      %{opts: opts}
    end

    test "the default supervisor is the one the application runs", %{slug: slug, opts: opts} do
      others = DynamicSupervisor.which_children(@supervisor)

      assert Native.start(slug, opts) == :ok
      assert {:ok, %{state: :running}} = Native.observe(slug, opts)

      pid = Process.whereis(Native.broker_name(slug))

      assert DynamicSupervisor.which_children(@supervisor) -- others ==
               [{:undefined, pid, :supervisor, [Vagus.Mqtt.Broker]}]

      assert Native.stop(slug, nil, opts) == :ok
      assert DynamicSupervisor.which_children(@supervisor) == others
    end

    test "the instance is the one the old backend knows as addon_<slug>", %{
      slug: slug,
      opts: opts
    } do
      id = "addon_" <> slug
      assert Vagus.Addon.Backend.Native.state(id) == {:ok, :stopped}

      :ok = Native.start(slug, opts)
      assert Vagus.Addon.Backend.Native.state(id) == {:ok, :running}
      assert Vagus.Addon.Backend.Native.broker_name(id) == Native.broker_name(slug)

      :ok = Native.stop(slug, nil, opts)
      assert Vagus.Addon.Backend.Native.state(id) == {:ok, :stopped}
    end
  end
end
