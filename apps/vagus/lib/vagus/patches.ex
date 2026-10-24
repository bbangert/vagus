defmodule Vagus.Patches do
  @moduledoc """
  Hot patches to the running BEAM, on the agent-dev-board flavor only. A
  patch is a directory `<root>/<name>/` holding `NOTES.md` (what it changes
  and why; a patch without one is refused), whole module sources in `*.ex`,
  and an `enabled` marker that has the boot load it. Any module may be
  replaced, Vagus's own included. An agent drives it over distribution:

      :erpc.call(board, Vagus.Patches, :load, ["dns_fix"])

  A patch that kills the VM would kill it on every boot, and heart would
  reboot into it forever, so `<root>/.boot` records each boot that loaded
  patches and a breaker skips them all once when the last such boot was
  never marked good. Good means the orchestrator's plan completed and the
  node stayed up `:good_after_ms` after the load, or this server stopped
  cleanly. Nerves' firmware validation cannot serve: every slot is flashed
  already validated.
  """

  use GenServer

  require Logger

  @default_root "/data/vagus/patches"
  @name_pattern ~r/\A[A-Za-z0-9_-]+\z/
  @poll_ms 5_000
  # Compiling several patches on a small board takes seconds.
  @call_timeout_ms 60_000
  @boot_file ".boot"
  @skipped_file ".skipped"

  @type result :: :ok | {:error, term()}
  @type patch :: %{
          name: String.t(),
          enabled?: boolean(),
          modules: [module()],
          loaded?: boolean(),
          last_result: result() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &Vagus.Flavor.agent?/0) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @spec list(keyword()) :: [patch()] | {:error, term()}
  def list(opts \\ []), do: call(opts, :list)

  @doc """
  Compiles and loads every `*.ex` of the patch, in name order, stopping at
  the first file that fails; modules from the files before it stay loaded,
  since compiling loads them.
  """
  @spec load(String.t(), keyword()) :: {:ok, [module()]} | {:error, term()}
  def load(name, opts \\ []), do: call(opts, {:load, name})

  @doc """
  Puts back the release's code for each module of the patch, or removes a
  module the release does not have.
  """
  @spec unload(String.t(), keyword()) :: {:ok, [module()]} | {:error, term()}
  def unload(name, opts \\ []), do: call(opts, {:unload, name})

  @spec enable(String.t(), keyword()) :: :ok | {:error, term()}
  def enable(name, opts \\ []), do: call(opts, {:enable, name})

  @spec disable(String.t(), keyword()) :: :ok | {:error, term()}
  def disable(name, opts \\ []), do: call(opts, {:disable, name})

  @doc """
  Loads every enabled patch, each on its own so one failure never stops the
  rest, unless the breaker trips. Once per server: a repeat answers the
  first result, since a second pass would find its own unmarked `.boot` and
  trip the breaker.
  """
  @spec boot_load(keyword()) ::
          {:ok, %{String.t() => result()}} | {:ok, :skipped} | {:error, term()}
  def boot_load(opts \\ []), do: call(opts, :boot_load)

  @spec mark_good(keyword()) :: :ok | {:error, term()}
  def mark_good(opts \\ []), do: call(opts, :mark_good)

  # Dist callers get a value back, never an exit, whether the server is
  # absent (appliance flavor) or slow.
  defp call(opts, msg) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      msg,
      Keyword.get(opts, :timeout, @call_timeout_ms)
    )
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {{:nodedown, _}, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl GenServer
  def init(opts) do
    # So a supervisor's shutdown reaches terminate/2, which marks the boot good.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       root: opts |> Keyword.get(:root, @default_root) |> Path.expand(),
       good_after_ms: Keyword.get(opts, :good_after_ms, 60_000),
       poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
       boot_complete?: Keyword.get(opts, :boot_complete?),
       patches: %{},
       boot_reply: nil,
       pending_since: nil
     }}
  end

  @impl GenServer
  def handle_call(:list, _from, state), do: {:reply, list_patches(state), state}

  def handle_call({:load, name}, _from, state) do
    {reply, state} = load_patch(name, state)
    {:reply, reply, state}
  end

  def handle_call({:unload, name}, _from, state) do
    {reply, state} = unload_patch(name, state)
    {:reply, reply, state}
  end

  def handle_call({:enable, name}, _from, state),
    do: {:reply, with_patch(name, state, &File.touch(enabled_path(&1))), state}

  def handle_call({:disable, name}, _from, state),
    do: {:reply, with_patch(name, state, &rm_marker/1), state}

  def handle_call(:boot_load, _from, %{boot_reply: nil} = state) do
    {reply, state} = run_boot_load(state)
    {:reply, reply, %{state | boot_reply: reply}}
  end

  def handle_call(:boot_load, _from, state), do: {:reply, state.boot_reply, state}

  def handle_call(:mark_good, _from, state),
    do: {:reply, write_good(state.root), %{state | pending_since: nil}}

  @impl GenServer
  def handle_info(:check_good, %{pending_since: nil} = state), do: {:noreply, state}

  def handle_info(:check_good, state) do
    elapsed = System.monotonic_time(:millisecond) - state.pending_since

    if elapsed >= state.good_after_ms and boot_complete?(state) do
      write_good(state.root)
      Logger.info("Patches: boot marked good")
      {:noreply, %{state | pending_since: nil}}
    else
      Process.send_after(self(), :check_good, state.poll_ms)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A clean stop means the patches did not take the VM down.
  @impl GenServer
  def terminate(reason, %{pending_since: since} = state) when since != nil do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: write_good(state.root)
  end

  def terminate(_reason, _state), do: :ok

  # Resolved per call rather than captured in init/1: the orchestrator
  # starts after this server.
  defp boot_complete?(%{boot_complete?: nil}), do: Vagus.App.Orchestrator.complete?()

  defp boot_complete?(%{boot_complete?: fun}), do: fun.() == true

  defp run_boot_load(state) do
    case previous_boot(state.root) do
      {:not_good, previous} -> {trip(state.root, previous), state}
      _good_or_none -> load_enabled(state)
    end
  end

  # Paths under the configured root; patch names are checked by valid_name/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp previous_boot(root) do
    case File.read(Path.join(root, @boot_file)) do
      {:error, :enoent} ->
        :none

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"good" => true}} -> :good
          {:ok, %{} = previous} -> {:not_good, previous}
          _ -> {:not_good, %{"unreadable" => "not JSON"}}
        end

      {:error, reason} ->
        {:not_good, %{"unreadable" => inspect(reason)}}
    end
  end

  defp trip(root, previous) do
    Logger.error(
      "Patches: none loaded this boot; the previous boot that loaded " <>
        "#{inspect(previous["patches"])} was never marked good (#{Path.join(root, @skipped_file)})"
    )

    write_json(root, @skipped_file, %{
      "at" => now(),
      "reason" => "previous boot not marked good",
      "previous" => previous
    })

    # Good at once: the skip is the recovery, so the next boot loads the
    # enabled patches again.
    write_boot(root, [], %{}, true)
    {:ok, :skipped}
  end

  defp load_enabled(state) do
    case state |> list_patches() |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.name) do
      [] ->
        write_boot(state.root, [], %{}, true)
        {{:ok, %{}}, state}

      names ->
        # Before the first load, so a VM that dies mid-load trips the breaker.
        write_boot(state.root, names, %{}, false)

        {results, state} =
          Enum.reduce(names, {%{}, state}, fn name, {acc, state} ->
            {result, state} = load_patch(name, state)
            {Map.put(acc, name, with_ok(result)), state}
          end)

        write_boot(state.root, names, results, false)
        Process.send_after(self(), :check_good, state.poll_ms)
        {{:ok, results}, %{state | pending_since: System.monotonic_time(:millisecond)}}
    end
  end

  defp with_ok({:ok, _modules}), do: :ok
  defp with_ok(error), do: error

  defp load_patch(name, state) do
    {result, modules} =
      try do
        compile_patch(name, state.root)
      rescue
        exception -> {{:error, {:raise, Exception.message(exception)}}, []}
      catch
        kind, reason -> {{:error, {kind, reason}}, []}
      end

    log_load(name, result, modules)
    {result, remember(state, name, modules, with_ok(result))}
  end

  defp log_load(name, {:ok, modules}, _loaded),
    do: Logger.warning("Patches: #{name} loaded, replacing #{inspect(modules)}")

  defp log_load(name, error, loaded),
    do: Logger.warning("Patches: #{name} failed (#{inspect(error)}); loaded #{inspect(loaded)}")

  defp remember(state, _name, [], {:error, reason})
       when reason in [:invalid_name, :not_found, :no_notes, :no_sources],
       do: state

  defp remember(state, name, modules, result) do
    entry = %{
      modules: Enum.uniq(modules ++ (get_in(state.patches, [name, :modules]) || [])),
      loaded?: modules != [] or loaded?(state, name),
      last_result: result
    }

    put_in(state, [:patches, name], entry)
  end

  defp compile_patch(name, root) do
    with :ok <- valid_name(name),
         dir = Path.join(root, name),
         :ok <- exists(dir, :not_found),
         :ok <- exists(Path.join(dir, "NOTES.md"), :no_notes),
         [_ | _] = sources <- sources(dir) do
      Enum.reduce_while(sources, {{:ok, []}, []}, fn file, {{:ok, _}, loaded} ->
        case compile_file(file) do
          {:ok, modules} -> {:cont, {{:ok, loaded ++ modules}, loaded ++ modules}}
          error -> {:halt, {error, loaded}}
        end
      end)
    else
      [] -> {{:error, :no_sources}, []}
      error -> {error, []}
    end
  end

  # Compiling loads the modules; the explicit load records the patch's file
  # as their origin and drops whatever older version lingered. Diagnostics are
  # captured so a failure carries its reason instead of printing to stderr.
  # Compiling a patch's sources is the point; its name passed valid_name/1.
  # sobelow_skip ["RCE.CodeModule"]
  defp compile_file(file) do
    {compiled, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Code.compile_file(file)}
        rescue
          exception -> {:error, Exception.message(exception)}
        end
      end)

    case compiled do
      {:ok, pairs} ->
        Enum.reduce_while(pairs, {:ok, []}, fn {mod, bin}, {:ok, mods} ->
          :code.purge(mod)

          case :code.load_binary(mod, String.to_charlist(file), bin) do
            {:module, ^mod} -> {:cont, {:ok, mods ++ [mod]}}
            {:error, reason} -> {:halt, {:error, {:load, mod, reason}}}
          end
        end)

      {:error, message} ->
        errors = for %{severity: :error, message: m} <- diagnostics, do: m
        {:error, {:compile, Path.basename(file), Enum.join(errors ++ [message], "\n")}}
    end
  end

  defp unload_patch(name, state) do
    with :ok <- valid_name(name),
         modules when modules != [] <- known_modules(state, name) do
      Enum.each(modules, &restore/1)
      Logger.warning("Patches: #{name} unloaded, restoring #{inspect(modules)}")
      entry = %{modules: modules, loaded?: false, last_result: last_result(state, name)}
      {{:ok, modules}, put_in(state, [:patches, name], entry)}
    else
      [] -> {{:error, :not_found}, state}
      error -> {error, state}
    end
  end

  # The release's `.beam` is found on the code path whatever is loaded now.
  defp restore(mod) do
    :code.purge(mod)

    case :code.get_object_code(mod) do
      {^mod, bin, file} -> :code.load_binary(mod, file, bin)
      :error -> :code.delete(mod)
    end
  end

  defp list_patches(state) do
    for name <- patch_names(state.root) do
      dir = Path.join(state.root, name)

      %{
        name: name,
        enabled?: File.exists?(enabled_path(dir)),
        modules: known_modules(state, name),
        loaded?: loaded?(state, name),
        last_result: last_result(state, name)
      }
    end
  end

  defp patch_names(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(valid_name(&1) == :ok and File.dir?(Path.join(root, &1))))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp known_modules(state, name) do
    case state.patches do
      %{^name => %{modules: [_ | _] = modules}} -> modules
      _ -> parse_modules(Path.join(state.root, name))
    end
  end

  defp loaded?(state, name), do: get_in(state.patches, [name, :loaded?]) || false
  defp last_result(state, name), do: get_in(state.patches, [name, :last_result])

  # Best effort, before any load has said which modules a patch defines.
  # The names are interned: the sources are root's, and compiling them
  # would intern them anyway.
  # Paths under the configured root; patch names are checked by valid_name/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp parse_modules(dir) do
    for file <- sources(dir),
        {:ok, body} = File.read(file),
        [_, mod] <- Regex.scan(~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)/m, body),
        uniq: true,
        do: Module.concat([mod])
  end

  defp sources(dir), do: dir |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort()

  defp with_patch(name, state, fun) do
    with :ok <- valid_name(name),
         dir = Path.join(state.root, name),
         :ok <- exists(dir, :not_found) do
      fun.(dir)
    end
  end

  # Paths under the configured root; patch names are checked by valid_name/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm_marker(dir) do
    case File.rm(enabled_path(dir)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  defp enabled_path(dir), do: Path.join(dir, "enabled")

  defp valid_name(name) when is_binary(name),
    do: if(Regex.match?(@name_pattern, name), do: :ok, else: {:error, :invalid_name})

  defp valid_name(_name), do: {:error, :invalid_name}

  defp exists(path, error), do: if(File.exists?(path), do: :ok, else: {:error, error})

  defp write_boot(root, names, results, good?) do
    write_json(root, @boot_file, %{
      "loaded_at" => now(),
      "patches" => names,
      "results" => Map.new(results, fn {name, result} -> {name, encode_result(result)} end),
      "good" => good?
    })
  end

  defp encode_result(:ok), do: "ok"
  defp encode_result(error), do: inspect(error)

  # Paths under the configured root; patch names are checked by valid_name/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_good(root) do
    path = Path.join(root, @boot_file)

    with {:ok, body} <- File.read(path),
         {:ok, %{} = boot} <- Jason.decode(body) do
      write_json(root, @boot_file, Map.put(boot, "good", true))
    else
      {:error, :enoent} -> {:error, :no_boot}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unreadable}
    end
  end

  # Renamed into place, so a power cut never leaves a torn record the
  # breaker would read as a bad boot.
  # Paths under the configured root; patch names are checked by valid_name/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_json(root, file, data) do
    path = Path.join(root, file)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(tmp, Jason.encode!(data)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        Logger.error("Patches: could not write #{path}: #{inspect(error)}")
        error
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
