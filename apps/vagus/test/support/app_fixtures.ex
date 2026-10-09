defmodule Vagus.AppFixtures do
  @moduledoc """
  Seeds and cleans up installed apps for tests.

  Tests must not know where app facts live: they install, register and
  inspect apps only through this module, so when the store behind
  `Vagus.App` changes, only this file changes with it.
  """

  import ExUnit.Assertions, only: [assert_receive: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Vagus.Addon.{Config, Registry, State}

  @settings [:watchdog, :boot, :ingress_panel, :protected, :auto_update, :ports, :ingress_port]

  @spec app_config(String.t(), map()) :: Config.t()
  def app_config(slug, overrides \\ %{}) do
    {:ok, config} =
      %{
        "name" => "Test App",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y"
      }
      |> Map.merge(overrides)
      |> Config.parse()

    config
  end

  @doc """
  Installing a slug again keeps its ingress token, user options and settings,
  as a reinstall over a live entry does. `process: false` records the app with
  no process behind it, as after a process start that failed.
  """
  @spec install_app(Config.t(), keyword()) :: Config.t()
  def install_app(%Config{slug: slug} = config, opts \\ []) do
    {state, opts} = Keyword.pop(opts, :state, :stopped)
    {process?, changes} = Keyword.pop(opts, :process, true)
    check_keys!(changes)

    :ok = State.put(config, state)
    if process?, do: {:ok, _pid} = Vagus.App.Instances.ensure(slug)
    :ok = set_app(slug, changes)

    on_exit(fn -> forget_app(slug) end)
    config
  end

  @doc """
  Changes an installed app's options and settings mid-test, taking the same
  keys as `install_app/2` bar `:state`. `:ingress_port` is written to the store
  directly: `Vagus.App` does not expose it.
  """
  @spec set_app(String.t(), keyword()) :: :ok
  def set_app(slug, changes) do
    check_keys!(changes)
    {ingress_port, changes} = Keyword.split(changes, [:ingress_port])
    :ok = Vagus.App.set(slug, changes)
    Enum.each(ingress_port, fn {key, port} -> :ok = State.put_setting(slug, key, port) end)
  end

  defp check_keys!(changes) do
    Enum.each(changes, fn {key, _value} ->
      unless key == :options or key in @settings,
        do: raise(ArgumentError, "unknown app fixture option #{inspect(key)}")
    end)
  end

  @doc """
  A token is only ever issued to an installed app, and what the app posts with
  it lands in the app's process, so an app not yet installed is installed
  here and forgotten again at exit. `installed: false` leaves it uninstalled,
  as for a token outliving its app.
  """
  @spec register_app_token(Config.t(), keyword()) :: String.t()
  def register_app_token(%Config{slug: slug} = config, opts \\ []) do
    if Keyword.get(opts, :installed, true) and not match?({:ok, _entry}, State.get(slug)),
      do: install_app(config)

    token = Keyword.get_lazy(opts, :token, fn -> random_token() end)
    identity = Map.merge(Registry.identity_from_config(config), Keyword.get(opts, :identity, %{}))
    :ok = Registry.register(token, identity)
    on_exit(fn -> Registry.unregister_slug(slug) end)
    token
  end

  @spec app_info(String.t()) :: {:ok, State.entry()} | :error
  def app_info(slug), do: Vagus.App.info(slug)

  @spec app_list() :: [State.entry()]
  def app_list, do: Vagus.App.list()

  @doc """
  For tests that install through a route, so no fixture call exists to hang
  cleanup on, and for simulating a concurrent uninstall mid-test. The entry
  goes first, so a process restarting meanwhile ignores its start instead of
  coming back with no entry.
  """
  @spec forget_app(String.t()) :: :ok
  def forget_app(slug) do
    :ok = State.delete(slug)
    :ok = Vagus.App.Instances.stop(slug)
    :ok = Registry.unregister_slug(slug)
  end

  @doc "Sends `{tag, method, message}` to the test for each discovery push, in delivery order."
  @spec capture_discovery_pushes(atom()) :: :ok
  def capture_discovery_pushes(tag \\ :discovery_push) do
    test_pid = self()
    prev = Application.get_env(:vagus, :discovery_push)

    Application.put_env(:vagus, :discovery_push, fn method, message ->
      send(test_pid, {tag, method, message})
      :ok
    end)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :discovery_push),
        else: Application.put_env(:vagus, :discovery_push, prev)
    end)
  end

  @doc """
  Returns once every push queued before it is delivered, so a `refute_received`
  after it is not racing the queue.
  """
  @spec drain_discovery_pushes(atom()) :: :ok
  def drain_discovery_pushes(tag \\ :discovery_push) do
    uuid = "drain-#{System.unique_integer([:positive])}"
    Vagus.Discovery.Push.notify(:delete, %{uuid: uuid, addon: "", service: ""})
    assert_receive {^tag, :delete, %{uuid: ^uuid}}, 5_000
    :ok
  end

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
