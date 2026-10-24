defmodule Vagus.App do
  @moduledoc """
  The one entry point to installed apps for everything outside the app
  subsystem: their facts, their settings and their lifecycle.

  Callers get plain maps and results, never a pid or a server name, so what
  sits behind these functions can change without touching them. Behind them
  is one `Vagus.App.Server` per app; its answer is the truth, and its saved
  file stands in only for an app that does not answer a listing in time.
  """

  require Logger

  alias Vagus.Addon.{Config, Store}
  alias Vagus.App.{Directory, Instances, Policy, Units}
  alias Vagus.App.File, as: AppFile
  alias Vagus.Network

  @settings [:ingress_panel, :watchdog, :ports, :boot, :auto_update, :protected]

  # The only options that mean anything to an operation from a backup; the
  # rest of `Vagus.Backups`' opts (`:server`, `:date`, `:extra`) are its own.
  @backup_opts [:backend, :engine_opts, :data_root, :socket]

  @type entry :: map()
  @type update_result :: %{slug: String.t(), from: String.t(), to: String.t()}

  @spec info(String.t()) :: {:ok, entry()} | :error
  def info(slug) do
    case ask_healing(slug, :info) do
      {:ok, {:ok, entry}} -> {:ok, entry}
      _absent_or_not_installed -> :error
    end
  end

  @doc """
  Every app with a saved file. One whose process does not answer by the
  deadline is listed from its file with `state: :unknown`, never left out:
  Home Assistant deletes the device of an app missing from `GET /addons`,
  with its entities and renames.
  """
  @spec list() :: [entry()]
  def list do
    slugs = slugs()
    answers = slugs |> Enum.flat_map(&live/1) |> ask_all(:snapshot, 1_000)

    Enum.flat_map(slugs, fn slug ->
      case Map.get(answers, slug) do
        # Uninstalled since the directory was listed.
        {:ok, :error} -> []
        {:ok, entry} -> [entry]
        nil -> unanswered(slug)
      end
    end)
  end

  defp unanswered(slug) do
    case AppFile.read(slug) do
      {:ok, saved} -> [unknown(slug, saved)]
      # A file that does not decode still names an installed app.
      {:error, _reason} -> [unknown(slug, %{config: placeholder(slug)})]
      :error -> []
    end
  end

  defp unknown(slug, saved),
    do: slug |> Policy.init_data(saved) |> Policy.snapshot() |> Map.put(:state, :unknown)

  defp placeholder(slug),
    do: %Config{slug: slug, name: slug, version: "unknown", description: "", arch: []}

  @spec installed?(String.t()) :: boolean()
  def installed?(slug), do: match?({:ok, true}, ask_healing(slug, :installed?))

  @doc "Installed, but its file does not load: listed and uninstallable, nothing else."
  @spec refused?(String.t()) :: boolean()
  def refused?(slug), do: match?({:ok, true}, ask_healing(slug, :refused?))

  @spec slugs() :: [String.t()]
  def slugs, do: Enum.sort(AppFile.saved())

  @doc """
  `:absent` covers no process for the slug, a dead or unanswering one, and a
  directory that is restarting: to a caller they all mean "no answer".
  """
  @spec ask(String.t(), term(), timeout()) :: {:ok, term()} | :absent
  def ask(slug, question, timeout \\ 5_000), do: call(whereis(slug), question, timeout)

  defp call(nil, _question, _timeout), do: :absent

  defp call(pid, question, timeout) do
    {:ok, :gen_statem.call(pid, question, timeout)}
  catch
    :exit, _reason -> :absent
  end

  # An app with a saved file but no process (its start failed, or it was
  # stopped out of band) gets one back here, so a missing process never hides
  # an installed app nor drops a write the app makes about itself.
  defp ask_healing(slug, question, timeout \\ 5_000),
    do: call(whereis(slug) || heal(slug), question, timeout)

  defp heal(slug) do
    with true <- slug in AppFile.saved(),
         {:ok, pid} <- Instances.ensure(slug) do
      pid
    else
      _ -> nil
    end
  end

  # A dead pid can still be listed until the directory's partition handles its
  # exit; asking it exits `noproc`, which callers already read as no answer.
  defp whereis(slug) do
    case lookup({:slug, slug}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
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
  Monitors the app's process, starting it first if the app is installed but
  has none, for a caller that must publish again into the next one.
  """
  @spec monitor(String.t()) :: {:ok, reference()} | :absent
  def monitor(slug) do
    case whereis(slug) || heal(slug) do
      nil -> :absent
      pid -> {:ok, Process.monitor(pid)}
    end
  end

  @spec provide_service(String.t(), String.t(), map()) ::
          :ok | {:error, :already_provided | :unavailable}
  def provide_service(slug, name, payload) do
    case ask_healing(slug, {:provide_service, name, payload}) do
      {:ok, reply} -> reply
      :absent -> {:error, :unavailable}
    end
  end

  @doc "Only the providing app's own process holds the service, so another app's withdraw finds nothing."
  @spec withdraw_service(String.t(), String.t(), timeout()) ::
          :ok | {:error, :not_found | :unavailable}
  def withdraw_service(slug, name, timeout \\ 5_000) do
    case ask(slug, {:withdraw_service, name}, timeout) do
      {:ok, reply} -> reply
      :absent -> {:error, :unavailable}
    end
  end

  @spec service(String.t()) :: {:ok, String.t(), map()} | :error
  def service(name) do
    with [{pid, slug}] <- lookup({:service, name}),
         {:ok, {:ok, payload}} <- call(pid, {:service, name}, 5_000) do
      {:ok, slug, payload}
    else
      _ -> :error
    end
  end

  @doc "Every provided service as `{name, provider_slug}`, read from the directory alone."
  @spec services() :: [{String.t(), String.t()}]
  def services do
    Registry.select(Directory, [{{{:service, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  @spec add_discovery(String.t(), String.t(), map()) ::
          {:ok, Policy.message(), :new | :existing | :updated} | {:error, :unavailable}
  def add_discovery(slug, service, config) do
    case ask_healing(slug, {:add_discovery, service, config}) do
      {:ok, reply} -> reply
      :absent -> {:error, :unavailable}
    end
  end

  @spec delete_discovery(String.t(), String.t(), timeout()) ::
          {:ok, Policy.message()} | {:error, :not_found | :not_owner}
  def delete_discovery(slug, uuid, timeout \\ 5_000) do
    case lookup({:discovery, uuid}) do
      [{pid, ^slug}] ->
        case call(pid, {:delete_discovery, uuid}, timeout) do
          {:ok, reply} -> reply
          :absent -> {:error, :not_found}
        end

      [{_pid, _owner}] ->
        {:error, :not_owner}

      [] ->
        {:error, :not_found}
    end
  end

  @spec discovery(String.t()) :: {:ok, Policy.message()} | :error
  def discovery(uuid) do
    with [{pid, _slug}] <- lookup({:discovery, uuid}),
         {:ok, {:ok, message}} <- call(pid, {:discovery, uuid}, 5_000) do
      {:ok, message}
    else
      _ -> :error
    end
  end

  @doc "An app that does not answer by the deadline is left out."
  @spec discoveries() :: [Policy.message()]
  def discoveries do
    answers = gather(:discovery_list)

    case for {slug, :absent} <- answers, do: slug do
      [] ->
        :ok

      missing ->
        Logger.warning("Discovery list omits apps that did not answer: #{inspect(missing)}")
    end

    for {_slug, {:ok, messages}} when is_list(messages) <- answers,
        message <- messages,
        do: message
  end

  defp lookup(key) do
    Registry.lookup(Directory, key)
  rescue
    ArgumentError -> []
  end

  @doc """
  Writes `:options` and the per-install settings together, on disk before
  it returns; `:error` when the slug is not installed, even with nothing to
  write. Every key is checked first: an unknown one raises `ArgumentError`.
  """
  @spec set(String.t(), keyword()) :: :ok | :error | {:error, :protected}
  def set(slug, changes) when is_list(changes) do
    validate_settings!(Keyword.delete(changes, :options))

    if Keyword.has_key?(changes, :boot) or Keyword.has_key?(changes, :watchdog),
      do: unprotected(slug, fn -> do_set(slug, changes) end),
      else: do_set(slug, changes)
  end

  @doc """
  `set/2` for per-install settings without its protection, for boot's own
  default apps (`Vagus.App.Units.install_default/1`); no request reaches it.
  """
  @spec put_settings(String.t(), keyword()) :: :ok | :error
  def put_settings(slug, settings) when is_list(settings) do
    validate_settings!(settings)
    do_set(slug, settings)
  end

  defp validate_settings!(settings) do
    Enum.each(settings, fn {key, _value} ->
      unless key in @settings, do: raise(ArgumentError, "unknown app setting #{inspect(key)}")
    end)
  end

  defp do_set(slug, changes) do
    case ask_healing(slug, {:set, changes}) do
      {:ok, :ok} -> :ok
      _not_written -> :error
    end
  end

  @doc "A token is found by its hash, so the directory never holds one in the clear."
  @spec identity_for_token(String.t()) :: {:ok, map()} | :error
  def identity_for_token(token) do
    with [{pid, _slug}] <- lookup({:token, Policy.hash(token)}),
         {:ok, {:ok, identity}} <- call(pid, :identity, 5_000) do
      {:ok, identity}
    else
      _ -> :error
    end
  end

  @doc """
  The token the app's running container holds, for a caller inside this VM
  that must act as the app. `:error` for an app that is stopped, native or
  gone.

  A secret. It lives in the app's own process, which redacts it from its
  status, and it reaches the caller in that process's reply. The caller
  uses it where it asked and does not keep, forward or log it.
  """
  @spec token(String.t()) :: {:ok, String.t()} | :error
  def token(slug) do
    case ask(slug, :token) do
      {:ok, {:ok, token}} -> {:ok, token}
      _absent_or_none -> :error
    end
  end

  @doc """
  Where ingress traffic for `slug` goes: `{ip, port, stream?}`, `stream?`
  being the config's `ingress_stream`. A host-network app answers on
  loopback or on the gateway depending on the app, so a connect to its port
  decides here, outside its process.
  """
  @spec ingress_target(String.t()) ::
          {:ok, {String.t(), pos_integer(), boolean()}} | {:error, term()}
  def ingress_target(slug) do
    case ask(slug, :ingress_target) do
      {:ok, {:ok, {:host_network, port, stream}}} ->
        {:ok, {Network.host_network_ip(port), port, stream}}

      {:ok, answer} ->
        answer

      :absent ->
        {:error, :not_found}
    end
  end

  @spec start(String.t()) :: {:ok, map()} | {:error, term()}
  def start(slug), do: slug |> command(:start, %{}) |> started(slug)

  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(slug), do: unprotected(slug, fn -> command(slug, :stop, %{}) end)

  @spec restart(String.t()) :: {:ok, map()} | {:error, term()}
  def restart(slug),
    do: unprotected(slug, fn -> slug |> command(:restart, %{}) |> started(slug) end)

  @spec uninstall(String.t()) :: :ok | {:error, term()}
  def uninstall(slug), do: unprotected(slug, fn -> command(slug, :uninstall, %{}) end)

  @doc "The agent flavor's orchestrator app, which holds the board's agent login and makes its workers."
  @spec orchestrator?(String.t() | nil) :: boolean()
  def orchestrator?(slug) do
    orchestrator = Application.get_env(:vagus, :orchestrator_app)
    orchestrator != nil and slug == orchestrator
  end

  @doc "The agent flavor's memory DB app, on the internal `agentnet` (`Vagus.Network.Agentnet`)."
  @spec memory_app?(String.t() | nil) :: boolean()
  def memory_app?(slug) do
    memory = Application.get_env(:vagus, :memory_app)
    memory != nil and slug == memory
  end

  @doc """
  The agent flavor's own apps (`:protected_apps`: the orchestrator and its
  memory DB). A request may not stop, restart, uninstall or restore one,
  nor change its `boot` or `watchdog`: from inside the board that is the
  agent cutting off its own control or memory. `update/2` stays allowed,
  since an image bump is legitimate and starts it again. Shutdown and a
  cold backup halt one through units and the backup policy, not through
  these.
  """
  @spec protected?(String.t() | nil) :: boolean()
  def protected?(slug), do: slug in Application.get_env(:vagus, :protected_apps, [])

  defp unprotected(slug, fun), do: if(protected?(slug), do: {:error, :protected}, else: fun.())

  @doc """
  Pulls the image and records the app installed, wanted `:stopped` unless
  `wanted: :started` says boot should start it. An installed slug is refused
  by its process before any pull, as upstream does.

  `settings:` are per-install settings committed with the install itself.
  They skip `set/2`'s protection, which guards against requests and would
  otherwise leave the orchestrator app with no way to get its boot and
  watchdog; no request reaches this option.
  """
  @spec install(Config.t(), keyword()) :: :ok | {:error, :already_installed | term()}
  def install(%Config{slug: slug} = config, opts \\ []) do
    settings = Keyword.get(opts, :settings, [])
    validate_settings!(settings)

    args = %{
      config: config,
      wanted: Keyword.get(opts, :wanted, :stopped),
      settings: Map.new(settings)
    }

    case Instances.ensure(slug) do
      {:ok, pid} -> call_op(pid, {:install, args})
      # Its file is there but unreadable: installing would overwrite it.
      :ignore -> {:error, :corrupt_file}
      _not_started -> {:error, :unavailable}
    end
  end

  @doc """
  Applies the app's boot rule, given whether the engine has its container
  running (`:unknown` when it could not be asked). One halted by a shutdown
  that did not take the device down is resumed instead, which applies the
  same rule.
  """
  @spec boot_start(String.t(), boolean() | :unknown) :: :ok | {:error, term()}
  def boot_start(slug, running? \\ :unknown) do
    args = %{running?: running?}

    case command(slug, :boot_start, args) do
      {:error, :shutting_down} -> slug |> command(:resume, args) |> unsaved_ok()
      result -> unsaved_ok(result)
    end
  end

  @doc "Stops the app's container for a shutdown, keeping what the app wants for the next boot."
  @spec halt(String.t()) :: :ok | {:error, term()}
  def halt(slug), do: command(slug, :halt, %{})

  @doc """
  Updates `slug` to the store's current version. With `backup: true` the
  update op snapshots the stopped app into a backup staged here, kept even
  when the update then rolls back: it holds the version the user had. An
  update done whose backup could not be stored is `{:error,
  {:backup_not_stored, reason}}`; the update stands.
  """
  @spec update(String.t(), keyword()) :: {:ok, update_result()} | {:error, term()}
  def update(slug, opts) do
    with {:ok, installed} <- installed(slug),
         {:ok, target} <- store_target(slug),
         # Only the precheck matters here: whether the target can be applied.
         %{} <- Policy.plan(:update, %{config: target}, installed) do
      report_stage(opts, "validate_options", 5)

      args =
        opts
        |> Keyword.take([:job, :jobs_server, :backend, :engine_opts, :data_root, :socket])
        |> Map.new()
        |> Map.put(:config, target)

      if Keyword.get(opts, :backup, false),
        do: update_with_backup(slug, installed.config.version, args, opts),
        else: command(slug, :update, args)
    end
  end

  defp update_with_backup(slug, version, args, opts) do
    backups = Application.get_env(:vagus, :backups_module, Vagus.Backups)

    case backups.begin_partial("addon_#{slug}_#{version}", Keyword.take(opts, [:server])) do
      {:ok, handle} ->
        args = Map.merge(args, %{backup: true, staging_dir: handle.staging_dir})
        command(slug, :update, args) |> keep_backup(backups, handle, slug)

      {:error, reason} ->
        {:error, {:backup_failed, reason}}
    end
  end

  # A failed snapshot may have staged part of a file.
  defp keep_backup({:error, {:backup_failed, _reason}} = result, backups, handle, _slug) do
    backups.discard_partial(handle)
    result
  end

  # The update stands either way; the caller asked for a backup and must hear
  # that it has none.
  defp keep_backup({:ok, _update} = result, backups, handle, slug) do
    case backups.finish_partial(handle, [slug]) do
      {:ok, _backup_slug} -> result
      {:error, reason} -> {:error, {:backup_not_stored, reason}}
    end
  end

  # The update's own failure is the answer. One that failed before its
  # snapshot staged nothing, which `finish_partial` reports as `:not_staged`.
  defp keep_backup(result, backups, handle, slug) do
    case backups.finish_partial(handle, [slug]) do
      {:ok, _backup_slug} ->
        :ok

      {:error, {:not_staged, ^slug}} ->
        :ok

      {:error, reason} ->
        Logger.error("App #{slug}: the pre-update backup was not stored: #{inspect(reason)}")
    end

    result
  end

  defp installed(slug) do
    case info(slug) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_installed}
    end
  end

  # The store entry's own `config.slug` is the bare app slug; installed apps
  # run under the store slug, as `handle_install` renames it.
  defp store_target(slug) do
    case latest_config(slug) do
      {:ok, config} -> {:ok, %{config | slug: slug}}
      :error -> {:error, :not_in_store}
    end
  end

  @doc """
  The config an update of `slug` would install: the store's entry, else a
  default app's embedded config, which no store lists and which a newer
  firmware carries at a newer version.
  """
  @spec latest_config(String.t()) :: {:ok, Config.t()} | :error
  def latest_config(slug) do
    with :error <- entry_config(Store.get(slug)),
         {:error, _no_builtin} <- Units.builtin_config(slug),
         do: :error
  end

  defp entry_config({:ok, %{config: config}}), do: {:ok, config}
  defp entry_config(:error), do: :error

  defp report_stage(opts, stage, progress) do
    Vagus.Jobs.update(
      Keyword.get(opts, :job),
      [stage: stage, progress: progress],
      Keyword.get(opts, :jobs_server, Vagus.Jobs)
    )
  end

  @doc """
  Snapshots the app into `<staging_dir>/<slug>.tar.gz` by its own `backup`
  operation, which stops and starts a cold app itself: a caller that dies
  mid-backup cannot leave it stopped.
  """
  @spec backup(String.t(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def backup(slug, staging_dir, opts \\ []) do
    args = opts |> Keyword.take(@backup_opts) |> Map.new() |> Map.put(:staging_dir, staging_dir)
    command(slug, :backup, args)
  end

  @doc """
  Replaces the app's data with `staging_dir`, a sibling of its data dir, and
  its options with the backed-up `options`, by its own `restore` operation:
  stop, swap, set, and a start when `start?`. The options are validated against the config current in the op; `nil`, options
  it rejects, or an options write since the op began keep the current ones.
  The app is busy throughout, so no other operation, an uninstall included,
  runs on it mid-restore.
  """
  @spec restore(String.t(), Path.t(), map() | nil, boolean(), keyword()) ::
          :ok | {:error, term()}
  def restore(slug, staging_dir, options, start?, opts \\ []) do
    args =
      opts
      |> Keyword.take(@backup_opts)
      |> Map.new()
      |> Map.merge(%{staging_dir: staging_dir, options: options, start?: start?})

    unprotected(slug, fn -> command(slug, :restore, args) end)
  end

  # The container was started as asked, and boot would report a running app
  # as failed. The process has logged the save.
  defp unsaved_ok({:error, {:persist, _reason}}), do: :ok
  defp unsaved_ok(result), do: result

  # An operation can take as long as an image pull, so there is no call
  # deadline; each step inside it has its own.
  defp command(slug, op, args) do
    case whereis(slug) || heal(slug) do
      nil -> {:error, :not_found}
      pid -> call_op(pid, {op, args})
    end
  end

  defp call_op(pid, command) do
    case :gen_statem.call(pid, command, :infinity) do
      {:error, :not_installed} -> {:error, :not_found}
      result -> result
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp started(:ok, slug), do: {:ok, %{slug: slug}}
  defp started(error, _slug), do: error
end
