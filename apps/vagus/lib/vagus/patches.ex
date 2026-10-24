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
  patches and a breaker skips them all once, recording why in
  `<root>/.skipped`, when the last such boot was never marked good. Good
  means the orchestrator's plan completed and `:good_after_ms` passed since
  the load; nothing else counts, since a supervisor giving up on crashing
  children also stops this server cleanly. A clean reboot inside that
  window trips the breaker once on the next boot: a false alarm, the safe
  one. Nerves' firmware validation cannot serve: every slot is flashed
  already validated.

  Code a load replaces stays loaded as old code until no process runs it,
  since purging it would kill those processes; such modules show `in_use`
  in `list/1`, and a load or unload that would replace them again is
  refused, because loading over old code purges it.
  """

  use GenServer

  require Logger

  @default_root "/data/vagus/patches"
  @name_pattern ~r/\A[A-Za-z0-9_-]+\z/
  # How late past `good_after_ms` a boot gets marked; a poll is one local call.
  @poll_ms 5_000
  # A crash-looping patch takes the node down within a minute; a longer wait
  # only makes a legitimate reboot soon after the load trip the breaker.
  @good_after_ms 60_000
  # Compiling one patch on a small board takes seconds; this bounds a hang.
  @compile_timeout_ms 60_000
  @call_timeout_ms @compile_timeout_ms + 5_000
  # A process leaves old code at its next call into the module, so seconds
  # in practice; two minutes before giving up on it.
  @purge_ms 5_000
  @purge_tries 24
  @boot_file ".boot"
  @skipped_file ".skipped"

  @type result :: :ok | {:error, term()}
  @type boot_status ::
          :not_started | :running | {:done, %{String.t() => result()}} | {:skipped, String.t()}
  @type patch :: %{
          name: String.t(),
          enabled?: boolean(),
          modules: [module()],
          loaded?: boolean(),
          last_result: result() | nil,
          in_use: [module()],
          purged?: boolean()
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
  the first file that fails; modules loaded before the failure stay loaded
  and are recorded, since compiling loads them.
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
  Starts loading every enabled patch, each on its own so one failure never
  stops the rest, unless the breaker trips (`{:ok, :skipped}`). Once per VM
  boot, even across a restart of this server: a second pass would find its
  own unmarked `.boot` and trip the breaker. `boot_status/1` follows it.
  """
  @spec boot_load(keyword()) :: {:ok, :started | :skipped} | {:error, term()}
  def boot_load(opts \\ []), do: call(opts, :boot_load)

  @spec boot_status(keyword()) :: boot_status() | {:error, term()}
  def boot_status(opts \\ []), do: call(opts, :boot_status)

  @doc "The breaker's records, and whether the boot load is still running."
  @spec status(keyword()) ::
          %{boot: map() | nil, skipped: map() | nil, running?: boolean()} | {:error, term()}
  def status(opts \\ []), do: call(opts, :status)

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
    # So a supervisor's shutdown reaches terminate/2, and a compile's crash
    # is its result rather than this server's.
    Process.flag(:trap_exit, true)

    state = %{
      root: opts |> Keyword.get(:root, @default_root) |> Path.expand(),
      good_after_ms: Keyword.get(opts, :good_after_ms, @good_after_ms),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      purge_ms: Keyword.get(opts, :purge_ms, @purge_ms),
      purge_tries: Keyword.get(opts, :purge_tries, @purge_tries),
      compile_timeout_ms: Keyword.get(opts, :compile_timeout_ms, @compile_timeout_ms),
      boot_complete?: Keyword.get(opts, :boot_complete?),
      patches: %{},
      in_use: %{},
      purge_timer?: false,
      boot: :not_started,
      boot_task: nil,
      pending_since: nil,
      good_ready: false
    }

    {:ok, resume(state)}
  end

  @impl GenServer
  def handle_call(:list, _from, state), do: {:reply, list_patches(state), state}

  def handle_call({:load, name}, _from, state) do
    known = known_modules(state, name)
    {result, modules} = load_files(name, state.root, known, state.compile_timeout_ms)
    state = state |> remember(name, modules, with_ok(result)) |> release(modules)
    {:reply, result, state}
  end

  def handle_call({:unload, name}, _from, state) do
    {reply, state} = unload_patch(name, state)
    {:reply, reply, state}
  end

  def handle_call({:enable, name}, _from, state),
    do: {:reply, with_patch(name, state, &File.touch(enabled_path(&1))), state}

  def handle_call({:disable, name}, _from, state),
    do: {:reply, with_patch(name, state, &rm_marker/1), state}

  def handle_call(:boot_load, _from, %{boot: :not_started} = state) do
    state = start_boot(state)
    {:reply, boot_reply(state.boot), state}
  end

  def handle_call(:boot_load, _from, state), do: {:reply, boot_reply(state.boot), state}

  def handle_call(:boot_status, _from, state), do: {:reply, state.boot, state}

  def handle_call(:status, _from, state) do
    status = %{
      boot: ok_or_nil(read_json(state.root, @boot_file)),
      skipped: ok_or_nil(read_json(state.root, @skipped_file)),
      running?: state.boot == :running
    }

    {:reply, status, state}
  end

  def handle_call(:mark_good, _from, state) do
    case write_good(state.root) do
      :ok -> {:reply, :ok, %{state | pending_since: nil, good_ready: true}}
      error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info(:check_good, %{pending_since: nil} = state), do: {:noreply, state}

  def handle_info(:check_good, state) do
    state = latch_good(state)
    state = if state.good_ready, do: try_write_good(state), else: state
    if state.pending_since, do: Process.send_after(self(), :check_good, state.poll_ms)
    {:noreply, state}
  end

  def handle_info(:retry_purge, state) do
    in_use = Enum.reduce(state.in_use, %{}, &retry_purge/2)
    {:noreply, schedule_purge(%{state | in_use: in_use, purge_timer?: false})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{boot_task: {ref, names}} = state) do
    case :persistent_term.get(marker(state.root), nil) do
      {:done, results, loaded, at} ->
        {:noreply, adopt(state, results, loaded, at)}

      _running ->
        Logger.error("Patches: boot load died (#{inspect(reason)})")
        results = Map.new(names, &{&1, {:error, {:boot_task, reason}}})
        at = System.monotonic_time(:millisecond)
        :persistent_term.put(marker(state.root), {:done, results, %{}, at})
        {:noreply, adopt(state, results, %{}, at)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Only a latched boot: any stop before it, `:shutdown` included, may be a
  # supervisor giving up on what the patches broke.
  @impl GenServer
  def terminate(_reason, %{good_ready: true, pending_since: since} = state) when since != nil,
    do: try_write_good(state)

  def terminate(_reason, _state), do: :ok

  # Keyed by root, and in `:persistent_term` because it must outlive this
  # server within one VM boot: a restarted server that ran `boot_load`
  # again would trip the breaker on the `.boot` its predecessor armed.
  defp marker(root), do: {__MODULE__, :boot_done, root}

  defp resume(state) do
    case :persistent_term.get(marker(state.root), nil) do
      nil ->
        state

      {:skipped, reason} ->
        %{state | boot: {:skipped, reason}}

      {:running, pid, names} ->
        %{state | boot: :running, boot_task: {Process.monitor(pid), names}}

      {:done, results, loaded, at} ->
        adopt(state, results, loaded, at)
    end
  end

  defp boot_reply({:skipped, _reason}), do: {:ok, :skipped}
  defp boot_reply(_boot), do: {:ok, :started}

  defp start_boot(state) do
    names = state |> list_patches() |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.name)

    case {names, previous_boot(state.root)} do
      # Nothing enabled is nothing to protect.
      {[], _previous} ->
        write_boot(state.root, [], %{}, true)
        finish_boot(state, {:done, %{}})

      {_names, {:not_good, previous}} ->
        finish_boot(state, trip(state.root, previous))

      {names, _good_or_none} ->
        arm_and_load(state, names)
    end
  end

  defp finish_boot(state, {:skipped, _} = boot) do
    :persistent_term.put(marker(state.root), boot)
    %{state | boot: boot}
  end

  defp finish_boot(state, {:done, results}) do
    at = System.monotonic_time(:millisecond)
    :persistent_term.put(marker(state.root), {:done, results, %{}, at})
    %{state | boot: {:done, results}}
  end

  # Fails closed: a `.boot` that does not say this boot is loading would let
  # a VM-killing patch load on every boot.
  defp arm_and_load(state, names) do
    case write_boot(state.root, names, %{}, false) do
      :ok ->
        start_task(state, names)

      {:error, reason} ->
        Logger.error("Patches: none loaded; the boot record could not be armed")
        finish_boot(state, {:done, Map.new(names, &{&1, {:error, {:arm, reason}}})})
    end
  end

  # Unlinked so this server's crash does not take a half-done load with it;
  # a restarted server finds the task through the marker. It waits for `:go`
  # so its `:done` marker can never be overwritten by the `:running` one.
  defp start_task(state, names) do
    cfg = Map.take(state, [:root, :compile_timeout_ms])

    {:ok, pid} =
      Task.start(fn ->
        receive do
          :go -> run_boot(names, cfg)
        end
      end)

    ref = Process.monitor(pid)
    :persistent_term.put(marker(state.root), {:running, pid, names})
    send(pid, :go)
    %{state | boot: :running, boot_task: {ref, names}}
  end

  defp run_boot(names, cfg) do
    Process.flag(:trap_exit, true)

    outcomes =
      Map.new(names, fn name ->
        {name, load_files(name, cfg.root, [], cfg.compile_timeout_ms)}
      end)

    results = Map.new(outcomes, fn {name, {result, _}} -> {name, with_ok(result)} end)
    write_boot(cfg.root, names, results, false)
    loaded = Map.new(outcomes, fn {name, {_, modules}} -> {name, modules} end)
    at = System.monotonic_time(:millisecond)
    :persistent_term.put(marker(cfg.root), {:done, results, loaded, at})
  end

  # `at` is monotonic and from the marker, so a restarted server keeps the
  # original delay; `.boot`'s wall-clock `loaded_at` may predate NTP.
  defp adopt(state, results, loaded, at) do
    state =
      Enum.reduce(loaded, state, fn {name, modules}, state ->
        state |> remember(name, modules, results[name]) |> release(modules)
      end)

    state = %{state | boot: {:done, results}, boot_task: nil}

    case read_json(state.root, @boot_file) do
      {:ok, %{"good" => false, "patches" => [_ | _]}} ->
        Process.send_after(self(), :check_good, state.poll_ms)
        %{state | pending_since: at}

      _good_or_unreadable ->
        state
    end
  end

  defp latch_good(%{good_ready: true} = state), do: state

  defp latch_good(state) do
    elapsed = System.monotonic_time(:millisecond) - state.pending_since
    %{state | good_ready: elapsed >= state.good_after_ms and boot_complete?(state)}
  end

  defp try_write_good(state) do
    case write_good(state.root) do
      :ok ->
        Logger.info("Patches: boot marked good")
        %{state | pending_since: nil}

      {:error, reason} ->
        Logger.error("Patches: could not mark the boot good (#{inspect(reason)}); retrying")
        state
    end
  end

  # Resolved per call rather than captured in init/1: the orchestrator
  # starts after this server, and restarts on its own.
  defp boot_complete?(%{boot_complete?: fun}) do
    if fun, do: fun.() == true, else: Vagus.App.Orchestrator.complete?()
  catch
    :exit, _reason -> false
  end

  defp previous_boot(root) do
    case read_json(root, @boot_file) do
      {:error, :enoent} -> :none
      {:ok, %{"good" => true}} -> :good
      {:ok, previous} -> {:not_good, previous}
      {:error, reason} -> {:not_good, %{"unreadable" => inspect(reason)}}
    end
  end

  defp trip(root, previous) do
    Logger.error(
      "Patches: none loaded this boot; the previous boot that loaded " <>
        "#{inspect(previous["patches"])} was never marked good (#{Path.join(root, @skipped_file)})"
    )

    reason = "previous boot not marked good"
    write_json(root, @skipped_file, %{"at" => now(), "reason" => reason, "previous" => previous})
    # Good at once: the skip is the recovery, so the next boot loads the
    # enabled patches again.
    write_boot(root, [], %{}, true)
    {:skipped, reason}
  end

  defp with_ok({:ok, _modules}), do: :ok
  defp with_ok(error), do: error

  defp load_files(name, root, known, timeout) do
    {result, modules} =
      with :ok <- valid_name(name),
           dir = Path.join(root, name),
           :ok <- exists(dir, :not_found),
           :ok <- exists(Path.join(dir, "NOTES.md"), :no_notes),
           [_ | _] = sources <- sources(dir),
           :ok <- old_code_free(known ++ parse_modules(dir)) do
        compile_bounded(sources, timeout)
      else
        [] -> {{:error, :no_sources}, []}
        error -> {error, []}
      end

    log_load(name, result, modules)
    {result, modules}
  end

  # Loading over old code purges it, killing whatever still runs it.
  defp old_code_free(modules) do
    case modules |> Enum.uniq() |> Enum.reject(&:code.soft_purge/1) do
      [] -> :ok
      in_use -> {:error, {:in_use, in_use}}
    end
  end

  defp compile_bounded(sources, timeout) do
    task = Task.async(fn -> compile_files(sources) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {{:error, {:exit, reason}}, Enum.flat_map(sources, &loaded_from/1)}
      nil -> {{:error, :timeout}, Enum.flat_map(sources, &loaded_from/1)}
    end
  end

  defp compile_files(sources) do
    Enum.reduce_while(sources, {{:ok, []}, []}, fn file, {_result, loaded} ->
      case compile_file(file) do
        {:ok, modules} ->
          {:cont, {{:ok, loaded ++ modules}, loaded ++ modules}}

        error ->
          {:halt, {error, Enum.uniq(loaded ++ loaded_from(file))}}
      end
    end)
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

  # The patch's source runs at compile time, so whatever it raises, throws
  # or exits is that file's result. Compiling loads the modules; the code
  # they replace becomes old, left to release/2. Diagnostics are captured so
  # a failure carries its reason instead of printing to stderr.
  # Compiling a patch's sources is the point; its name passed valid_name/1.
  # sobelow_skip ["RCE.CodeModule"]
  defp compile_file(file) do
    {compiled, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Code.compile_file(file)}
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason)}
        end
      end)

    case compiled do
      {:ok, pairs} ->
        {:ok, Enum.map(pairs, &elem(&1, 0))}

      {:error, message} ->
        errors = for %{severity: :error, message: m} <- diagnostics, do: m
        {:error, {:compile, Path.basename(file), Enum.join(errors ++ [message], "\n")}}
    end
  end

  defp unload_patch(name, state) do
    with :ok <- valid_name(name),
         [_ | _] = modules <- known_modules(state, name),
         :ok <- old_code_free(modules),
         {:ok, restored} <- restore_all(modules) do
      Logger.warning("Patches: #{name} unloaded, restoring #{inspect(modules)}")
      entry = %{modules: modules, loaded?: false, last_result: last_result(state, name)}
      {{:ok, restored}, state |> put_in([:patches, name], entry) |> release(restored)}
    else
      [] -> {{:error, :not_found}, state}
      {:error, {:restore, _mod, _reason}, _restored} = error -> restore_failed(error, state)
      error -> {error, state}
    end
  end

  defp restore_failed({:error, reason, restored}, state) do
    Logger.error("Patches: restore failed (#{inspect(reason)}); restored #{inspect(restored)}")
    {{:error, reason}, release(state, restored)}
  end

  defp restore_all(modules) do
    Enum.reduce_while(modules, {:ok, []}, fn mod, {:ok, done} ->
      case restore(mod) do
        :ok -> {:cont, {:ok, done ++ [mod]}}
        {:error, reason} -> {:halt, {:error, {:restore, mod, reason}, done}}
      end
    end)
  end

  # The release's `.beam` is found on the code path whatever is loaded now.
  defp restore(mod) do
    case :code.get_object_code(mod) do
      {^mod, bin, file} ->
        case :code.load_binary(mod, file, bin) do
          {:module, ^mod} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :error ->
        :code.delete(mod)
        :ok
    end
  end

  defp release(state, modules) do
    in_use =
      modules
      |> Enum.uniq()
      |> Enum.reduce(state.in_use, fn mod, in_use ->
        if :code.soft_purge(mod),
          do: Map.delete(in_use, mod),
          else: Map.put(in_use, mod, state.purge_tries)
      end)

    schedule_purge(%{state | in_use: in_use})
  end

  defp retry_purge({mod, 0}, acc), do: Map.put(acc, mod, 0)

  defp retry_purge({mod, tries}, acc) do
    cond do
      :code.soft_purge(mod) ->
        acc

      tries == 1 ->
        Logger.error("Patches: old code of #{inspect(mod)} still running; left loaded")
        Map.put(acc, mod, 0)

      true ->
        Map.put(acc, mod, tries - 1)
    end
  end

  defp schedule_purge(%{purge_timer?: false} = state) do
    if Enum.any?(state.in_use, fn {_mod, tries} -> tries > 0 end) do
      Process.send_after(self(), :retry_purge, state.purge_ms)
      %{state | purge_timer?: true}
    else
      state
    end
  end

  defp schedule_purge(state), do: state

  defp list_patches(state) do
    for name <- patch_names(state.root) do
      dir = Path.join(state.root, name)
      modules = known_modules(state, name)
      in_use = Enum.filter(modules, &Map.has_key?(state.in_use, &1))

      %{
        name: name,
        enabled?: File.exists?(enabled_path(dir)),
        modules: modules,
        loaded?: loaded?(state, name),
        last_result: last_result(state, name),
        in_use: in_use,
        purged?: in_use == []
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

  defp parse_modules(dir), do: dir |> sources() |> Enum.flat_map(&parse_file/1) |> Enum.uniq()

  # A file that failed part way may have loaded the modules before it.
  defp loaded_from(file), do: file |> parse_file() |> Enum.filter(&:code.is_loaded/1)

  # Best effort, before any load has said which modules a patch defines.
  # The names are interned: the sources are root's, and compiling them
  # would intern them anyway. A file that does not parse defined nothing.
  # Patch names are checked by valid_name/1 before any file is listed.
  # sobelow_skip ["Traversal.FileModule"]
  defp parse_file(file) do
    with {:ok, body} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(body) do
      ast |> defined_modules(nil) |> Enum.uniq()
    else
      _unreadable -> []
    end
  end

  defp defined_modules({:defmodule, _meta, [name, opts]}, parent) when is_list(opts) do
    case module_name(name, parent) do
      nil -> defined_modules(opts, parent)
      mod -> [mod | defined_modules(opts, mod)]
    end
  end

  defp defined_modules({form, _meta, args}, parent) when is_list(args),
    do: defined_modules([form | args], parent)

  defp defined_modules({left, right}, parent), do: defined_modules([left, right], parent)

  defp defined_modules(list, parent) when is_list(list),
    do: Enum.flat_map(list, &defined_modules(&1, parent))

  defp defined_modules(_ast, _parent), do: []

  # Nesting prefixes the parent, as the compiler does, unless the name is
  # spelled from `Elixir.`.
  defp module_name({:__aliases__, _meta, [:"Elixir" | _] = parts}, _parent),
    do: if(Enum.all?(parts, &is_atom/1), do: Module.concat(parts))

  defp module_name({:__aliases__, _meta, parts}, parent) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(List.wrap(parent) ++ parts)
  end

  defp module_name(name, _parent) when is_atom(name) and name not in [nil, true, false], do: name
  defp module_name(_name, _parent), do: nil

  defp sources(dir), do: dir |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort()

  defp with_patch(name, state, fun) do
    with :ok <- valid_name(name),
         dir = Path.join(state.root, name),
         :ok <- exists(dir, :not_found) do
      fun.(dir)
    end
  end

  # Patch names are checked by valid_name/1 in with_patch/3.
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

  defp write_good(root) do
    with {:ok, boot} <- read_json(root, @boot_file),
         :ok <- write_json(root, @boot_file, Map.put(boot, "good", true)) do
      if boot["patches"] not in [nil, []], do: clear_skipped(root)
      :ok
    else
      {:error, :enoent} -> {:error, :no_boot}
      error -> error
    end
  end

  # A later patch-loading boot marked good means the skip is history.
  # Fixed file names under the configured root.
  # sobelow_skip ["Traversal.FileModule"]
  defp clear_skipped(root) do
    case File.rm(Path.join(root, @skipped_file)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> Logger.error("Patches: could not clear #{@skipped_file}: #{inspect(error)}")
    end
  end

  defp ok_or_nil({:ok, data}), do: data
  defp ok_or_nil(_error), do: nil

  # Fixed file names under the configured root.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_json(root, file) do
    with {:ok, body} <- File.read(Path.join(root, file)) do
      case Jason.decode(body) do
        {:ok, %{} = data} -> {:ok, data}
        _ -> {:error, :unreadable}
      end
    end
  end

  # Renamed into place, so a power cut never leaves a torn record the
  # breaker would read as a bad boot.
  # Fixed file names under the configured root.
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
        File.rm(tmp)
        Logger.error("Patches: could not write #{path}: #{inspect(error)}")
        error
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
