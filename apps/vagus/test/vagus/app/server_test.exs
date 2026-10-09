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

  test "killed, it comes back under the same key as a new process" do
    slug = slug()
    install_app(app_config(slug))
    [{pid, _}] = lookup(slug)
    ref = Process.monitor(pid)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert new_pid = wait_for_new(slug, pid)
    assert new_pid != pid
    assert {:ok, %{config: %{slug: ^slug}}} = :gen_statem.call(new_pid, :info)
  end

  test "format_status/1 redacts secrets when present" do
    data = %{slug: "s", token_hash: "h", services: %{mqtt: %{"password" => "p"}}, discovery: [1]}

    assert %{data: %{slug: "s", token_hash: :redacted, services: :redacted, discovery: :redacted}} =
             Server.format_status(%{state: :idle, data: data})

    assert %{data: %{slug: "s"}} = Server.format_status(%{state: :idle, data: %{slug: "s"}})
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
