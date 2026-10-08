defmodule Vagus.AppFixtures do
  @moduledoc """
  Seeds and cleans up installed apps for tests.

  Tests must not know where app facts live: they install, register and
  inspect apps only through this module, so when the store behind
  `Vagus.App` changes, only this file changes with it.
  """

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
  as a reinstall over a live entry does.
  """
  @spec install_app(Config.t(), keyword()) :: Config.t()
  def install_app(%Config{slug: slug} = config, opts \\ []) do
    {state, changes} = Keyword.pop(opts, :state, :stopped)
    check_keys!(changes)

    :ok = State.put(config, state)
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

  @spec register_app_token(Config.t(), keyword()) :: String.t()
  def register_app_token(%Config{slug: slug} = config, opts \\ []) do
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
  cleanup on, and for simulating a concurrent uninstall mid-test.
  """
  @spec forget_app(String.t()) :: :ok
  def forget_app(slug) do
    :ok = State.delete(slug)
    :ok = Registry.unregister_slug(slug)
  end

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
