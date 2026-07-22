defmodule Vagus.Addon.DefaultProvider do
  @moduledoc """
  Auto-installs and boots Vagus's default native provider on startup (M5, the
  MQ-P5 default flip) — making the embedded mqttx broker the MQTT provider in
  place of the containerized Mosquitto add-on (which stays in the catalog as a
  reference but is never auto-installed).

  Unlike `Vagus.Addon.BootStarter` (which only re-starts *already-installed*
  add-ons and waits for the balena-engine to come up), a native add-on needs no
  container/engine, so this one-shot process installs + starts it directly,
  independent of Docker — the broker is available even on a boot where the
  engine never appears. It's placed after `Native.Supervisor`/`Services`/
  `Discovery`/`DNS` in the tree so all of its dependencies are up when it runs.

  Gated by `config :vagus, :default_native_addon` (the store slug to ensure,
  e.g. `"core_mqtt"`); `start_link/1` returns `:ignore` when unset, so it sits
  unconditionally in `Vagus.Application`'s children while `:host`/`mix test`
  simply never enable it. Idempotent: on later boots the add-on is already
  installed (and `BootStarter` also re-starts it), and every step tolerates that.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.{Config, Manager, State}
  alias Vagus.Addon.Store.BuiltinFetcher

  @doc "Starts the one-shot ensurer, or `:ignore` unless `:default_native_addon` is set."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :default_native_addon) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts), do: {:ok, opts, {:continue, :ensure}}

  @impl GenServer
  def handle_continue(:ensure, opts) do
    ensure(Application.get_env(:vagus, :default_native_addon))
    {:noreply, opts}
  end

  defp ensure(slug) do
    with {:ok, config} <- default_config(slug),
         :ok <- ensure_installed(slug, config) do
      case Manager.start_slug(slug) do
        {:ok, _result} ->
          Logger.info("Vagus.Addon.DefaultProvider: default provider #{slug} started")

        {:error, reason} ->
          Logger.warning("Vagus.Addon.DefaultProvider: start #{slug} failed: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        Logger.warning(
          "Vagus.Addon.DefaultProvider: could not ensure #{inspect(slug)}: #{inspect(reason)}"
        )
    end
  end

  defp ensure_installed(slug, config) do
    case State.get(slug) do
      {:ok, _entry} ->
        :ok

      :error ->
        with :ok <- Manager.install(config) do
          State.put(config, :stopped)
        end
    end
  end

  # The only builtin native add-on is the mqttx broker. Build its config directly
  # from the embedded source (no store reload needed at boot) and rewrite the slug
  # to the installed store slug, exactly as the store-install route does.
  defp default_config(slug) do
    case BuiltinFetcher.config(:mqtt) do
      nil ->
        {:error, :no_builtin}

      raw ->
        case Config.parse(raw) do
          {:ok, config} -> {:ok, %{config | slug: slug}}
          {:error, _} = err -> err
        end
    end
  end
end
