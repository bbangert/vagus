defmodule Vagus.App.Policy do
  @moduledoc """
  Upstream Supervisor's rules for an app, as pure functions the orchestrator,
  the app process and the router apply: boot, services and discovery, the
  reported state, the restart ladder, and the step runner (`plan/3`,
  `next/3`) that turns each operation into task steps plus a closed set of
  effects. Minting a token is the one impure act; it is a decision, not an
  action, so it is a local step here rather than a task.

  Each task's input is built by `task_input/2` from the data current when that
  task is spawned, not from a copy taken when its operation began: options
  saved while an update pulls reach that update's start step.

  `on_event/2` and `strike/2` read `data.shutting_down`, which the process
  keeps in step with `Vagus.Host.Shutdown.in_flight?/0`.
  """

  alias Vagus.Addon.{Config, OptionsSchema}
  alias Vagus.App.Steps

  @type message :: %{uuid: String.t(), addon: String.t(), service: String.t(), config: map()}
  @type caller :: :supervisor | {:addon, map()} | term()

  # `GET /services` lists these whether or not anything provides them.
  @known_services ~w(mqtt)

  @doc """
  What boot does with one app, by whether its container runs: `:managed` is
  one this process started and still holds; `true`, `false` and `:unknown`
  are the engine's answer for one it did not start. Only an app recorded
  `:started` is touched. A container running without this process's token
  is started again whatever the boot mode, since nothing it holds
  authenticates any more; a stopped one starts when its effective boot is
  `auto`, and is otherwise recorded `:stopped` so its state stops claiming it
  runs. With no answer from the engine nothing is demoted.
  """
  @spec boot(map(), :managed | boolean() | :unknown) :: :start | :demote | :none
  def boot(%{wanted: wanted, config: config} = data, running?),
    do: boot(%{state: wanted, config: config, boot: data.boot}, running?)

  def boot(%{state: :started}, true), do: :start

  def boot(%{state: :started} = entry, running?) when running? in [false, :unknown] do
    cond do
      Config.effective_boot(entry.config, entry[:boot]) == "auto" -> :start
      running? == :unknown -> :none
      true -> :demote
    end
  end

  def boot(_entry, _running?), do: :none

  @doc """
  Upstream compares discovery messages by `(app, service)` only, so a repeat
  post never mints a second uuid: Core would see a second config flow rather
  than an update. `:new` takes `fresh_uuid`; `:existing` (same config) means
  Core already has the record and must not be told again; `:updated` keeps
  the uuid and replaces the config.
  """
  @spec discover([message()], String.t(), String.t(), map(), String.t()) ::
          {:new | :existing | :updated, message()}
  def discover(existing, slug, service, config, fresh_uuid) do
    case Enum.find(existing, &(&1.addon == slug and &1.service == service)) do
      nil -> {:new, %{uuid: fresh_uuid, addon: slug, service: service, config: config}}
      %{config: ^config} = message -> {:existing, message}
      message -> {:updated, %{message | config: config}}
    end
  end

  @doc "Only an app whose config gives it the `provide` role may publish or withdraw a service."
  @spec may_provide?(caller(), String.t()) :: boolean()
  def may_provide?({:addon, %{services_role: roles}}, service),
    do: Map.get(roles, service) == "provide"

  def may_provide?(_caller, _service), do: false

  @doc "Core always; an app when it declares any role (`provide`, `want`, `need`) for it."
  @spec may_read_service?(caller(), String.t()) :: boolean()
  def may_read_service?(:supervisor, _service), do: true

  def may_read_service?({:addon, %{services_role: roles}}, service),
    do: Map.has_key?(roles, service)

  def may_read_service?(_caller, _service), do: false

  @doc "The `GET /services` list, from the `{service, provider_slug}` pairs provided now."
  @spec services_view([{String.t(), String.t()}]) :: [map()]
  def services_view(provided) do
    Enum.map(@known_services, fn service ->
      providers = for {^service, slug} <- provided, do: slug
      %{slug: service, available: providers != [], providers: providers}
    end)
  end

  @type step :: {atom(), term()}
  @type outcome :: :begin | {:ok, term()} | {:error, term()}
  @type effect ::
          {:step, step()}
          | {:reply, term()}
          | {:keys, [term()], [term()]}
          | :persist
          | {:emit, atom()}
          | {:timer, atom(), non_neg_integer(), term()}
          | {:cancel, atom()}
          | :monitor_broker
          | :delete_file
          | :idle
          | :shutting_down
          | :exit

  @max_attempts 5
  @strikes_to_restart 2
  @probe_interval_ms 120_000
  # The ladder resets once a restart stays up, not when it merely starts, or a
  # container that dies a second after each start never runs out.
  @settled_ms 120_000

  @deadlines %{
    pull: 1_800_000,
    port: 15_000,
    start: 120_000,
    stop: 60_000,
    halt_stop: 40_000,
    snapshot: 600_000,
    exec_hook: 120_000,
    remove_app: 120_000,
    reclaim_image: 60_000
  }

  # A caller's backend, data root, engine socket and jobs server reach every
  # task step.
  @engine_overrides [:backend, :data_root, :socket, :jobs_server]

  @persisted ~w(config wanted user_options ingress_token ingress_port ingress_panel watchdog ports
                 boot auto_update protected)a

  @doc "The process's data for `slug`, from its saved file (`nil` before install)."
  @spec init_data(String.t(), map() | nil) :: map()
  def init_data(slug, saved) do
    %{
      slug: slug,
      config: nil,
      wanted: :stopped,
      user_options: %{},
      ingress_token: nil,
      ingress_port: nil,
      ingress_panel: false,
      watchdog: false,
      ports: %{},
      boot: nil,
      auto_update: nil,
      protected: true,
      container_id: nil,
      ip: nil,
      token: nil,
      token_hash: nil,
      broker_pid: nil,
      last_event: nil,
      attempt: 0,
      strikes: 0,
      services: %{},
      discovery: %{},
      released: [],
      gone: false,
      run: nil,
      shutting_down: false
    }
    |> Map.merge(Map.take(saved || %{}, @persisted))
  end

  @doc "Readers hash a presented token the same way to find its key."
  @spec hash(String.t()) :: binary()
  def hash(token), do: :crypto.hash(:sha256, token)

  @doc "The DNS name: `foo_bar` and `foo-bar` share one, so the second is refused."
  @spec dns_name(String.t()) :: String.t()
  def dns_name(slug), do: slug |> String.replace("_", "-") |> String.downcase()

  @doc """
  Upstream's five states from the last container event. An observed event
  always wins; with none, a stopped app is `stopped`, and a process still in
  `:new` has nothing to report.
  """
  @spec derive(atom() | tuple(), map()) :: :startup | :started | :stopped | :error | :unknown
  def derive(:new, _data), do: :unknown
  def derive(_state, %{last_event: event}), do: from_event(event)

  defp from_event(nil), do: :stopped
  defp from_event(:stopped), do: :stopped
  defp from_event({:running, true}), do: :startup
  defp from_event({:running, false}), do: :started
  defp from_event(health) when health in [:healthy, :unhealthy], do: :started
  defp from_event({:exited, 0}), do: :stopped
  defp from_event({:exited, _code}), do: :error
  defp from_event({:failed, _reason}), do: :error

  @doc """
  A container event or the native broker's `DOWN` (`{:broker_down, reason}`),
  or `:settled`. An event for a container this process stopped or cleaned up
  is late and ignored, as is one for a container other than the current one.
  A start seen while no container is known is the app's container running
  without this process having started it (the process restarted, or the
  engine reports it after a reconnect): it is adopted. Upstream restarts on
  any exit, a clean one included; a `once` app's clean exit is its
  completion instead.
  """
  @spec on_event(term(), map()) :: {map(), [effect()]}
  def on_event(%{id: id} = event, data) do
    if id in data.released, do: {data, []}, else: container_event(event, data)
  end

  def on_event({:broker_down, _reason}, %{container_id: id} = data) when id != nil,
    do: died(data, {:exited, :down})

  def on_event(:settled, data), do: {%{data | attempt: 0}, []}
  def on_event(_event, data), do: {data, []}

  defp container_event(%{action: "start", id: id}, %{container_id: nil} = data)
       when is_binary(id),
       do: observe(%{data | container_id: id}, {:running, false}, [])

  defp container_event(%{id: id}, %{container_id: current} = data) when id != current,
    do: {data, []}

  defp container_event(%{action: "die"} = event, data),
    do: died(data, {:exited, Map.get(event, :exit_code)})

  defp container_event(%{action: "health_status: healthy"}, data),
    do: observe(data, :healthy, [])

  defp container_event(%{action: "health_status: unhealthy"}, data) do
    {data, effects} = observe(data, :unhealthy, [])
    retry(data, effects)
  end

  defp container_event(_event, data), do: {data, []}

  defp died(data, event) do
    {data, effects} = drop_run_keys(data)
    effects = effects ++ [{:cancel, :probe}, {:cancel, :settled}]
    {data, effects} = observe(data, event, effects)

    if data.config.startup == "once" and event == {:exited, 0},
      do: {data, effects},
      else: retry(data, effects)
  end

  @doc """
  Whether an app that went down comes back. A native app with boot `auto` is
  always revived, with no cap and no watchdog flag: it is the MQTT broker
  every other app leans on, and nothing outside the BEAM restarts it. A
  container app needs its watchdog flag and an attempt left. No time window:
  the ladder is the only bound.
  """
  @spec restart?(map(), boolean()) :: boolean()
  def restart?(_data, true = _shutting_down), do: false
  def restart?(%{wanted: wanted}, _shutting_down) when wanted != :started, do: false

  def restart?(data, _shutting_down) do
    if Steps.native?(data.config),
      do: Config.effective_boot(data.config, data.boot) == "auto",
      else: data.watchdog == true and data.attempt < @max_attempts
  end

  @doc """
  The wait before the next restart, by attempts already made: upstream's first
  try is at once, then 10 s doubling. Native: 5 s, which lets the listener
  socket go, then every 30 s.
  """
  @spec backoff(map()) :: non_neg_integer()
  def backoff(%{config: config, attempt: attempt}) do
    cond do
      Steps.native?(config) -> if attempt == 0, do: 5_000, else: 30_000
      attempt == 0 -> 0
      true -> 10_000 * 2 ** (attempt - 1)
    end
  end

  defp retry(data, effects) do
    if restart?(data, data.shutting_down) do
      timer = {:timer, :retry, backoff(data), {:retry, data.container_id}}
      {%{data | attempt: data.attempt + 1}, effects ++ [timer]}
    else
      {data, effects}
    end
  end

  @doc """
  One URL-probe result (`:healthy`, `:unhealthy`, or `:skip` when the probe
  could not be run). Two misses in a row are one restart on the crash ladder,
  so one slow answer is not a restart; once that is spent the app reports `error` and the probe
  stops.
  """
  @spec strike(:healthy | :unhealthy | :skip, map()) :: {map(), [effect()]}
  def strike(:healthy, data), do: {%{data | strikes: 0}, [probe_timer()]}
  def strike(:skip, data), do: {data, [probe_timer()]}

  def strike(:unhealthy, %{strikes: strikes} = data) when strikes + 1 < @strikes_to_restart,
    do: {%{data | strikes: strikes + 1}, [probe_timer()]}

  def strike(:unhealthy, data) do
    data = %{data | strikes: 0}

    if restart?(data, data.shutting_down),
      do: retry(data, []),
      else: observe(data, {:failed, :unhealthy}, [])
  end

  @doc "The next URL-probe tick."
  @spec probe_timer() :: effect()
  def probe_timer, do: {:timer, :probe, @probe_interval_ms, :probe}

  @doc """
  Whether a command is taken in this state. Only `halt` pre-empts an
  operation, since a shutdown cannot wait out an image pull; `resume` is what leaves `:shutting_down`. `:noop` asks for
  an `:ok` reply and nothing else.
  """
  @spec admit(atom() | tuple(), term()) :: :ok | :noop | {:error, term()}
  def admit(command, state), do: do_admit(command_op(command), state)

  defp command_op({op, _args}), do: op
  defp command_op(op), do: op

  defp do_admit(:install, :new), do: :ok
  defp do_admit(_op, :new), do: {:error, :not_installed}
  defp do_admit(:install, _state), do: {:error, :already_installed}
  defp do_admit(:halt, :shutting_down), do: :noop
  defp do_admit(:resume, :shutting_down), do: :ok
  defp do_admit(_op, :shutting_down), do: {:error, :shutting_down}
  defp do_admit(:resume, _state), do: :noop
  defp do_admit(:halt, {:busy, :halt}), do: {:error, :busy}
  defp do_admit(:halt, _state), do: :ok
  defp do_admit(_op, {:busy, _op_running}), do: {:error, :busy}
  defp do_admit(_op, :idle), do: :ok

  @doc "The identity a token grants: the app's API roles and service roles."
  @spec identity(Config.t()) :: map()
  def identity(config) do
    # A `services:` entry without a role grants nothing rather than failing.
    services_role =
      config.services
      |> Enum.flat_map(fn s ->
        case String.split(s, ":", parts: 2) do
          [service, role] -> [{service, role}]
          [_service] -> []
        end
      end)
      |> Map.new()

    %{
      slug: config.slug,
      services_role: services_role,
      auth_api: config.auth_api,
      discovery: config.discovery,
      hassio_api: config.hassio_api,
      hassio_role: config.hassio_role,
      homeassistant_api: config.homeassistant_api
    }
  end

  @doc """
  Every directory key the data implies; a `{key, value}` item carries a
  value. A host-network app has no DNS record, and only a dynamically
  assigned ingress port is unique to its app.
  """
  @spec keys(map()) :: [term()]
  def keys(data) do
    [{:slug, data.slug}] ++
      if(data.token_hash, do: [{:token, data.token_hash}], else: []) ++
      dns_keys(data) ++
      ingress_keys(data) ++
      Enum.map(Map.keys(data.services), &{{:service, &1}, data.slug}) ++
      Enum.map(Map.keys(data.discovery), &{{:discovery, &1}, data.slug})
  end

  defp dns_keys(%{ip: ip, config: %{host_network: false}, slug: slug}) when is_binary(ip),
    do: [{{:dns, dns_name(slug)}, ip}]

  defp dns_keys(_data), do: []

  defp ingress_keys(%{config: %Config{} = config} = data) do
    token =
      if config.ingress and data.ingress_token,
        do: [{:ingress_token, hash(data.ingress_token)}],
        else: []

    port =
      if config.ingress_port == 0 and is_integer(data.ingress_port),
        do: [{:ingress_port, data.ingress_port}],
        else: []

    token ++ port
  end

  defp ingress_keys(_data), do: []

  @doc """
  A reader's question. The ingress target of a host-network app names
  `:host_network` rather than an address: which host address answers needs a
  connect, and the app process never blocks.
  """
  @spec answer(term(), map()) :: term()
  def answer(question, %{config: nil}), do: uninstalled(question)
  def answer(:info, data), do: {:ok, snapshot(data)}
  def answer(:snapshot, data), do: snapshot(data)
  def answer(:installed?, _data), do: true
  def answer(:identity, data), do: {:ok, identity(data.config)}
  def answer(:ingress_target, data), do: ingress_target(data)
  def answer({:service, name}, data), do: Map.fetch(data.services, name)
  def answer({:discovery, uuid}, data), do: Map.fetch(data.discovery, uuid)
  def answer(:discovery_list, data), do: Map.values(data.discovery)
  def answer(_question, _data), do: {:error, :unknown_question}

  defp uninstalled(:installed?), do: false
  defp uninstalled(:discovery_list), do: []
  defp uninstalled(:ingress_target), do: {:error, :not_found}
  defp uninstalled(_question), do: :error

  defp ingress_target(data) do
    with {:ok, port} <- ingress_port(data),
         {:ok, ip} <- ingress_ip(data) do
      {:ok, {ip, port, data.config.ingress_stream == true}}
    end
  end

  defp ingress_port(%{ingress_port: port}) when is_integer(port) and port > 0, do: {:ok, port}

  defp ingress_port(%{config: %{ingress_port: port}}) when is_integer(port) and port > 0,
    do: {:ok, port}

  defp ingress_port(_data), do: {:error, :no_ingress_port}

  defp ingress_ip(%{config: %{host_network: true}}), do: {:ok, :host_network}
  defp ingress_ip(%{ip: ip}) when is_binary(ip), do: {:ok, ip}
  defp ingress_ip(_data), do: {:error, :no_container_ip}

  @doc """
  The app's saved facts plus its reported `state`, the shape
  `Addon.Info.render` and the router read.
  """
  @spec snapshot(map()) :: map()
  def snapshot(data),
    do: data |> Map.take(@persisted) |> Map.put(:state, derive(:idle, data))

  @doc """
  The run for `op`, or why it cannot begin: an update needs a newer version
  whose schema still accepts the saved options. `next(run, :begin, data)`
  starts it.
  """
  @spec plan(atom(), map(), map()) :: map() | {:error, term()}
  def plan(op, args, data) do
    with :ok <- precheck(op, args, data) do
      %{op: op, args: args, steps: steps(op, args, data), step: nil, acc: acc(op, data)}
      |> Map.merge(%{task: nil, ref: nil, from: nil, unsaved: nil})
    end
  end

  defp precheck(:install, %{config: config}, _data) do
    if Config.reserved_slug?(config.slug), do: {:error, {:reserved_slug, config.slug}}, else: :ok
  end

  defp precheck(:update, %{config: %{version: version}}, %{config: %{version: version}}),
    do: {:error, :no_update_available}

  defp precheck(:update, %{config: target}, data) do
    case OptionsSchema.effective(target.schema, target.options, data.user_options) do
      {:ok, _options} -> :ok
      {:error, reason} -> {:error, {:invalid_options, reason}}
    end
  end

  defp precheck(_op, _args, _data), do: :ok

  # Every update branch that rolls back, a failed snapshot's included, needs
  # the version it started from.
  defp acc(:update, data), do: %{old: data.config}
  defp acc(_op, _data), do: %{}

  # `:port?` and `:start?` are resolved against the data current when they
  # are reached, so an update's start sees the committed config.
  defp steps(:install, _args, _data), do: [{:pull, nil}, {:port?, nil}, {:commit, nil}]
  defp steps(:start, _args, _data), do: start_steps()
  defp steps(:stop, _args, _data), do: [{:stop, nil}]
  defp steps(:restart, _args, _data), do: [{:stop, nil} | start_steps()]

  defp steps(:uninstall, _args, _data),
    do: [{:stop, nil}, {:delete_file, nil}, {:remove_app, nil}]

  defp steps(:halt, _args, _data), do: [{:halt_stop, nil}]

  defp steps(:update, args, _data) do
    snapshot = if args[:backup], do: [{:snapshot, nil}], else: []

    [{:pull, nil}, {:stop, nil}] ++
      snapshot ++ [{:commit, nil}, {:start?, nil}, {:reclaim_image, nil}]
  end

  defp steps(:backup, _args, data) do
    cond do
      data.config.backup == "cold" -> [{:stop, nil}, {:snapshot, nil}, {:start?, nil}]
      Steps.native?(data.config) or not running?(data) -> [{:snapshot, nil}]
      true -> hook(data, :pre) ++ [{:snapshot, nil}] ++ hook(data, :post)
    end
  end

  defp start_steps, do: [{:port?, nil}, {:mint_token, nil}, {:start, nil}]

  defp hook(%{config: config}, :pre) when is_binary(config.backup_pre), do: [{:exec_hook, :pre}]

  defp hook(%{config: config}, :post) when is_binary(config.backup_post),
    do: [{:exec_hook, :post}]

  defp hook(_data, _which), do: []

  defp running?(%{container_id: id, last_event: event}),
    do: id != nil and from_event(event) in [:startup, :started]

  @doc """
  Applies one outcome of the current step (or `:begin`) and moves on: local
  steps run here, and the effects end in one task step to spawn or in the
  op's end. An outcome no clause plans for fails the op rather than raising.
  """
  @spec next(map(), outcome(), map()) :: {map(), [effect()]}
  def next(run, outcome, data) do
    before = derive(:idle, data)
    data = %{data | run: run}
    {data, effects} = if outcome == :begin, do: advance(data, []), else: settle(outcome, data)
    {data, emit(before, data, effects)}
  end

  defp observe(data, event, effects) do
    before = derive(:idle, data)
    data = %{data | last_event: event}
    {data, emit(before, data, effects)}
  end

  defp emit(before, data, effects) do
    case derive(:idle, data) do
      ^before -> effects
      now -> [{:emit, now} | effects]
    end
  end

  defp advance(%{run: %{steps: []}} = data, effects), do: finish(data, effects)

  defp advance(%{run: %{steps: [step | rest]}} = data, effects) do
    case expand(step, data) do
      [^step] -> run_step(step, put_steps(data, rest), effects)
      steps -> advance(put_steps(data, steps ++ rest), effects)
    end
  end

  defp expand({:port?, _}, data) do
    config = data.config || data.run.args.config

    if config.ingress and config.ingress_port == 0 and data.ingress_port == nil,
      do: [{:port, nil}],
      else: []
  end

  defp expand({:start?, _}, data),
    do: if(data.run.acc[:was_running], do: start_steps(), else: [])

  # Native apps mint no token: they run in the BEAM and never call the API.
  defp expand({:mint_token, _} = step, data),
    do: if(Steps.native?(data.config), do: [], else: [step])

  defp expand(step, _data), do: [step]

  defp run_step({:mint_token, _}, data, effects) do
    token = :crypto.strong_rand_bytes(56) |> Base.encode16(case: :lower)
    drop = if data.token_hash, do: [{:token, data.token_hash}], else: []
    data = %{data | token: token, token_hash: hash(token)}
    advance(data, effects ++ [{:keys, [{:token, data.token_hash}], drop}])
  end

  defp run_step({:commit, _}, %{run: %{op: :install, args: %{config: config}}} = data, effects) do
    token = data.ingress_token || Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    data = %{
      data
      | config: config,
        ingress_token: token,
        wanted: data.run.args[:wanted] || :stopped
    }

    token_key = Enum.filter(ingress_keys(data), &match?({:ingress_token, _}, &1))
    keys = if token_key == [], do: [], else: [{:keys, token_key, []}]
    advance(data, effects ++ keys ++ [:persist])
  end

  defp run_step({:commit, _}, %{run: %{args: %{config: config}}} = data, effects),
    do: reconfigure(data, config, data.ingress_port, effects)

  defp run_step({:rollback_config, _}, data, effects),
    do: reconfigure(data, data.run.acc.old, data.ingress_port, effects)

  # Run by the process itself, which feeds its result back as this step's
  # outcome.
  defp run_step({:delete_file, _} = step, data, effects),
    do: {put_in(data.run.step, step), effects ++ [:delete_file]}

  defp run_step(step, data, effects) do
    {data, before} = before_task(step, data)
    {put_in(data.run.step, step), effects ++ before ++ [{:step, step}]}
  end

  # The ingress keys follow the config in both directions, and a dynamic port
  # outlives only a config that still asks for one: `ingress_target/1`
  # prefers it over the config's own port. A rollback never takes back a port
  # the commit dropped, since another app may hold it by then; the start that
  # follows picks a fresh one.
  defp reconfigure(data, config, port, effects) do
    before = ingress_keys(data)
    data = %{data | config: config, ingress_port: if(config.ingress_port == 0, do: port)}
    now = ingress_keys(data)
    keys = if before == now, do: [], else: [{:keys, now -- before, before -- now}]
    advance(data, effects ++ keys ++ [:persist])
  end

  # The credential goes before the container: a stopped app's token must not
  # outlive it, and nothing it posts while stopping should land.
  defp before_task({:stop, nil}, %{run: %{op: :uninstall}} = data) do
    drop = Enum.map(tl(keys(data)), &key/1)
    data = %{data | token: nil, token_hash: nil, ip: nil, wanted: :stopped}
    data = %{data | services: %{}, discovery: %{}}
    {data, [{:keys, [], drop} | cancel_timers()]}
  end

  defp before_task({name, _}, data) when name in [:stop, :halt_stop] do
    {data, effects} = drop_run_keys(data)
    data = if data.run.op == :stop, do: %{data | wanted: :stopped}, else: data
    {data, effects ++ cancel_timers()}
  end

  defp before_task(_step, data), do: {data, []}

  defp drop_run_keys(data) do
    drop = Enum.map(dns_keys(data), &key/1)
    drop = if data.token_hash, do: [{:token, data.token_hash} | drop], else: drop
    effects = if drop == [], do: [], else: [{:keys, [], drop}]
    {%{data | token: nil, token_hash: nil, ip: nil}, effects}
  end

  # Only the last few: a late event trails its container by moments, not by
  # many containers.
  defp release(%{container_id: nil} = data), do: data

  defp release(data),
    do: %{data | container_id: nil, released: Enum.take([data.container_id | data.released], 4)}

  defp key({{_kind, _name} = key, _value}), do: key
  defp key(key), do: key

  defp cancel_timers, do: [{:cancel, :probe}, {:cancel, :settled}, {:cancel, :retry}]

  defp settle(outcome, %{run: %{op: op, step: {name, arg}}} = data),
    do: on_outcome(op, name, arg, outcome, data)

  defp settle(outcome, %{run: run} = data),
    do: fail(data, {:unplanned, run.op, run.step, outcome}, [])

  # The one recovery after a dead or timed-out step that touched the
  # container: its state is unknown, so it is removed by name. It always ends
  # the op as a failure, then the restart rule.
  defp on_outcome(_op, :stop, :by_name, _outcome, data),
    do: fail(put_acc(release(data), :cleaned, true), data.run.acc.cause, [])

  defp on_outcome(_op, :pull, _, {:ok, _ref}, data), do: advance(data, [])
  defp on_outcome(:install, :pull, _, {:error, reason}, data), do: fail(data, reason, [])
  defp on_outcome(:update, :pull, _, {:error, reason}, data), do: fail(data, {:pull, reason}, [])

  defp on_outcome(op, :port, _, {:ok, port}, data) when is_integer(port) do
    persist = if op == :install, do: [], else: [:persist]
    advance(%{data | ingress_port: port}, [{:keys, [{:ingress_port, port}], []} | persist])
  end

  defp on_outcome(_op, :port, _, {:error, reason}, data),
    do: fail(data, {:ingress_port, reason}, [])

  defp on_outcome(_op, :start, _, {:ok, %{container_id: _} = fact}, data) do
    {data, effects} = started(data, fact)

    case data.run.acc do
      %{cause: cause} ->
        finish(put_acc(put_steps(data, []), :result, rolled_back(cause)), effects)

      _acc ->
        advance(data, effects)
    end
  end

  defp on_outcome(:update, :start, _, {:error, reason}, %{run: %{acc: %{cause: _}}} = data) do
    {data, effects} = drop_run_keys(data)
    fail(%{data | last_event: {:failed, reason}}, {:rollback_failed, reason}, effects)
  end

  # Only a committed target is rolled back; a start of the old version that
  # fails, after a failed snapshot, fails like any start.
  defp on_outcome(:update, :start, _, {:error, reason}, %{config: config} = data)
       when config != data.run.acc.old do
    steps = [{:rollback_config, nil} | start_steps()]
    advance(data |> put_acc(:cause, reason) |> put_steps(steps), [])
  end

  defp on_outcome(op, :start, _, {:error, reason}, data) do
    {data, effects} = drop_run_keys(data)
    data = %{data | last_event: {:failed, reason}}

    cond do
      reason in [:died, :timeout] -> cleanup(data, reason, effects)
      op == :backup -> finish(data, effects)
      true -> fail(data, reason, effects)
    end
  end

  defp on_outcome(_op, :stop, nil, {:ok, %{was_running: was_running}}, data) do
    data = put_acc(%{release(data) | last_event: :stopped}, :was_running, was_running)
    advance(data, [])
  end

  defp on_outcome(_op, :stop, nil, {:error, reason}, data), do: cleanup(data, {:stop, reason}, [])

  defp on_outcome(:update, :snapshot, _, {:ok, _path}, data), do: advance(data, [])

  defp on_outcome(:update, :snapshot, _, {:error, reason}, data) do
    data = put_acc(data, :result, {:error, {:backup_failed, reason}})
    advance(put_steps(data, [{:start?, nil}]), [])
  end

  defp on_outcome(:backup, :snapshot, _, {status, _} = result, data) when status in [:ok, :error],
    do: advance(put_acc(data, :result, result), [])

  defp on_outcome(:backup, :exec_hook, :pre, {:ok, _}, data), do: advance(data, [])

  defp on_outcome(:backup, :exec_hook, :pre, {:error, reason}, data),
    do: fail(data, {:backup_pre_failed, reason}, [])

  defp on_outcome(:backup, :exec_hook, :post, _outcome, data), do: advance(data, [])
  defp on_outcome(:update, :reclaim_image, _, _outcome, data), do: advance(data, [])
  # The commit point of an uninstall: from here nothing writes the file
  # again, so nothing that follows can bring the app back.
  defp on_outcome(:uninstall, :delete_file, _, {:ok, _}, data),
    do: advance(%{data | gone: true}, [])

  # Still installed, so its ingress URL answers again.
  defp on_outcome(:uninstall, :delete_file, _, {:error, reason}, data),
    do: fail(data, reason, [{:keys, ingress_keys(data), []}])

  defp on_outcome(:uninstall, :remove_app, _, {:ok, _}, data), do: advance(data, [])

  defp on_outcome(:uninstall, :remove_app, _, {:error, reason}, data),
    do: fail(data, reason, [])

  # Halt never persists: it keeps what the app wants for the next boot. An
  # app whose file is already gone was being uninstalled, and ends here.
  defp on_outcome(:halt, :halt_stop, _, outcome, data) do
    data = %{release(data) | last_event: :stopped}
    reply = if match?({:ok, _}, outcome), do: :ok, else: outcome
    {data, [{:reply, reply}, if(data.gone, do: :exit, else: :shutting_down)]}
  end

  defp on_outcome(op, name, arg, outcome, data),
    do: fail(data, {:unplanned, op, {name, arg}, outcome}, [])

  defp started(data, fact) do
    run = data.run
    wanted = if run.op == :start, do: :started, else: data.wanted
    attempt = if run.args[:retry], do: data.attempt, else: 0

    data = %{
      data
      | container_id: fact.container_id,
        ip: fact[:ip],
        broker_pid: fact[:pid],
        wanted: wanted,
        attempt: attempt,
        strikes: 0,
        last_event: {:running, fact[:healthcheck] == true}
    }

    dns = dns_keys(data)
    monitor = if fact[:pid], do: [:monitor_broker], else: []
    probe = if is_binary(data.config.watchdog) and data.watchdog, do: [probe_timer()], else: []
    settled = if run.args[:retry], do: [{:timer, :settled, @settled_ms, :settled}], else: []
    {data, [{:keys, dns, Enum.map(dns, &key/1)} | monitor] ++ probe ++ settled}
  end

  defp rolled_back(cause), do: {:error, {:rolled_back, cause}}

  defp cleanup(data, cause, effects) do
    data = data |> put_acc(:cause, cause) |> put_steps([{:stop, :by_name}])
    advance(data, effects)
  end

  defp finish(%{run: %{op: :install}} = data, effects),
    do: {data, effects ++ [{:reply, :ok}, :idle]}

  defp finish(%{run: %{op: :uninstall}} = data, effects),
    do: {data, effects ++ [{:reply, :ok}, :exit]}

  defp finish(%{run: run} = data, effects),
    do: {data, effects ++ [:persist, {:reply, result(run, data)}, :idle]}

  defp result(%{op: :update, acc: %{result: result}}, _data), do: result

  defp result(%{op: :update, acc: acc}, data),
    do: {:ok, %{slug: data.slug, from: acc.old.version, to: data.config.version}}

  defp result(%{op: :backup, acc: acc}, _data), do: Map.get(acc, :result, {:ok, nil})
  defp result(_run, _data), do: :ok

  # An install that fails leaves no file and no process. Otherwise a retry
  # that failed, or a cleanup after a dead step, goes back to the ladder.
  defp fail(%{run: %{op: :install}} = data, reason, effects),
    do: {data, effects ++ [{:reply, {:error, reason}}, :exit]}

  defp fail(%{gone: true} = data, reason, effects),
    do: {data, effects ++ [{:reply, {:error, reason}}, :exit]}

  defp fail(%{run: run} = data, reason, effects) do
    {data, retry} =
      if run.args[:retry] || run.acc[:cleaned], do: retry(data, []), else: {data, []}

    {data, effects ++ [:persist, {:reply, {:error, reason}}] ++ retry ++ [:idle]}
  end

  defp put_steps(data, steps), do: put_in(data.run.steps, steps)
  defp put_acc(data, key, value), do: put_in(data.run.acc[key], value)

  @doc """
  What a task step is given, built from the data current at its spawn (see
  the moduledoc). An update's pull fetches the target, not the installed
  config.
  """
  @spec task_input(step(), map()) :: map()
  def task_input({name, arg}, %{run: run} = data) do
    config =
      if name == :pull, do: run.args[:config] || data.config, else: data.config || run.args.config

    run.args
    |> Map.take(@engine_overrides)
    |> Map.merge(%{
      slug: data.slug,
      config: config,
      job: run.args[:job],
      stage: stage(run.op, name)
    })
    |> Map.merge(input(name, arg, data))
  end

  defp input(:start, _arg, data),
    do: Map.take(data, [:token, :user_options, :ports, :protected])

  defp input(:snapshot, _arg, %{run: run} = data) do
    state = if run.acc[:was_running] || running?(data), do: "started", else: "stopped"

    %{
      staging_dir: run.args[:staging_dir],
      system: run.args[:system] || %{},
      user_options: data.user_options,
      state: state
    }
  end

  defp input(:exec_hook, :pre, data), do: %{cmd: data.config.backup_pre}
  defp input(:exec_hook, :post, data), do: %{cmd: data.config.backup_post}
  defp input(:reclaim_image, _arg, data), do: %{old: data.run.acc.old}
  defp input(_name, _arg, _data), do: %{}

  # Coarse waypoints for the update job's progress bar.
  defp stage(:update, :pull), do: {"pull_image", 20}
  defp stage(:update, :stop), do: {"stop", 70}
  defp stage(:update, :snapshot), do: {"backup", 75}
  defp stage(:update, :start), do: {"start", 90}
  defp stage(_op, _name), do: nil

  @doc "Each task step's deadline, re-armed at every spawn."
  @spec deadline(atom()) :: pos_integer()
  def deadline(name), do: Map.fetch!(@deadlines, name)
end
