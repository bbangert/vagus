defmodule Vagus.Memory do
  @moduledoc """
  The agent flavor's memory server: the native app `vagus_memory`, run in
  Vagus's own tree (`Vagus.Addon.Backend.Native`) over the board's
  Postgres + pgvector app (`agent_memory`, on agentnet). Containers reach
  it as MCP tools over Streamable HTTP (`Vagus.Memory.MCP`) on port 8890;
  the functions here are the same operations for callers in the BEAM, over
  dist too.

  Every operation returns `{:ok, _}` or `{:error, _}`; `:db_unavailable`
  while Postgres is unreachable or the schema is not yet applied,
  `:unavailable` when this app is not running.

  The embedder is `config :vagus, Vagus.Memory, embedder: Module`
  (`Vagus.Memory.Embedder`), `Vagus.Memory.Embedder.None` by default.
  """

  use Supervisor

  alias Vagus.Memory.{Embedder, MCP, Store}
  alias Vagus.Network.Agentnet

  @port 8890

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec port() :: pos_integer()
  def port, do: @port

  defdelegate remember(kind, scope, text, opts \\ []), to: Store
  defdelegate recall(query, opts \\ []), to: Store
  defdelegate journal(task, entry, opts \\ []), to: Store
  defdelegate device_note(device_id, text, opts \\ []), to: Store
  defdelegate capture_register(path, meta, opts \\ []), to: Store
  defdelegate forget(id, reason, opts \\ []), to: Store
  defdelegate status(opts \\ []), to: Store
  defdelegate reembed(model, opts \\ []), to: Store

  @doc """
  Options (tests): `:repo`, `:store`, `:tasks` names; `:db` Postgrex
  options merged over the agentnet DB's and config's `:db`; `:pool`, false
  to start no pool (config's, default true), so every operation is
  `:db_unavailable`; `:embedder`; `:retry_ms`, the first schema-init
  retry; `:listen`, default `Vagus.Flavor.agent?/0`.
  """
  @impl Supervisor
  def init(opts) do
    repo = Keyword.get(opts, :repo, __MODULE__.Repo)
    store = Keyword.get(opts, :store, Store)
    tasks = Keyword.get(opts, :tasks, __MODULE__.TaskSupervisor)

    config = Application.get_env(:vagus, __MODULE__, [])
    embedder = Keyword.get_lazy(opts, :embedder, fn -> config[:embedder] || Embedder.None end)

    db =
      repo
      |> db_options()
      |> Keyword.merge(Keyword.get(config, :db, []))
      |> Keyword.merge(Keyword.get(opts, :db, []))

    pool =
      if Keyword.get(opts, :pool, Keyword.get(config, :pool, true)),
        do: [{Postgrex, db}],
        else: []

    children =
      pool ++
        [
          {Store,
           [name: store, repo: repo, embedder: embedder] ++ Keyword.take(opts, [:retry_ms])},
          # The admission bound for MCP tool calls: the pool's two
          # connections serve two at a time and each call is killed at
          # 15 s, so more waiting tasks than a short queue are only memory.
          # A call over it is answered busy at once (`Vagus.Memory.MCP`).
          {Task.Supervisor, name: tasks, max_children: 8}
        ] ++
        if(Keyword.get_lazy(opts, :listen, &Vagus.Flavor.agent?/0),
          do: listeners(store, tasks),
          else: []
        )

    # Each child recovers on its own: the store holds no connection, only
    # the pool's name, and a listener only the store's.
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp db_options(repo) do
    [
      name: repo,
      hostname: Agentnet.memory_ip(),
      port: 5432,
      database: "memory",
      username: "agent",
      pool_size: 2,
      types: Vagus.Memory.PostgrexTypes,
      connect_timeout: 5_000,
      # A checkout waits about a second, not the caller's whole budget,
      # while Postgres is down; the connections back off to 30 s apart.
      queue_target: 1_000,
      queue_interval: 5_000,
      backoff_type: :exp,
      backoff_max: 30_000,
      parameters: [application_name: "vagus-memory"]
    ]
  end

  # No auth (the board is root by design): the bind addresses, and the
  # peer check in `Vagus.Memory.MCP`, are the boundary. The agentnet
  # gateway serves the workers; loopback the host-networked orchestrator
  # and Vagus's own tools. The gateway exists only once agentnet's bridge
  # does, so it is bound with the API listener's `:eaddrnotavail` retry.
  defp listeners(store, tasks) do
    plug = {MCP, store: store, tasks: tasks}

    [
      {DynamicSupervisor, name: __MODULE__.ListenerSupervisor, strategy: :one_for_one}
      | for {key, ip} <- [gateway: Agentnet.gateway(), loopback: "127.0.0.1"] do
          name = Module.concat(__MODULE__.Listener, Macro.camelize(Atom.to_string(key)))

          Supervisor.child_spec(
            {Vagus.API.Listener,
             name: name,
             listener_name: Module.concat(name, Bandit),
             supervisor: __MODULE__.ListenerSupervisor,
             plug: plug,
             port: @port,
             ip: ip},
            id: name
          )
        end
    ]
  end
end
