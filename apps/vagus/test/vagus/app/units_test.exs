defmodule Vagus.App.UnitsTest do
  # `async: false`: `demote` and `want_started` write the shared State.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures, only: [app_config: 2, listening_api_port: 0]

  alias Vagus.Addon.Backend.Native
  alias Vagus.Addon.State
  alias Vagus.App.{Gates, Units}
  alias Vagus.Core.EventPusher

  @arities %{
    list: 0,
    ensure: 1,
    in_flight?: 0,
    install_default: 1,
    want_started: 1,
    native?: 1,
    running?: 1,
    start: 1,
    demote: 1,
    stop: 1,
    core_start: 1,
    core_stop: 1,
    report: 2,
    push_complete: 0
  }

  defp installed(slug, attrs \\ %{}) do
    config = app_config(slug, attrs)
    :ok = State.put(config, :started)
    on_exit(fn -> State.delete(slug) end)
    %{config: config, state: :started}
  end

  defp slug, do: "units_#{System.unique_integer([:positive])}"

  test "every unit is a function of the arity the orchestrator calls it with" do
    units = Units.all()
    assert Map.keys(units) |> Enum.sort() == Enum.sort([:gates | Map.keys(@arities)])

    for {key, arity} <- @arities do
      assert is_function(Map.fetch!(units, key), arity), "#{key}/#{arity}"
    end

    assert Map.keys(units.gates) |> Enum.sort() == [:api, :engine, :network, :tree]
    assert Enum.all?(Map.values(units.gates), &is_function(&1, 0))
  end

  test "the tree gate passes once the application is started" do
    assert Gates.tree() == :ok
  end

  test "the api gate passes while the API's port accepts, and fails once it does not" do
    socket = listening_api_port()
    assert Gates.api() == :ok

    :ok = :gen_tcp.close(socket)
    assert Gates.api() == {:error, :not_accepting}
  end

  test "demote records the app stopped" do
    slug = slug()
    entry = installed(slug)
    assert Units.demote(entry) == :ok
    assert {:ok, %{state: :stopped}} = State.get(slug)
  end

  test "want_started records an installed app started, and an unknown one is an error" do
    slug = slug()
    %{config: config} = installed(slug)
    :ok = State.put(config, :stopped)

    assert Units.want_started(slug) == :ok
    assert {:ok, %{state: :started}} = State.get(slug)
    assert Units.want_started(slug()) == :error
  end

  test "native? holds only for an allowlisted native app" do
    native = %{config: %{app_config("core_mqtt", %{}) | backend: :native}}
    assert Units.native?(native)
    refute Units.native?(%{config: %{app_config("other", %{}) | backend: :native}})
    refute Units.native?(%{config: app_config("core_mqtt", %{})})
  end

  test "running? asks the native backend for a native app" do
    entry = %{config: %{app_config("core_mqtt", %{}) | backend: :native}}
    refute Units.running?(entry)

    Process.register(self(), Native.broker_name("addon_core_mqtt"))
    assert Units.running?(entry)
  after
    if Process.whereis(Native.broker_name("addon_core_mqtt")) == self(),
      do: Process.unregister(Native.broker_name("addon_core_mqtt"))
  end

  test "push_complete pushes Core the startup complete event" do
    assert Units.push_complete(self()) == :ok
    assert_received {:"$gen_cast", {:push, data}}

    assert data == %{
             "event" => "supervisor_update",
             "update_key" => "supervisor",
             "data" => %{"startup" => "complete"}
           }

    state = %{
      ready: true,
      connection_pid: self(),
      conn_mod: EventPusher.Connection,
      next_id: 7
    }

    EventPusher.handle_cast({:push, data}, state)
    assert_received {:"$gen_cast", {:request, {:text, json}}}

    assert Jason.decode!(json) == %{
             "id" => 7,
             "type" => "supervisor/event",
             "data" => data
           }
  end
end
