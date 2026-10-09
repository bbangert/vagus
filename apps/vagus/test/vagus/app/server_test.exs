defmodule Vagus.App.ServerTest do
  # Starts app processes under the global `Vagus.App.Instances` and seeds the
  # global `Vagus.Addon.State`.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures

  alias Vagus.Addon.State
  alias Vagus.App.{Instances, Server}

  defp slug, do: "app_server_#{System.unique_integer([:positive])}"

  defp lookup(slug), do: Registry.lookup(Vagus.App.Directory, {:slug, slug})

  test "ensure/1 twice gives the same process" do
    slug = slug()
    install_app(app_config(slug))

    assert {:ok, pid} = Instances.ensure(slug)
    assert {:ok, ^pid} = Instances.ensure(slug)
    assert [{^pid, _}] = lookup(slug)
  end

  test ":info answers the State entry" do
    slug = slug()
    install_app(app_config(slug), state: :started)
    [{pid, _}] = lookup(slug)

    assert {:ok, %{state: :started, config: %{slug: ^slug}}} = :gen_statem.call(pid, :info)
    assert :gen_statem.call(pid, :installed?)
  end

  test "once its entry is gone it answers :error and stops :normal" do
    slug = slug()
    install_app(app_config(slug))
    [{pid, _}] = lookup(slug)
    ref = Process.monitor(pid)

    :ok = State.delete(slug)

    assert :error = :gen_statem.call(pid, :info)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert :absent = Vagus.App.ask(slug, :info)
  end

  test "with no State entry it does not start" do
    assert :ignore = Instances.ensure(slug())
  end

  # A private supervisor, so repeated runs cannot spend the restart budget of
  # the shared `Vagus.App.Instances`; the via-name still registers the process
  # in the directory.
  test "killed, it comes back under the same key as a new process" do
    slug = slug()
    :ok = State.put(app_config(slug), :stopped)
    on_exit(fn -> State.delete(slug) end)

    sup =
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_restarts: 10, max_seconds: 60}
      )

    {:ok, pid} = DynamicSupervisor.start_child(sup, {Server, slug})
    ref = Process.monitor(pid)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert new_pid = wait_for_new(slug, pid)
    assert new_pid != pid
    assert {:ok, %{config: %{slug: ^slug}}} = :gen_statem.call(new_pid, :info)
  end

  test "an unknown question is answered, not a crash" do
    slug = slug()
    install_app(app_config(slug))
    [{pid, _}] = lookup(slug)

    assert {:error, :unknown_question} = :gen_statem.call(pid, :no_such_question)
    assert Process.alive?(pid)
  end

  test "format_status/1 redacts secrets when present" do
    data = %{slug: "s", token_hash: "h", services: %{mqtt: %{"password" => "p"}}, discovery: [1]}

    assert %{data: %{slug: "s", token_hash: :redacted, services: :redacted, discovery: :redacted}} =
             Server.format_status(%{state: :idle, data: data})

    assert %{data: %{slug: "s"}} = Server.format_status(%{state: :idle, data: %{slug: "s"}})
  end

  test "format_status/1 redacts the payload of an event being handled" do
    from = {self(), make_ref()}

    queue = [
      {{:call, from}, {:provide_service, "mqtt", %{"password" => "p"}}},
      {{:call, from}, {:add_discovery, "mqtt", %{"password" => "p"}}},
      {{:call, from}, :info}
    ]

    assert %{queue: redacted, postponed: [_]} =
             Server.format_status(%{data: %{}, queue: queue, postponed: [hd(queue)]})

    assert redacted == [
             {{:call, from}, {:provide_service, "mqtt", :redacted}},
             {{:call, from}, {:add_discovery, "mqtt", :redacted}},
             {{:call, from}, :info}
           ]

    refute inspect(Server.format_status(%{data: %{}, queue: queue, postponed: queue})) =~ ~s("p")
  end

  # Process-level: the state of a live process, as `:sys.get_status/1` and a
  # crash report show it.
  test "a live process's status shows no service payload" do
    slug = slug()
    install_app(app_config(slug))
    [{pid, _}] = lookup(slug)
    :ok = :gen_statem.call(pid, {:provide_service, "svc_#{slug}", %{"password" => "s3cret"}})

    refute inspect(:sys.get_status(pid)) =~ "s3cret"
  end

  describe "services" do
    setup do
      slug = slug()
      install_app(app_config(slug))
      [{pid, _}] = lookup(slug)
      %{slug: slug, pid: pid, name: "svc_#{slug}"}
    end

    test "a provided service is held and keyed in the directory under its provider",
         %{slug: slug, pid: pid, name: name} do
      assert :ok = :gen_statem.call(pid, {:provide_service, name, %{"host" => "h"}})

      assert {:ok, %{"host" => "h"}} = :gen_statem.call(pid, {:service, name})
      assert [{^pid, ^slug}] = Registry.lookup(Vagus.App.Directory, {:service, name})
    end

    test "a second provider is refused, and so is the provider's own re-post",
         %{pid: pid, name: name} do
      other = slug()
      install_app(app_config(other))
      [{other_pid, _}] = lookup(other)
      :ok = :gen_statem.call(pid, {:provide_service, name, %{"host" => "a"}})

      assert {:error, :already_provided} =
               :gen_statem.call(other_pid, {:provide_service, name, %{"host" => "b"}})

      assert {:error, :already_provided} =
               :gen_statem.call(pid, {:provide_service, name, %{"host" => "c"}})

      assert :error = :gen_statem.call(other_pid, {:service, name})
      assert {:ok, %{"host" => "a"}} = :gen_statem.call(pid, {:service, name})
    end

    test "a withdrawn service leaves the directory and can be provided again",
         %{pid: pid, name: name} do
      :ok = :gen_statem.call(pid, {:provide_service, name, %{}})

      assert :ok = :gen_statem.call(pid, {:withdraw_service, name})
      assert {:error, :not_found} = :gen_statem.call(pid, {:withdraw_service, name})
      assert :error = :gen_statem.call(pid, {:service, name})
      assert [] = Registry.lookup(Vagus.App.Directory, {:service, name})
      assert :ok = :gen_statem.call(pid, {:provide_service, name, %{}})
    end

    test "every key goes with the process", %{slug: slug, pid: pid, name: name} do
      :ok = :gen_statem.call(pid, {:provide_service, name, %{}})
      {:ok, %{uuid: uuid}, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})
      ref = Process.monitor(pid)

      :ok = Instances.stop(slug)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # The directory drops a dead process's keys when its partition handles
      # the exit, asynchronously to the DOWN the test sees.
      assert gone?({:service, name})
      assert gone?({:discovery, uuid})
    end
  end

  describe "discovery" do
    setup do
      slug = slug()
      install_app(app_config(slug))
      [{pid, _}] = lookup(slug)
      %{slug: slug, pid: pid}
    end

    test "a new message gets a uuid and a directory key, a repeat keeps both",
         %{slug: slug, pid: pid} do
      assert {:ok, %{uuid: uuid, addon: ^slug, service: "mqtt", config: %{"a" => 1}} = message,
              :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{"a" => 1}})

      assert uuid =~ ~r/\A[0-9a-f]{32}\z/
      assert [{^pid, ^slug}] = Registry.lookup(Vagus.App.Directory, {:discovery, uuid})

      assert {:ok, ^message, :existing} =
               :gen_statem.call(pid, {:add_discovery, "mqtt", %{"a" => 1}})

      assert {:ok, %{uuid: ^uuid, config: %{"a" => 2}}, :updated} =
               :gen_statem.call(pid, {:add_discovery, "mqtt", %{"a" => 2}})

      assert {:ok, %{config: %{"a" => 2}}} = :gen_statem.call(pid, {:discovery, uuid})
      assert [%{uuid: ^uuid}] = :gen_statem.call(pid, :discovery_list)
    end

    test "another service is another message", %{pid: pid} do
      {:ok, %{uuid: a}, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})
      {:ok, %{uuid: b}, :new} = :gen_statem.call(pid, {:add_discovery, "other", %{}})

      refute a == b
      assert length(:gen_statem.call(pid, :discovery_list)) == 2
    end

    test "a deleted message leaves the directory", %{pid: pid} do
      {:ok, %{uuid: uuid} = message, :new} = :gen_statem.call(pid, {:add_discovery, "mqtt", %{}})

      assert {:ok, ^message} = :gen_statem.call(pid, {:delete_discovery, uuid})
      assert {:error, :not_found} = :gen_statem.call(pid, {:delete_discovery, uuid})
      assert :error = :gen_statem.call(pid, {:discovery, uuid})
      assert [] = :gen_statem.call(pid, :discovery_list)
      assert [] = Registry.lookup(Vagus.App.Directory, {:discovery, uuid})
    end
  end

  defp gone?(key, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      Registry.lookup(Vagus.App.Directory, key) == [] -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> gone?(key, deadline)
    end
  end

  # The restart is the DynamicSupervisor's, asynchronous to the DOWN the test
  # sees; poll the directory against a deadline rather than sleeping.
  defp wait_for_new(slug, old, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    case lookup(slug) do
      [{pid, _}] when pid != old ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: nil,
          else: wait_for_new(slug, old, deadline)
    end
  end
end
