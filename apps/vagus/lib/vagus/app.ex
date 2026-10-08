defmodule Vagus.App do
  @moduledoc """
  The one entry point to installed apps for everything outside the app
  subsystem: their facts, their settings and their lifecycle.

  Callers get the `Vagus.Addon.State` entry map and plain results, never a
  pid or a server name, so what sits behind these functions can change
  without touching them.
  """

  alias Vagus.Addon.{Config, Manager, Registry, State, Update}
  alias Vagus.Network

  @settings [:ingress_panel, :watchdog, :ports, :boot, :auto_update, :protected]

  # The only options that mean anything to `Manager` from a backup; the rest of
  # `Vagus.Backups`' opts (`:server`, `:date`, `:extra`) are its own.
  @backup_opts [:backend, :data_root, :socket]

  @spec info(String.t()) :: {:ok, State.entry()} | :error
  def info(slug), do: State.get(slug)

  @spec list() :: [State.entry()]
  def list, do: State.list()

  @spec installed?(String.t()) :: boolean()
  def installed?(slug), do: match?({:ok, _entry}, State.get(slug))

  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(State.list(), & &1.config.slug)

  @doc """
  Writes `:options` and the per-install settings in the order given, stopping
  at the first `:error` (the slug is not installed). Every key is checked
  before anything is written: an unknown one raises `ArgumentError`.
  """
  @spec set(String.t(), keyword()) :: :ok | :error
  def set(slug, changes) when is_list(changes) do
    Enum.each(changes, fn {key, _value} ->
      unless key == :options or key in @settings,
        do: raise(ArgumentError, "unknown app setting #{inspect(key)}")
    end)

    Enum.reduce_while(changes, :ok, fn change, :ok ->
      case write(slug, change) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp write(slug, {:options, options}), do: State.put_options(slug, options)
  defp write(slug, {key, value}), do: State.put_setting(slug, key, value)

  @doc "`:error` also when the Registry is not running, as in narrow test setups."
  @spec identity_for_token(String.t()) :: {:ok, Registry.identity()} | :error
  def identity_for_token(token) do
    if Process.whereis(Registry), do: Registry.identity_for_token(token), else: :error
  end

  @spec resolve_ingress_token(String.t()) :: {:ok, String.t()} | :error
  def resolve_ingress_token(token), do: Vagus.Ingress.resolve_token(token)

  @doc """
  Where ingress traffic for `slug` goes: `{ip, port, stream?}`, `stream?`
  being the config's `ingress_stream`. The IP of a bridged app is read from a
  live docker inspect on every call.
  """
  @spec ingress_target(String.t()) ::
          {:ok, {String.t(), pos_integer(), boolean()}} | {:error, term()}
  def ingress_target(slug) do
    case State.get(slug) do
      :error ->
        {:error, :not_found}

      {:ok, entry} ->
        with {:ok, port} <- ingress_port(entry),
             {:ok, ip} <- ingress_ip(slug, entry, port) do
          {:ok, {ip, port, entry.config.ingress_stream == true}}
        end
    end
  end

  # The allocated dynamic port wins; otherwise the config's static port, unless
  # it is the `0` "assign one dynamically" sentinel.
  defp ingress_port(%{ingress_port: port}) when is_integer(port) and port > 0, do: {:ok, port}

  defp ingress_port(%{config: %{ingress_port: port}}) when is_integer(port) and port > 0,
    do: {:ok, port}

  defp ingress_port(_entry), do: {:error, :no_ingress_port}

  # A host-network app answers on loopback or on the gateway depending on the
  # app, so the port decides; `Vagus.Addon.Watchdog.Probe` must use the same
  # rule or it probes a live app dead.
  defp ingress_ip(_slug, %{config: %{host_network: true}}, port),
    do: {:ok, Network.host_network_ip(port)}

  defp ingress_ip(slug, _entry, _port) do
    with {:ok, %{"NetworkSettings" => %{"Networks" => networks}}} <-
           Vagus.Runtime.Docker.inspect_container("addon_#{slug}"),
         %{"IPAddress" => ip} when is_binary(ip) and ip != "" <-
           Map.get(networks, Network.name()) do
      {:ok, ip}
    else
      _ -> {:error, :no_container_ip}
    end
  end

  @spec start(String.t()) :: {:ok, map()} | {:error, term()}
  def start(slug), do: Manager.start_slug(slug)

  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(slug), do: Manager.stop(slug)

  @spec restart(String.t()) :: {:ok, map()} | {:error, term()}
  def restart(slug), do: Manager.restart(slug)

  @spec uninstall(String.t()) :: :ok | {:error, term()}
  def uninstall(slug), do: Manager.uninstall(slug)

  @doc "Pulls the image and records the app installed but `:stopped`."
  @spec install(Config.t()) :: :ok | {:error, term()}
  def install(%Config{} = config) do
    with :ok <- Manager.install(config) do
      State.put(config, :stopped)
    end
  end

  @spec update(String.t(), keyword()) :: {:ok, Update.result()} | {:error, term()}
  def update(slug, opts), do: Update.update(slug, opts)

  @spec stop_for_backup(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_for_backup(slug, opts \\ []), do: Manager.stop(slug, Keyword.take(opts, @backup_opts))

  @spec start_after_backup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_after_backup(slug, opts \\ []),
    do: Manager.start_slug(slug, Keyword.take(opts, @backup_opts))

  @doc "Whether `slug` may run in-BEAM, with no container behind it."
  @spec native_allowed?(String.t()) :: boolean()
  def native_allowed?(slug), do: Manager.native_allowed?(slug)
end
