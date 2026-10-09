defmodule Vagus.App.Server do
  @moduledoc """
  One process per app: it holds every fact about the app and runs every
  operation on it. Its own file (`Vagus.App.File`) is the durable half; the
  per-start token, container id and IP live only here. A restarted process
  never asks the engine itself: its `Vagus.App.Orchestrator.up/1` makes the
  orchestrator inspect its container and send `boot_start` with the answer,
  and a wanted app whose container still runs is started again, which
  replaces the container under a fresh token (the old token died with the
  old process).

  States: `:new` (no file yet; it expires unless an install arrives),
  `:idle`, `{:busy, op}` and `:shutting_down`. The step an operation is on is
  deliberately not in the state: a state change replays postponed events and
  cancels the state timeout, and both must happen once, when the operation
  ends, not at every step.

  An operation is a run of steps planned by `Vagus.App.Policy`; this process
  only spawns each task step and interprets the effects `Policy.next/3`
  returns. Each step's input is built from the data current when that task
  is spawned, so options saved while an update pulls reach its start. A step
  that dies or overruns its deadline becomes an `{:error, :died | :timeout}`
  outcome on the same path as any other.

  Questions, settings writes and the app's own service and discovery posts
  are taken in every state, an operation in flight included. Container
  events and the native broker's `DOWN` wait until the operation ends.

  Registering a directory key links this process to a registry partition,
  and exits are trapped, so a partition's death arrives as an `EXIT`: it
  stops this process abnormally, and its restart registers again.
  """

  @behaviour :gen_statem

  require Logger

  alias Vagus.App.{Directory, Orchestrator, Policy, Steps}
  alias Vagus.App.File, as: AppFile
  alias Vagus.Core.{EventPusher, Events}
  alias Vagus.Discovery.Push

  @new_ttl_ms 60_000
  @probe_deadline_ms 10_000
  @ops [
    :install,
    :start,
    :stop,
    :restart,
    :update,
    :backup,
    :restore,
    :uninstall,
    :halt,
    :resume,
    :boot_start
  ]
  @questions [:info, :snapshot, :installed?, :identity, :ingress_target, :discovery_list]
  @settings [:ingress_panel, :watchdog, :ports, :boot, :auto_update, :protected]
  @redacted [:token, :token_hash, :ingress_token, :user_options, :services, :discovery]

  @spec child_spec(String.t()) :: Supervisor.child_spec()
  def child_spec(slug) do
    %{id: {__MODULE__, slug}, start: {__MODULE__, :start_link, [slug]}, restart: :transient}
  end

  @spec start_link(String.t()) :: :gen_statem.start_ret()
  def start_link(slug), do: :gen_statem.start_link(name(slug), __MODULE__, slug, [])

  defp name(slug), do: {:via, Registry, {Directory, {:slug, slug}}}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(slug) do
    Process.flag(:trap_exit, true)

    case AppFile.read(slug) do
      :error ->
        {:ok, :new, fresh(slug, nil), [{:state_timeout, deadline(:new), :expire}]}

      # Not a fresh slug: an install over it would replace what the user had.
      {:error, reason} ->
        Logger.error("App #{slug}: its file cannot be read (#{inspect(reason)}); not started")
        :ignore

      # Before any key or boot can reach the app, so a restore this process's
      # predecessor died in never leaves it starting on an empty data dir.
      # One that died after its swap restored the data but not the options;
      # its caller got no reply, so the restore failed and a retry redoes it.
      {:ok, saved} ->
        Steps.reconcile_asides(slug)
        {data, rewrite?} = claim_port(fresh(slug, saved), saved[:rewrite] == true)
        if rewrite?, do: rewritten(data), else: up(data)
    end
  end

  # A token minted for this file but not saved would be minted again at every
  # start, moving the app's ingress URL each time, so the start fails closed.
  # `:ignore` rather than a stop: a `:transient` restart that errors is
  # retried by the supervisor until its intensity takes every app down.
  defp rewritten(data) do
    case persist(data) do
      :ok ->
        up(data)

      {:error, reason} ->
        Logger.error(
          "App #{data.slug}: its file could not be rewritten (#{inspect(reason)}); not started"
        )

        :ignore
    end
  end

  defp up(data) do
    data = sync_keys(data, tl(Policy.keys(data)), [])
    Orchestrator.up(data.slug)
    {:ok, if(data.shutting_down, do: :shutting_down, else: :idle), data}
  end

  # A saved dynamic port another app already holds is not this app's: it is
  # dropped, and the next start's `port?` step picks one.
  defp claim_port(%{ingress_port: port} = data, rewrite?) when is_integer(port) do
    me = self()

    case Registry.register(Directory, {:ingress_port, port}, data.slug) do
      {:error, {:already_registered, other}} when other != me ->
        Logger.warning(
          "App #{data.slug}: its ingress port #{port} is held by another app; dropped"
        )

        {%{data | ingress_port: nil}, true}

      _registered ->
        {data, rewrite?}
    end
  end

  defp claim_port(data, rewrite?), do: {data, rewrite?}

  defp fresh(slug, saved) do
    slug
    |> Policy.init_data(saved)
    |> Map.merge(%{
      probe: nil,
      broker_ref: nil,
      retired: false,
      killed: [],
      shutting_down: shutdown?()
    })
  end

  @impl :gen_statem
  def handle_event(type, content, state, data),
    do: event(type, content, state, %{data | shutting_down: shutdown?()})

  defp event(:state_timeout, :expire, :new, _data), do: {:stop, :normal}

  defp event({:call, from}, {op, args} = command, state, data) when op in @ops do
    case Policy.admit(command, state) do
      :ok -> command(op, args, from, state, data)
      :noop -> {:keep_state_and_data, [{:reply, from, :ok}]}
      {:error, reason} -> {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Nothing to write before an install commits, nor once an uninstall began:
  # a write then would bring its file back.
  defp event({:call, from}, {:set, _changes}, _state, data)
       when data.config == nil or data.retired,
       do: {:keep_state_and_data, [{:reply, from, {:error, :not_installed}}]}

  # Validated and on disk before the reply, so a reboot right after it keeps
  # the change; an operation in flight reads the new values at its next step.
  defp event({:call, from}, {:set, changes}, state, data) do
    if Enum.all?(changes, fn {key, _value} -> key == :options or key in @settings end) do
      updated = Enum.reduce(changes, data, &put_setting/2)

      case AppFile.write(updated) do
        :ok -> run_effects(watchdog_flip(data, updated), state, updated, [{:reply, from, :ok}])
        {:error, _reason} -> {:keep_state_and_data, [{:reply, from, :error}]}
      end
    else
      {:keep_state_and_data, [{:reply, from, :error}]}
    end
  end

  defp event({:call, from}, {write, _name, _payload}, state, data)
       when write in [:provide_service, :add_discovery] and (state == :new or data.retired),
       do: {:keep_state_and_data, [{:reply, from, {:error, :unavailable}}]}

  # The app's own re-post is refused too, as upstream refuses any second
  # provider: the key is already held.
  defp event({:call, from}, {:provide_service, name, payload}, _state, data) do
    case Registry.register(Directory, {:service, name}, data.slug) do
      {:ok, _owner} ->
        {:keep_state, put_in(data.services[name], payload), [{:reply, from, :ok}]}

      {:error, {:already_registered, _pid}} ->
        {:keep_state_and_data, [{:reply, from, {:error, :already_provided}}]}
    end
  end

  defp event({:call, from}, {:withdraw_service, name}, _state, data) do
    case Map.pop(data.services, name) do
      {nil, _services} ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}

      {_payload, services} ->
        :ok = Registry.unregister(Directory, {:service, name})
        {:keep_state, %{data | services: services}, [{:reply, from, :ok}]}
    end
  end

  defp event({:call, from}, {:add_discovery, service, config}, _state, data) do
    messages = Map.values(data.discovery)
    fresh = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {outcome, message} = Policy.discover(messages, data.slug, service, config, fresh)

    if outcome == :new,
      do: {:ok, _owner} = Registry.register(Directory, {:discovery, message.uuid}, data.slug)

    # Queued before the reply so it is ahead of anything the caller does next.
    # `:existing` is a record Core already has; pushing it again is the
    # duplicate config flow the dedup prevents.
    if outcome != :existing, do: Push.notify(:post, message)

    data = put_in(data.discovery[message.uuid], message)
    {:keep_state, data, [{:reply, from, {:ok, message, outcome}}]}
  end

  defp event({:call, from}, {:delete_discovery, uuid}, _state, data) do
    case Map.pop(data.discovery, uuid) do
      {nil, _discovery} ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}

      {message, discovery} ->
        :ok = Registry.unregister(Directory, {:discovery, uuid})
        Push.notify(:delete, message)
        {:keep_state, %{data | discovery: discovery}, [{:reply, from, {:ok, message}}]}
    end
  end

  if Mix.env() == :test do
    # Tests authenticate as an installed app without starting its container.
    defp event({:call, from}, {:test_token, token}, state, data) when state != :new do
      drop = if data.token_hash, do: [{:token, data.token_hash}], else: []
      data = %{data | token: token, token_hash: Policy.hash(token)}
      {:keep_state, sync_keys(data, [{:token, data.token_hash}], drop), [{:reply, from, :ok}]}
    end
  end

  defp event({:call, from}, question, _state, data)
       when question in @questions or
              (is_tuple(question) and tuple_size(question) == 2 and
                 elem(question, 0) in [:service, :discovery]),
       do: {:keep_state_and_data, [{:reply, from, Policy.answer(question, data)}]}

  # A typo'd question from one caller must not crash-loop every app process.
  defp event({:call, from}, _unknown, _state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :unknown_question}}]}

  defp event(:info, {:done, ref, outcome}, state, %{run: %{ref: ref, task: pid}} = data) do
    Process.unlink(pid)
    settle(outcome, state, data)
  end

  defp event(:state_timeout, {:step, ref}, state, %{run: %{ref: ref, task: pid}} = data) do
    Logger.warning("App #{data.slug}: #{inspect(data.run.step)} overran its deadline")
    settle({:error, :timeout}, state, kill(pid, data))
  end

  # Only the reason's shape: a start task's arguments carry the app's token.
  defp event(:info, {:EXIT, pid, reason}, state, %{run: %{task: pid}} = data)
       when reason != :normal do
    Logger.warning("App #{data.slug}: #{inspect(data.run.step)} died: #{inspect(shape(reason))}")
    settle({:error, :died}, state, data)
  end

  defp event(:info, {:probe, ref, result}, state, %{probe: {pid, ref}} = data) do
    Process.unlink(pid)
    strike(result, state, data)
  end

  # Not the app answering badly, so not a strike.
  defp event(:info, {:EXIT, pid, reason}, state, %{probe: {pid, _ref}} = data)
       when reason != :normal,
       do: strike(:skip, state, data)

  defp event({:timeout, :probe_deadline}, ref, state, %{probe: {pid, ref}} = data),
    do: strike(:unhealthy, state, kill(pid, data))

  defp event(:info, {:docker_event, _payload}, {:busy, _op}, _data),
    do: {:keep_state_and_data, [:postpone]}

  defp event(:info, {:DOWN, ref, :process, _pid, _reason}, {:busy, _op}, %{broker_ref: ref}),
    do: {:keep_state_and_data, [:postpone]}

  defp event({:timeout, name}, _message, {:busy, _op}, _data)
       when name in [:retry, :settled, :probe],
       do: {:keep_state_and_data, [:postpone]}

  defp event(:info, {:docker_event, payload}, state, data) when state != :new,
    do: on_event(payload, state, data)

  defp event(:info, {:DOWN, ref, :process, _pid, reason}, state, %{broker_ref: ref} = data),
    do: on_event({:broker_down, reason}, state, %{data | broker_ref: nil})

  # For the container it was armed against: once an operation replaced that
  # one, or the user stopped the app, the restart is stale. Still current, it
  # may be running yet unhealthy, which is a restart too.
  defp event({:timeout, :retry}, {:retry, id}, :idle, %{wanted: :started} = data) do
    if data.shutting_down or id != data.container_id,
      do: :keep_state_and_data,
      else: begin_op(:start, %{retry: true}, nil, :idle, data)
  end

  defp event({:timeout, :settled}, :settled, state, data) when state != :new,
    do: on_event(:settled, state, data)

  defp event({:timeout, :probe}, :probe, :idle, data) do
    if data.container_id && data.watchdog == true && is_binary(data.config.watchdog),
      do: spawn_probe(data),
      else: :keep_state_and_data
  end

  defp event({:timeout, _name}, _message, _state, _data), do: :keep_state_and_data

  # Unlinking does not take back an EXIT already queued by a task that died
  # as it was killed. Every other task is unlinked before its result is used,
  # so a normal exit is the only one a finished task can still deliver;
  # anything else is the directory's partition going.
  defp event(:info, {:EXIT, pid, reason}, _state, data) do
    cond do
      pid in data.killed -> {:keep_state, %{data | killed: List.delete(data.killed, pid)}}
      reason == :normal -> :keep_state_and_data
      true -> {:stop, reason}
    end
  end

  # Stale step results, stale deadlines, late replies and stray messages.
  defp event(_type, _content, _state, _data), do: :keep_state_and_data

  # Nothing to stop yet, and no file: the process just ends.
  defp command(:halt, _args, from, {:busy, :install}, data) do
    kill(data.run.task, data)
    {:stop_and_reply, :normal, reply(data.run, {:error, :shutting_down}) ++ [{:reply, from, :ok}]}
  end

  defp command(:halt, args, from, {:busy, _op}, data) do
    parked = reply(data.run, {:error, :shutting_down})
    data = kill(data.run.task, data)
    begin_op(:halt, args, from, {:busy, :halt}, %{data | run: nil}, parked)
  end

  defp command(op, args, from, _state, data) when op in [:resume, :boot_start],
    do: boot(from, Map.get(args, :running?, :unknown), data)

  # Core GETs a message before acting on its DELETE, so the DELETEs are queued
  # now, ahead of the stop, and whatever the stopping app posts is refused.
  defp command(:uninstall, args, from, state, data) do
    Enum.each(Map.values(data.discovery), &Push.notify(:delete, &1))
    begin_op(:uninstall, args, from, state, %{data | retired: true})
  end

  defp command(op, args, from, state, data), do: begin_op(op, args, from, state, data)

  defp boot(from, reported, data) do
    case Policy.boot(data, running?(data, reported)) do
      :start ->
        begin_op(:start, %{}, from, :idle, data)

      :demote ->
        data = %{data | wanted: :stopped}
        persist(data)
        {:next_state, :idle, data, [{:reply, from, :ok}, {{:timeout, :retry}, :cancel}]}

      :none ->
        {:next_state, :idle, data, [{:reply, from, :ok}]}
    end
  end

  # What this process started and still holds is current. A container it only
  # heard of holds no token it issued; the engine knows nothing of a native
  # app, which runs in the BEAM.
  defp running?(data, reported) do
    up? = Policy.derive(:idle, data) in [:startup, :started]

    cond do
      up? and (data.token_hash != nil or data.broker_pid != nil) -> :managed
      up? -> true
      Steps.native?(data.config) -> false
      true -> reported
    end
  end

  defp begin_op(op, args, from, state, data, actions \\ []) do
    case Policy.plan(op, args, data) do
      {:error, reason} when state == :new ->
        {:stop_and_reply, :normal, actions ++ [{:reply, from, {:error, reason}}]}

      {:error, reason} ->
        {:keep_state_and_data, actions ++ [{:reply, from, {:error, reason}}]}

      run ->
        {data, effects} = Policy.next(%{run | from: from}, :begin, stop_probe(data))
        run_effects(effects, {:busy, op}, data, actions ++ cancel_retry(op))
    end
  end

  # A pending restart is stale once anything else starts or stops the app.
  defp cancel_retry(op) when op in [:start, :restart, :stop, :uninstall, :halt],
    do: [{{:timeout, :retry}, :cancel}]

  defp cancel_retry(_op), do: []

  defp settle(outcome, state, data) do
    {data, effects} = Policy.next(data.run, port_free(outcome, data), data)
    run_effects(effects, state, data)
  end

  # The directory is the arbiter of a dynamic port, so the claim is the
  # registration itself: two apps that picked one port cannot both pass.
  defp port_free({:ok, port}, %{run: %{step: {:port, _arg}}} = data) do
    key = {:ingress_port, port}
    me = self()

    case Registry.register(Directory, key, data.slug) do
      {:ok, _owner} -> {:ok, port}
      {:error, {:already_registered, ^me}} -> {:ok, port}
      {:error, {:already_registered, _other}} -> {:error, {:port_taken, key}}
    end
  end

  defp port_free(outcome, _data), do: outcome

  defp on_event(event, state, data) do
    {data, effects} = Policy.on_event(event, data)
    run_effects(effects, state, data)
  end

  defp strike(result, state, data) do
    {data, effects} = Policy.strike(result, %{data | probe: nil})
    run_effects(effects, state, data, [{{:timeout, :probe_deadline}, :cancel}])
  end

  defp run_effects(effects, state, data, actions \\ []) do
    case Enum.reduce_while(effects, {state, data, actions}, &effect/2) do
      {:exit, data, actions} -> {:stop_and_reply, :normal, replies(actions), data}
      {state, data, actions} -> {:next_state, state, data, actions}
    end
  end

  # An install that could not save its file has installed nothing: no reboot
  # would find it. Anywhere else the container already did what was asked,
  # so the op goes on and its reply carries the failure. Every save writes the
  # whole record, so a later one that succeeds clears it.
  defp effect(:persist, {st, %{run: run} = d, acts}) do
    case persist(d) do
      :ok ->
        {:cont, {st, %{d | run: %{run | unsaved: nil}}, acts}}

      {:error, reason} when run.op == :install ->
        {:halt, {:exit, d, acts ++ reply(run, {:error, {:persist, reason}})}}

      {:error, reason} ->
        {:cont, {st, %{d | run: %{run | unsaved: reason}}, acts}}
    end
  end

  # Acknowledged: an uninstall whose file is still there has removed nothing,
  # so a failed delete fails the op before the removal and keeps the app.
  defp effect(:delete_file, {st, d, acts}) do
    outcome =
      case AppFile.delete(d.slug) do
        :ok -> {:ok, nil}
        {:error, reason} -> {:error, {:delete_file, reason}}
      end

    {d, effects} = Policy.next(d.run, outcome, d)

    case Enum.reduce_while(effects, {st, d, acts}, &effect/2) do
      {:exit, _d, _acts} = exit -> {:halt, exit}
      acc -> {:cont, acc}
    end
  end

  defp effect(effect, acc), do: {:cont, apply_effect(effect, acc)}

  defp persist(data) do
    with {:error, reason} <- AppFile.write(data) do
      Logger.warning("App #{data.slug}: not saved (#{inspect(reason)})")
      {:error, reason}
    end
  end

  defp apply_effect({:step, step}, {st, d, acts}) do
    {d, step_actions} = spawn_step(d, step)
    {st, d, acts ++ step_actions}
  end

  defp apply_effect({:reply, term}, {st, d, acts}),
    do: {st, d, acts ++ reply(d.run, unsaved(term, d.run))}

  defp apply_effect({:keys, add, drop}, {st, d, acts}), do: {st, sync_keys(d, add, drop), acts}

  defp apply_effect({:timer, name, ms, msg}, {st, d, acts}),
    do: {st, d, acts ++ [{{:timeout, name}, deadline(name, ms), msg}]}

  defp apply_effect({:cancel, name}, {st, d, acts}),
    do: {st, d, acts ++ [{{:timeout, name}, :cancel}]}

  defp apply_effect(:monitor_broker, {st, d, acts}), do: {st, monitor_broker(d), acts}
  defp apply_effect(:idle, {_st, d, acts}), do: {:idle, %{d | run: nil, retired: false}, acts}

  defp apply_effect(:shutting_down, {_st, d, acts}),
    do: {:shutting_down, %{d | run: nil, retired: false}, acts}

  defp apply_effect(:exit, {_st, d, acts}), do: {:exit, d, acts}

  defp apply_effect({:emit, state}, {_st, d, _acts} = acc) do
    d.slug |> Events.app_state(state) |> EventPusher.push()
    acc
  end

  defp spawn_step(%{run: run} = data, {name, _arg} = step) do
    {ref, parent, steps} = {make_ref(), self(), steps()}
    input = Policy.task_input(step, data)
    pid = spawn_link(fn -> send(parent, {:done, ref, steps.run(name, input)}) end)

    {%{data | run: %{run | task: pid, ref: ref}},
     [{:state_timeout, deadline(name), {:step, ref}}]}
  end

  defp spawn_probe(data) do
    {ref, parent, probe} = {make_ref(), self(), probe()}
    input = Map.take(data, [:config, :user_options, :ip])

    pid =
      spawn_link(fn -> send(parent, {:probe, ref, probe.check(input.config.watchdog, input)}) end)

    {:keep_state, %{data | probe: {pid, ref}},
     [{{:timeout, :probe_deadline}, deadline(:probe_deadline), ref}]}
  end

  # An operation never runs beside a probe.
  defp stop_probe(%{probe: {pid, _ref}} = data), do: %{kill(pid, data) | probe: nil}
  defp stop_probe(data), do: data

  # A handful is enough: a queued EXIT is handled before anything sent later.
  defp kill(pid, data) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    %{data | killed: Enum.take([pid | data.killed], 8)}
  end

  defp reply(%{from: from}, term) when from != nil, do: [{:reply, from, term}]
  defp reply(_run, _term), do: []

  # A success whose record is not on disk would be undone by the next boot.
  defp unsaved(:ok, %{unsaved: reason}) when reason != nil, do: {:error, {:persist, reason}}

  defp unsaved({:ok, _}, %{op: :update, unsaved: reason}) when reason != nil,
    do: {:error, {:persist, reason}}

  defp unsaved(term, _run), do: term

  defp replies(actions), do: Enum.filter(actions, &match?({:reply, _from, _term}, &1))

  defp monitor_broker(%{broker_pid: pid} = data) when is_pid(pid),
    do: %{data | broker_ref: Process.monitor(pid)}

  defp monitor_broker(data), do: data

  # A `{key, value}` item carries its value (the DNS name its IP); every other
  # key carries the slug, so a lookup alone names the app.
  defp sync_keys(data, add, drop) do
    Enum.each(drop, &Registry.unregister(Directory, &1))

    Enum.each(add, fn
      {{_kind, _name} = key, value} -> register(data.slug, key, value)
      key -> register(data.slug, key, data.slug)
    end)

    data
  end

  defp register(slug, key, value) do
    me = self()

    case Registry.register(Directory, key, value) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, ^me}} ->
        {_new, _old} = Registry.update_value(Directory, key, fn _old -> value end)
        :ok

      # `foo_bar` and `foo-bar` share a DNS name: the second is refused.
      {:error, {:already_registered, _other}} ->
        Logger.warning("App #{slug}: #{inspect(key)} is held by another app; not registered")
    end
  end

  defp put_setting({:options, options}, data), do: Policy.put_options(data, options)
  defp put_setting({key, value}, data), do: Map.put(data, key, value)

  defp watchdog_flip(%{watchdog: same}, %{watchdog: same}), do: []

  defp watchdog_flip(_before, %{watchdog: true, container_id: id}) when id != nil,
    do: [Policy.probe_timer()]

  defp watchdog_flip(_before, _after), do: [{:cancel, :probe}]

  defp shutdown?, do: Vagus.Host.Shutdown.in_flight?()

  defp steps, do: Application.get_env(:vagus, :app_steps, Vagus.App.Steps)
  defp probe, do: Application.get_env(:vagus, :app_probe, Vagus.App.Probe)

  defp deadline(name), do: deadline(name, default_deadline(name))

  # Tests shorten deadlines and timers here, by name, to a value or by a
  # function of the default; production never sets it.
  defp deadline(name, default) do
    case Application.get_env(:vagus, :app_deadlines, %{}) do
      %{^name => scale} when is_function(scale, 1) -> scale.(default)
      %{^name => ms} -> ms
      _none -> default
    end
  end

  defp default_deadline(:new), do: @new_ttl_ms
  defp default_deadline(:probe_deadline), do: @probe_deadline_ms
  defp default_deadline(name), do: Policy.deadline(name)

  # Tokens, options, service payloads and discovery configs can carry
  # credentials, in the data and in an event being handled at a crash.
  @impl :gen_statem
  def format_status(status) do
    status
    |> Map.replace_lazy(:data, fn
      data when is_map(data) -> Map.new(data, &redact/1)
      data -> data
    end)
    |> Map.replace_lazy(:queue, fn queue -> Enum.map(queue, &redact_event/1) end)
    |> Map.replace_lazy(:postponed, fn queue -> Enum.map(queue, &redact_event/1) end)
    |> Map.replace_lazy(:reason, &shape/1)
    |> Map.replace(:log, [])
  end

  # A crash's reason holds the arguments of the frame that raised, this data
  # among them; its shape and where it happened are enough to read.
  defp shape({cause, [{_m, _f, _a, _loc} | _] = stack}),
    do: {shape(cause), Enum.map(stack, &frame/1)}

  defp shape(%{__exception__: true} = exception), do: exception.__struct__
  defp shape(reason) when is_atom(reason), do: reason

  defp shape(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp shape(_reason), do: :redacted

  defp frame({module, fun, args, location}) when is_list(args),
    do: {module, fun, length(args), location}

  defp frame(frame), do: frame

  defp redact({key, _value}) when key in @redacted, do: {key, :redacted}
  defp redact({:run, %{op: op, step: step}}), do: {:run, %{op: op, step: step}}
  defp redact(pair), do: pair

  defp redact_event({type, {:provide_service, name, _payload}}),
    do: {type, {:provide_service, name, :redacted}}

  defp redact_event({type, {:add_discovery, service, _config}}),
    do: {type, {:add_discovery, service, :redacted}}

  defp redact_event({type, {:set, changes}}) when is_list(changes),
    do: {type, {:set, Enum.map(changes, fn {key, _value} -> {key, :redacted} end)}}

  defp redact_event({type, {:restore, %{options: options} = args}}) when options != nil,
    do: {type, {:restore, %{args | options: :redacted}}}

  defp redact_event({type, {:test_token, _token}}), do: {type, {:test_token, :redacted}}
  defp redact_event(event), do: event
end
