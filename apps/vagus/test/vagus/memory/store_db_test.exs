defmodule Vagus.Memory.StoreDBTest do
  # One database for every test, reset by each.
  use ExUnit.Case, async: false

  import Plug.Test

  alias Vagus.Memory
  alias Vagus.Memory.Embedder.None
  alias Vagus.Memory.FakeEmbedder.{A, B, Narrow, Wrong}

  @moduletag :db

  setup do
    db = db_options(System.fetch_env!("VAGUS_MEMORY_TEST_DSN"))
    reset(db)
    %{db: db}
  end

  defp db_options(dsn) do
    uri = URI.parse(dsn)
    [user | password] = String.split(uri.userinfo || "agent", ":", parts: 2)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/memory", "/"),
      username: user
    ] ++ Enum.map(password, &{:password, &1})
  end

  # The extension too, so each test's first init creates it on a connection
  # whose types were loaded without it.
  defp reset(db) do
    {:ok, conn} = Postgrex.start_link(db)

    Postgrex.query!(
      conn,
      "DROP TABLE IF EXISTS captures, journal, devices, tasks, memories, schema_version CASCADE",
      []
    )

    Postgrex.query!(conn, "DROP EXTENSION IF EXISTS vector CASCADE", [])
    GenServer.stop(conn)
  end

  defp start_memory(db, embedder) do
    opts = start_unready(db, embedder)
    await_ready(opts)
    opts
  end

  defp start_unready(db, embedder) do
    n = System.unique_integer([:positive])
    names = for key <- [:name, :repo, :store, :tasks], do: {key, :"memory_db_#{key}_#{n}"}

    start_supervised!(
      {Memory, names ++ [db: db, pool: true, embedder: embedder, listen: false, retry_ms: 20]},
      id: names[:name]
    )

    [store: names[:store], memory: names[:name]]
  end

  defp await_ready(opts, tries \\ 250) do
    case Memory.status(opts) do
      {:ok, _status} ->
        :ok

      {:error, :db_unavailable} when tries > 0 ->
        receive after: (20 -> await_ready(opts, tries - 1))
    end
  end

  defp texts({:ok, results}), do: Enum.map(results, & &1.text)

  defp sql(db, statement, params \\ []) do
    {:ok, conn} = Postgrex.start_link(db)
    result = Postgrex.query!(conn, statement, params)
    GenServer.stop(conn)
    result.rows
  end

  test "init is idempotent and records model and dims once", %{db: db} do
    opts = start_memory(db, A)
    assert {:ok, %{id: id}} = Memory.remember("fact", nil, "the kettle boils", opts)
    stop_supervised!(opts[:memory])

    opts = start_memory(db, A)

    assert {:ok, %{schema_version: 1, model: "fake-a", dims: 64, counts: %{live: 1}}} =
             Memory.status(opts)

    assert sql(db, "SELECT version, model, dims FROM schema_version") == [[1, "fake-a", 64]]
    assert {:ok, [%{id: ^id}]} = Memory.recall("kettle", opts)
  end

  test "two stores initialising at once make one schema", %{db: db} do
    [first, second] = for _ <- 1..2, do: start_unready(db, A)
    await_ready(first)
    await_ready(second)

    assert sql(db, "SELECT count(*) FROM schema_version") == [[1]]
    assert {:ok, %{embedded: true}} = Memory.remember("fact", nil, "after both", first)
  end

  test "a paraphrase is recalled by vector where keywords alone miss it", %{db: db} do
    opts = start_memory(db, A)

    assert {:ok, %{embedded: true}} =
             Memory.remember("fact", "home", "the kettle boils water quickly", opts)

    assert {:ok, _} =
             Memory.remember("fact", "home", "the garage door opener speaks zigbee", opts)

    assert texts(Memory.recall("kettle water heating", [embedder: None] ++ opts)) == []

    assert ["the kettle boils water quickly" | _] =
             texts(Memory.recall("kettle water heating", opts))
  end

  test "keyword recall works without an embedder, and a scope filters", %{db: db} do
    opts = start_memory(db, None)

    assert {:ok, %{embedded: false}} =
             Memory.remember("lesson", "gw", "rollback the gateway firmware first", opts)

    assert {:ok, _} =
             Memory.remember("lesson", "other", "rollback is not needed for the probe", opts)

    assert Enum.sort(texts(Memory.recall("rollback", opts))) == [
             "rollback is not needed for the probe",
             "rollback the gateway firmware first"
           ]

    assert texts(Memory.recall("rollback", [scope: "gw"] ++ opts)) == [
             "rollback the gateway firmware first"
           ]

    assert {:ok, [%{score: score, source_task: nil, kind: "lesson"}]} =
             Memory.recall("rollback", [scope: "gw", k: 1] ++ opts)

    assert score > 0
  end

  test "forget tombstones and hides a memory but deletes nothing", %{db: db} do
    opts = start_memory(db, A)
    {:ok, %{id: old}} = Memory.remember("fact", nil, "the broker listens on 1884", opts)
    {:ok, %{id: new}} = Memory.remember("fact", nil, "the broker listens on 1883", opts)

    assert {:ok, %{tombstone: tombstone, superseded_by: ^new}} =
             Memory.forget(old, "wrong port", [replaced_by: new, source_task: "t1"] ++ opts)

    assert texts(Memory.recall("broker listens", opts)) == ["the broker listens on 1883"]
    refute "wrong port" in texts(Memory.recall("wrong port", opts))
    assert Memory.forget(old, "again", opts) == {:error, :not_found}
    assert Memory.forget(tombstone, "a tombstone", opts) == {:error, :not_found}
    assert Memory.forget(new, "x", [replaced_by: old] ++ opts) == {:error, :not_found}

    assert sql(db, "SELECT kind, text, refs, source_task FROM memories WHERE id = $1", [tombstone]) ==
             [["tombstone", "wrong port", [old], "t1"]]

    assert {:ok, %{counts: %{live: 1, superseded: 1, tombstones: 1}}} = Memory.status(opts)
  end

  test "journal, device notes and captures", %{db: db} do
    opts = start_memory(db, None)
    assert {:ok, %{task_id: task}} = Memory.journal("flash-q6a", "started", opts)
    assert {:ok, %{task_id: ^task}} = Memory.journal("flash-q6a", "done", [summary: "ok"] ++ opts)
    assert sql(db, "SELECT summary, finished_at IS NOT NULL FROM tasks") == [["ok", true]]

    assert {:ok, _} = Memory.device_note("q6a-58", "UFS 128 GB", opts)
    assert {:ok, _} = Memory.device_note("q6a-58", "fan on PoE", opts)
    assert sql(db, "SELECT notes FROM devices") == [["UFS 128 GB\nfan on PoE"]]

    assert Memory.device_note("q6a-58", String.duplicate("a", 65_520), opts) ==
             {:error, :too_large}

    assert {:ok, %{id: _}} =
             Memory.capture_register(
               "/data/captures/uart.log",
               %{"baud" => 115_200},
               [task: "flash-q6a"] ++ opts
             )

    assert sql(db, "SELECT c.meta, t.name FROM captures c JOIN tasks t ON t.id = c.task_id") ==
             [[%{"baud" => 115_200}, "flash-q6a"]]
  end

  test "a vector from another model or of the wrong width is stored NULL and found by keyword",
       %{db: db} do
    opts = start_memory(db, A)

    assert {:ok, %{embedded: false}} =
             Memory.remember("fact", nil, "zigbee channel is 25", [embedder: B] ++ opts)

    assert {:ok, %{embedded: false}} =
             Memory.remember("fact", nil, "zigbee pan id is 1a62", [embedder: Wrong] ++ opts)

    assert Enum.sort(texts(Memory.recall("zigbee", opts))) == [
             "zigbee channel is 25",
             "zigbee pan id is 1a62"
           ]

    assert {:ok, %{counts: %{unembedded: 2}}} = Memory.status(opts)
  end

  test "reembed switches model, resizes, and resumes", %{db: db} do
    opts = start_memory(db, None)
    for i <- 1..70, do: {:ok, _} = Memory.remember("fact", nil, "note #{i} about kettles", opts)

    assert Memory.reembed("fake-b", [embedder: A] ++ opts) ==
             {:error, {:embedder_model, "fake-a"}}

    # 384 to 64 dims: the column is rebuilt.
    assert {:ok, %{switched: true, embedded: 64, done: false}} =
             Memory.reembed("fake-a", [embedder: A, max_batches: 1] ++ opts)

    assert {:ok, %{model: "fake-a", dims: 64, counts: %{unembedded: 6}}} = Memory.status(opts)

    assert {:ok, %{switched: false, embedded: 6, done: true}} =
             Memory.reembed("fake-a", [embedder: A] ++ opts)

    # Same width, another model: every vector is cleared and refilled.
    assert {:ok, %{switched: true, embedded: 70, dims: 64}} =
             Memory.reembed("fake-b", [embedder: B] ++ opts)

    assert {:ok, %{switched: true, embedded: 70, dims: 32}} =
             Memory.reembed("fake-narrow", [embedder: Narrow] ++ opts)

    assert {:ok, %{model: "fake-narrow", dims: 32, counts: %{unembedded: 0}}} =
             Memory.status(opts)

    assert {:ok, [_ | _]} = Memory.recall("kettles", [embedder: Narrow] ++ opts)
  end

  defp paused_remember(opts, stage, text) do
    test = self()

    hook = fn
      ^stage ->
        send(test, {:paused, self()})
        receive do: (:go -> :ok)

      _other ->
        :ok
    end

    task =
      Task.async(fn -> Memory.remember("fact", nil, text, [embedder: A, hook: hook] ++ opts) end)

    assert_receive {:paused, pid}, 5_000
    {task, pid}
  end

  test "an insert embedded before a switch commits without the stale vector", %{db: db} do
    opts = start_memory(db, A)
    {task, pid} = paused_remember(opts, :embedded, "kettle descaling uses citric acid")

    assert {:ok, %{switched: true}} = Memory.reembed("fake-b", [embedder: B] ++ opts)
    send(pid, :go)
    assert {:ok, %{embedded: false}} = Task.await(task)

    assert {:ok, %{switched: false, embedded: 1}} =
             Memory.reembed("fake-b", [embedder: B] ++ opts)
  end

  test "a switch waits for an insert holding the model, then clears its vector", %{db: db} do
    opts = start_memory(db, A)
    {task, pid} = paused_remember(opts, :locked, "kettle descaling uses citric acid")

    reembed = Task.async(fn -> Memory.reembed("fake-b", [embedder: B] ++ opts) end)
    refute Task.yield(reembed, 300)

    send(pid, :go)
    assert {:ok, %{embedded: true}} = Task.await(task)
    assert {:ok, %{switched: true, embedded: 1}} = Task.await(reembed)

    assert {:ok, %{model: "fake-b", counts: %{unembedded: 0}}} = Memory.status(opts)
  end

  defp paused_recall(opts, stage, query) do
    test = self()

    hook = fn
      ^stage ->
        send(test, {:paused, self()})
        receive do: (:go -> :ok)

      _other ->
        :ok
    end

    task = Task.async(fn -> Memory.recall(query, [embedder: A, hook: hook] ++ opts) end)
    assert_receive {:paused, pid}, 5_000
    {task, pid}
  end

  test "a switch waits for a recall holding the model", %{db: db} do
    opts = start_memory(db, A)

    {:ok, _} =
      Memory.remember("fact", nil, "the kettle boils water quickly", [embedder: A] ++ opts)

    {task, pid} = paused_recall(opts, :locked, "kettle water heating")

    reembed = Task.async(fn -> Memory.reembed("fake-narrow", [embedder: Narrow] ++ opts) end)
    refute Task.yield(reembed, 300)

    send(pid, :go)
    assert texts(Task.await(task)) == ["the kettle boils water quickly"]
    assert {:ok, %{switched: true, dims: 32}} = Task.await(reembed)
  end

  test "a recall embedded before a width switch falls back to keywords", %{db: db} do
    opts = start_memory(db, A)

    {:ok, _} =
      Memory.remember("fact", nil, "the kettle boils water quickly", [embedder: A] ++ opts)

    {:ok, _} =
      Memory.remember("fact", nil, "kettle water heating takes power", [embedder: A] ++ opts)

    {task, pid} = paused_recall(opts, :embedded, "kettle water heating")

    assert {:ok, %{switched: true, dims: 32}} =
             Memory.reembed("fake-narrow", [embedder: Narrow] ++ opts)

    send(pid, :go)
    assert texts(Task.await(task)) == ["kettle water heating takes power"]
  end

  test "a schema dropped under a running store is reapplied", %{db: db} do
    opts = start_memory(db, A)
    sql(db, "DROP TABLE captures, journal, devices, tasks, memories, schema_version CASCADE")

    assert Memory.remember("fact", nil, "lost", opts) == {:error, :db_unavailable}
    await_ready(opts)
    assert {:ok, %{embedded: true}} = Memory.remember("fact", nil, "kept", opts)
  end

  test "the MCP tools round-trip through the store", %{db: db} do
    opts = start_memory(db, A)
    tasks = :"memory_mcp_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: tasks})
    mcp = Memory.MCP.init(store: opts[:store], tasks: tasks)

    call = fn name, arguments ->
      body =
        JSON.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: name, arguments: arguments}
        })

      conn =
        :post
        |> conn("/mcp", body)
        |> Plug.Conn.put_req_header("x-vagus-task", "task-7")
        |> Memory.MCP.call(mcp)

      %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
        JSON.decode!(conn.resp_body)

      JSON.decode!(text)
    end

    assert %{"id" => id, "embedded" => true} =
             call.("remember", %{kind: "fact", text: "the kettle boils water", refs: ["a"]})

    assert [%{"id" => ^id, "source_task" => "task-7", "created_at" => _}] =
             call.("recall", %{query: "kettle", k: 3})

    assert %{"tombstone" => _} = call.("forget", %{id: id, reason: "obsolete"})
    assert call.("recall", %{query: "kettle"}) == []
  end
end
