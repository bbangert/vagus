defmodule Vagus.App do
  @moduledoc """
  The one entry point to installed apps for everything outside the app
  subsystem: their facts, their settings and their lifecycle.

  Callers get the `Vagus.Addon.State` entry map and plain results, never a
  pid or a server name, so what sits behind these functions can change
  without touching them.
  """

  require Logger

  alias Vagus.Addon.{Config, Manager, State, Update}
  alias Vagus.Addon.Registry, as: Tokens
  alias Vagus.App.{Directory, Instances}
  alias Vagus.Network

  @settings [:ingress_panel, :watchdog, :ports, :boot, :auto_update, :protected]

  # The only options that mean anything to `Manager` from a backup; the rest of
  # `Vagus.Backups`' opts (`:server`, `:date`, `:extra`) are its own.
  @backup_opts [:backend, :data_root, :socket]

  @doc """
  The process's answer when it gives one, else the `Vagus.Addon.State` entry,
  so a missing or stuck process never hides an installed app.
  """
  @spec info(String.t()) :: {:ok, State.entry()} | :error
  def info(slug) do
    case ask(slug, :info) do
      {:ok, {:ok, entry}} -> {:ok, entry}
      {:ok, :error} -> :error
      :absent -> from_state(slug)
    end
  end

  # An entry whose process is missing (its start failed, or it was stopped out
  # of band) gets one back here; a live but stuck one is left to its own fate.
  defp from_state(slug) do
    with {:ok, _entry} = found <- State.get(slug) do
      if whereis(slug) == nil, do: Instances.ensure(slug)
      found
    end
  end

  @doc """
  Every app `Vagus.Addon.State` records, each with its process's answer laid
  over it. One whose process is missing or does not answer by the deadline is
  listed with `state: :unknown`, never left out: Home Assistant deletes the
  device of an app missing from `GET /addons`, with its entities and renames.
  """
  @spec list() :: [State.entry() | %{state: :unknown}]
  def list do
    entries = State.list()
    answers = entries |> Enum.flat_map(&live(&1.config.slug)) |> ask_all(:info, 1_000)

    Enum.flat_map(entries, fn %{config: %{slug: slug}} = entry ->
      case Map.get(answers, slug) do
        {:ok, {:ok, answered}} -> [answered]
        # Uninstalled since `State.list/0`.
        {:ok, :error} -> []
        _unanswered -> [%{entry | state: :unknown}]
      end
    end)
  end

  @spec installed?(String.t()) :: boolean()
  def installed?(slug), do: match?({:ok, _entry}, State.get(slug))

  @spec slugs() :: [String.t()]
  def slugs, do: Enum.map(State.list(), & &1.config.slug)

  @doc """
  `:absent` covers no process for the slug, a dead or unanswering one, and a
  directory that is restarting: to a caller they all mean "no answer".
  """
  @spec ask(String.t(), term(), timeout()) :: {:ok, term()} | :absent
  def ask(slug, question, timeout \\ 5_000) do
    case whereis(slug) do
      nil -> :absent
      pid -> {:ok, :gen_statem.call(pid, question, timeout)}
    end
  catch
    :exit, _reason -> :absent
  end

  # A dead pid can still be listed until the directory's partition handles its
  # exit; asking it exits `noproc`, which callers already read as no answer.
  defp whereis(slug) do
    case Registry.lookup(Directory, {:slug, slug}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp live(slug) do
    case whereis(slug) do
      nil -> []
      pid -> [{slug, pid}]
    end
  end

  @doc """
  Asks every installed app at once under one absolute deadline, so a single
  stuck app costs the caller `deadline_ms`, not `deadline_ms` per app.
  """
  @spec gather(term(), non_neg_integer()) :: [{String.t(), {:ok, term()} | :absent}]
  def gather(question, deadline_ms \\ 1_000) do
    slugs = slugs()
    answers = slugs |> Enum.flat_map(&live/1) |> ask_all(question, deadline_ms)
    Enum.map(slugs, &{&1, Map.get(answers, &1, :absent)})
  end

  # Requests still outstanding at the deadline are abandoned by `:gen_statem`,
  # so no late reply reaches the caller's mailbox.
  defp ask_all(apps, question, deadline_ms) do
    deadline = {:abs, System.monotonic_time(:millisecond) + deadline_ms}

    apps
    |> Enum.reduce(:gen_statem.reqids_new(), fn {slug, pid}, reqids ->
      :gen_statem.send_request(pid, question, slug, reqids)
    end)
    |> collect(deadline, %{})
  end

  defp collect(reqids, deadline, answers) do
    case :gen_statem.receive_response(reqids, deadline, true) do
      {{:reply, reply}, slug, rest} ->
        collect(rest, deadline, Map.put(answers, slug, {:ok, reply}))

      {{:error, _reason}, _slug, rest} ->
        collect(rest, deadline, answers)

      _timeout_or_no_request ->
        answers
    end
  end

  @doc """
  Writes `:options` and the per-install settings in the order given; `:error`
  when the slug is not installed, even with nothing to write. Every key is
  checked before anything is written: an unknown one raises `ArgumentError`.
  """
  @spec set(String.t(), keyword()) :: :ok | :error
  def set(slug, changes) when is_list(changes) do
    Enum.each(changes, fn {key, _value} ->
      unless key == :options or key in @settings,
        do: raise(ArgumentError, "unknown app setting #{inspect(key)}")
    end)

    if installed?(slug), do: write_all(slug, changes), else: :error
  end

  # A write still answers `:error` if the app is uninstalled between the check
  # and it, so the first one stops the rest.
  defp write_all(slug, changes) do
    Enum.reduce_while(changes, :ok, fn change, :ok ->
      case write(slug, change) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp write(slug, {:options, options}), do: State.put_options(slug, options)
  defp write(slug, {key, value}), do: State.put_setting(slug, key, value)

  @doc "`:error` also when the token registry is not running, as in narrow test setups."
  @spec identity_for_token(String.t()) :: {:ok, Tokens.identity()} | :error
  def identity_for_token(token) do
    if Process.whereis(Tokens), do: Tokens.identity_for_token(token), else: :error
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
  def uninstall(slug) do
    # One critical section: a reinstall landing between the uninstall and the
    # stop would have its new process killed.
    with_slug_lock(slug, fn ->
      result = Manager.uninstall_holding_lock(slug)
      # `:not_found` too: an entry deleted out of band can leave its process up.
      if result in [:ok, {:error, :not_found}], do: Instances.stop(slug)
      result
    end)
  end

  @doc """
  Pulls the image and records the app installed but `:stopped`. An installed
  slug is refused before the pull, as upstream does.
  """
  @spec install(Config.t()) :: :ok | {:error, :already_installed | term()}
  def install(%Config{slug: slug} = config) do
    # Under the lifecycle lock so two installs of one slug cannot both pass the
    # check, both pull and both write the entry. `Manager.install/2` does not
    # take this lock itself; nesting it would drop it at the inner release.
    with_slug_lock(slug, fn -> do_install(config) end)
  end

  defp do_install(%Config{slug: slug} = config) do
    if installed?(slug) do
      {:error, :already_installed}
    else
      with :ok <- Manager.install(config),
           :ok <- State.put(config, :stopped) do
        ensure_after_install(slug)
      end
    end
  end

  # The install is durable once the entry is written; a process that does not
  # start now comes back on the Orchestrator's next start or through `info/1`.
  defp ensure_after_install(slug) do
    case Instances.ensure(slug) do
      {:ok, _pid} ->
        :ok

      # The entry went between the put and the start: uninstalled meanwhile.
      :ignore ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("App #{slug} installed but its process did not start: #{inspect(reason)}")
        :ok
    end
  end

  # `Manager`'s lifecycle lock, so app-level steps serialise with its own.
  defp with_slug_lock(slug, fun),
    do: :global.trans({{:addon_lifecycle, slug}, self()}, fun, [node()])

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
