defmodule Vagus.Memory.Store do
  @moduledoc """
  The memory store. The process owns what must have one owner: applying
  the schema once Postgres answers, and the embedder and its warning. The
  operations run in the caller against the pool, so a slow embed or query
  holds one caller, not every caller; the pool's two connections bound
  what reaches the database.

  The DB app may start after this one, or be stopped for a cold backup.
  Schema init retries with backoff and never crashes the native app; until
  it succeeds, and whenever Postgres is unreachable, an operation returns
  `{:error, :db_unavailable}`. A schema that disappears under a live store
  (a restore onto an empty data dir) sends it back to init.
  """

  use GenServer

  require Logger

  alias Vagus.Memory.{Fusion, SQL}

  @text_cap 65_536
  @name_chars 256
  @path_cap 4_096
  @refs_cap 64
  @k_default 8
  @call_ms 15_000
  @switch_ms 120_000
  @batch 64
  @context_ms 5_000
  @retry_first_ms 1_000
  @retry_max_ms 30_000

  @type error ::
          :db_unavailable
          | :unavailable
          | :too_large
          | :invalid
          | :reserved_kind
          | :not_found
          | {:db, atom()}
          | term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec remember(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def remember(kind, scope, text, opts \\ []) do
    refs = Keyword.get(opts, :refs, [])
    source_task = Keyword.get(opts, :source_task)

    with :ok <- name(kind),
         :ok <- if(kind == "tombstone", do: {:error, :reserved_kind}, else: :ok),
         :ok <- optional_name(scope),
         :ok <- text(text),
         :ok <- optional_name(source_task),
         :ok <- refs(refs),
         {:ok, ctx} <- context(opts) do
      vector = embed(ctx, text)
      hook(opts, :embedded)

      transaction(ctx, fn conn ->
        vector = usable(conn, ctx, vector, SQL.model_for_share())
        hook(opts, :locked)

        %{rows: [[id, at]]} =
          Postgrex.query!(conn, SQL.insert_memory(), [
            kind,
            scope,
            text,
            refs,
            vector,
            source_task
          ])

        %{id: id, created_at: at, embedded: vector != nil}
      end)
    end
  end

  @spec recall(String.t(), keyword()) :: {:ok, [map()]} | {:error, error()}
  def recall(query, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    k = Keyword.get(opts, :k, @k_default)

    with :ok <- text(query),
         :ok <- if(String.trim(query) == "", do: {:error, :invalid}, else: :ok),
         :ok <- optional_name(scope),
         :ok <- if(is_integer(k) and k in 1..100, do: :ok, else: {:error, :invalid}),
         {:ok, ctx} <- context(opts) do
      # Embedded before the transaction, so the lock below is never held
      # for the engine's time.
      vector = embed(ctx, query)
      hook(opts, :embedded)
      # Enough candidates that a row both lists rank lowly can still fuse
      # into the top k; 1000 is ef_search's ceiling and k's at 100.
      pool = max(10 * k, 200)
      scoped = if scope, do: [scope], else: []

      # FOR SHARE holds the model through both queries: a `reembed/2`
      # switch waits for this recall, and one that committed first makes
      # the vector unusable, so the call is keyword-only.
      transaction(ctx, fn conn ->
        vector = usable(conn, ctx, vector, SQL.model_for_share())
        hook(opts, :locked)

        vector_ids =
          case vector do
            nil ->
              []

            vector ->
              Postgrex.query!(conn, SQL.scan_settings(), [Integer.to_string(pool)])
              ids(conn, SQL.vector_recall(scope != nil), [vector, pool | scoped])
          end

        keyword_ids = ids(conn, SQL.keyword_recall(scope != nil), [query, pool | scoped])
        rows(conn, Fusion.merge([vector_ids, keyword_ids], k))
      end)
    end
  end

  @spec journal(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def journal(task, entry, opts \\ []) do
    summary = Keyword.get(opts, :summary)

    with :ok <- name(task),
         :ok <- text(entry),
         :ok <- if(summary, do: text(summary), else: :ok),
         {:ok, ctx} <- context(opts) do
      transaction(ctx, fn conn ->
        task_id = task_id(conn, task)
        %{rows: [[id, at]]} = Postgrex.query!(conn, SQL.insert_journal(), [task_id, entry])
        if summary, do: Postgrex.query!(conn, SQL.finish_task(), [task_id, summary])
        %{id: id, task_id: task_id, at: at}
      end)
    end
  end

  @spec device_note(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def device_note(device_id, text, opts \\ []) do
    with :ok <- name(device_id),
         :ok <- text(text),
         {:ok, ctx} <- context(opts) do
      transaction(ctx, fn conn ->
        case Postgrex.query!(conn, SQL.append_device_note(@text_cap), [device_id, text]).rows do
          [[id, at]] -> %{id: id, updated_at: at}
          [] -> Postgrex.rollback(conn, :too_large)
        end
      end)
    end
  end

  @spec capture_register(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def capture_register(path, meta, opts \\ []) do
    task = Keyword.get(opts, :task)

    with :ok <- bounded(path, @path_cap),
         :ok <- if(path == "", do: {:error, :invalid}, else: :ok),
         :ok <- if(is_map(meta), do: json(meta), else: {:error, :invalid}),
         :ok <- optional_name(task),
         {:ok, ctx} <- context(opts) do
      transaction(ctx, fn conn ->
        task_id = if task, do: task_id(conn, task)
        %{rows: [[id, at]]} = Postgrex.query!(conn, SQL.insert_capture(), [path, task_id, meta])
        %{id: id, created_at: at}
      end)
    end
  end

  @doc """
  Hides memory `id` from recall. Nothing is deleted: a `tombstone` row
  records the reason, and `id`'s `superseded_by` names `:replaced_by` when
  given, else the tombstone.
  """
  @spec forget(pos_integer(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def forget(id, reason, opts \\ []) do
    replaced_by = Keyword.get(opts, :replaced_by)
    source_task = Keyword.get(opts, :source_task)

    with :ok <- if(is_integer(id) and id > 0, do: :ok, else: {:error, :invalid}),
         :ok <- text(reason),
         :ok <- replacement(replaced_by, id),
         :ok <- optional_name(source_task),
         {:ok, ctx} <- context(opts) do
      transaction(ctx, fn conn ->
        scope =
          case Postgrex.query!(conn, SQL.live_scope(), [id]).rows do
            [[scope]] -> scope
            [] -> Postgrex.rollback(conn, :not_found)
          end

        if replaced_by && Postgrex.query!(conn, SQL.live_scope(), [replaced_by]).rows == [],
          do: Postgrex.rollback(conn, :not_found)

        %{rows: [[tombstone, _at]]} =
          Postgrex.query!(conn, SQL.insert_memory(), [
            "tombstone",
            scope,
            reason,
            [id],
            nil,
            source_task
          ])

        Postgrex.query!(conn, SQL.supersede(), [id, replaced_by || tombstone])
        %{id: id, tombstone: tombstone, superseded_by: replaced_by || tombstone}
      end)
    end
  end

  @spec status(keyword()) :: {:ok, map()} | {:error, error()}
  def status(opts \\ []) do
    with {:ok, ctx} <- context(opts) do
      transaction(ctx, fn conn ->
        %{rows: [[version, model, dims]]} =
          Postgrex.query!(conn, "SELECT version, model, dims FROM schema_version", [])

        %{rows: [counts]} = Postgrex.query!(conn, SQL.counts(), [])

        keys = [
          :live,
          :unembedded,
          :superseded,
          :tombstones,
          :tasks,
          :journal,
          :devices,
          :captures
        ]

        %{
          schema_version: version,
          model: model,
          dims: dims,
          embedder: %{model: ctx.embedder.model(), dims: ctx.embedder.dims()},
          counts: Map.new(Enum.zip(keys, counts))
        }
      end)
    end
  end

  @doc """
  Moves the stored vectors to `model`, which must be the embedder's. The
  switch takes `schema_version` FOR UPDATE, so it waits out every insert
  holding it FOR SHARE and clears or resizes the column before any later
  insert sees the new model; the refill then runs in batches, each
  rechecking the model, so a run cut short resumes by calling it again.
  `:max_batches` bounds one run.
  """
  @spec reembed(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def reembed(model, opts \\ []) do
    with {:ok, ctx} <- context(opts),
         :ok <- embedder_is(ctx.embedder, model),
         dims = ctx.embedder.dims(),
         :ok <- if(dims in 1..SQL.max_dims(), do: :ok, else: {:error, {:embedder_dims, dims}}),
         {:ok, switched} <- switch(ctx, model, dims) do
      fill(ctx, model, dims, Keyword.get(opts, :max_batches, :infinity), %{
        model: model,
        dims: dims,
        switched: switched,
        embedded: 0,
        failed: 0,
        last_id: 0,
        done: false
      })
    end
  end

  defp switch(ctx, model, dims) do
    transaction(
      ctx,
      fn conn ->
        [[old_model, old_dims]] = Postgrex.query!(conn, SQL.model_for_update(), []).rows

        cond do
          old_model == model and old_dims == dims ->
            false

          old_dims != dims ->
            Enum.each(SQL.resize(dims), &Postgrex.query!(conn, &1, []))
            Postgrex.query!(conn, SQL.switch_model(), [model, dims])
            true

          true ->
            Postgrex.query!(conn, SQL.clear_embeddings(), [])
            Postgrex.query!(conn, SQL.switch_model(), [model, dims])
            true
        end
      end,
      timeout: @switch_ms
    )
  end

  defp fill(_ctx, _model, _dims, 0, acc), do: {:ok, Map.delete(acc, :last_id)}

  defp fill(ctx, model, dims, batches, acc) do
    with {:ok, batch} <-
           transaction(ctx, fn conn ->
             Postgrex.query!(conn, SQL.unembedded_batch(), [acc.last_id, @batch]).rows
           end) do
      case batch do
        [] ->
          {:ok, acc |> Map.put(:done, true) |> Map.delete(:last_id)}

        rows ->
          # Embedded outside the transaction: the lock is held only for the
          # writes, never for the engine's time.
          vectors = for [id, text] <- rows, do: {id, embed(ctx, text)}

          with {:ok, written} <- write_batch(ctx, model, dims, vectors) do
            failed = length(vectors) - written
            [last_id, _text] = List.last(rows)
            acc = %{acc | embedded: acc.embedded + written, failed: acc.failed + failed}
            fill(ctx, model, dims, next(batches), %{acc | last_id: last_id})
          end
      end
    end
  end

  defp next(:infinity), do: :infinity
  defp next(batches), do: batches - 1

  defp write_batch(ctx, model, dims, vectors) do
    transaction(ctx, fn conn ->
      case Postgrex.query!(conn, SQL.model_for_share(), []).rows do
        [[^model, ^dims]] ->
          Enum.count(vectors, fn
            {_id, nil} ->
              false

            {id, vector} ->
              Postgrex.query!(conn, SQL.set_embedding(), [id, vector]).num_rows == 1
          end)

        _switched_again ->
          Postgrex.rollback(conn, :superseded)
      end
    end)
  end

  defp embedder_is(embedder, model) do
    if embedder.model() == model,
      do: :ok,
      else: {:error, {:embedder_model, embedder.model()}}
  end

  defp replacement(nil, _id), do: :ok
  defp replacement(other, id) when is_integer(other) and other > 0 and other != id, do: :ok
  defp replacement(_other, _id), do: {:error, :invalid}

  defp task_id(conn, task) do
    %{rows: [[id]]} = Postgrex.query!(conn, SQL.upsert_task(), [task])
    id
  end

  defp ids(conn, sql, params),
    do: conn |> Postgrex.query!(sql, params) |> Map.get(:rows) |> List.flatten()

  defp rows(_conn, []), do: []

  defp rows(conn, ranked) do
    by_id =
      Map.new(Postgrex.query!(conn, SQL.fetch_rows(), [Enum.map(ranked, &elem(&1, 0))]).rows, fn
        [id, kind, scope, text, at, task] ->
          {id, %{id: id, kind: kind, scope: scope, text: text, created_at: at, source_task: task}}
      end)

    for {id, score} <- ranked, row = by_id[id], do: Map.put(row, :score, score)
  end

  # A vector is stored or compared only against the model and width the
  # schema records; anything else would be measured against another
  # engine's space.
  defp usable(_conn, _ctx, nil, _sql), do: nil

  defp usable(conn, ctx, vector, sql) do
    model = ctx.embedder.model()
    width = length(vector)

    case Postgrex.query!(conn, sql, []).rows do
      [[^model, ^width]] -> vector
      _other -> nil
    end
  end

  # The embedder is third-party code: whatever it does, the memory is still
  # stored, and found by keyword.
  defp embed(ctx, text) do
    case safe_embed(ctx.embedder, text) do
      {:ok, vector} when is_list(vector) ->
        if length(vector) == ctx.embedder.dims() and Enum.all?(vector, &is_number/1),
          do: vector,
          else: embed_failed(ctx, {:width, length(vector), ctx.embedder.dims()})

      {:ok, other} ->
        embed_failed(ctx, {:not_a_vector, other})

      {:error, reason} ->
        embed_failed(ctx, reason)
    end
  end

  defp safe_embed(embedder, text) do
    embedder.embed(text)
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp embed_failed(ctx, reason) do
    GenServer.cast(ctx.store, {:embed_failed, ctx.embedder, reason})
    nil
  end

  defp hook(opts, stage) do
    case Keyword.get(opts, :hook) do
      nil -> :ok
      fun -> fun.(stage)
    end
  end

  defp context(opts) do
    store = Keyword.get(opts, :store, __MODULE__)

    case GenServer.call(store, :context, @context_ms) do
      {:ok, ctx} ->
        {:ok, %{ctx | embedder: Keyword.get(opts, :embedder, ctx.embedder), store: store}}

      error ->
        error
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp transaction(ctx, fun, opts \\ []) do
    Postgrex.transaction(ctx.repo, fun, Keyword.put_new(opts, :timeout, @call_ms))
  rescue
    DBConnection.ConnectionError -> {:error, :db_unavailable}
    error in Postgrex.Error -> db_error(ctx, error)
  catch
    # The pool is not running: the subtree is starting or stopping.
    :exit, _reason -> {:error, :db_unavailable}
  end

  @schema_lost [:undefined_table, :undefined_column, :undefined_object]

  defp db_error(ctx, %Postgrex.Error{postgres: %{code: code}}) when code in @schema_lost do
    GenServer.cast(ctx.store, :schema_lost)
    {:error, :db_unavailable}
  end

  defp db_error(_ctx, error) do
    Logger.warning("Vagus.Memory: query failed: #{Exception.message(error)}")
    {:error, {:db, (error.postgres || %{})[:code] || :unknown}}
  end

  defp name(value) when is_binary(value) and value != "" do
    # The byte check first bounds the character count's walk.
    if byte_size(value) <= 4 * @name_chars and String.length(value) <= @name_chars,
      do: valid(value),
      else: {:error, :too_large}
  end

  defp name(_value), do: {:error, :invalid}

  defp optional_name(nil), do: :ok
  defp optional_name(value), do: name(value)

  defp text(value), do: bounded(value, @text_cap)

  defp bounded(value, cap) when is_binary(value) do
    if byte_size(value) <= cap, do: valid(value), else: {:error, :too_large}
  end

  defp bounded(_value, _cap), do: {:error, :invalid}

  # Postgres text holds neither invalid UTF-8 nor NUL.
  defp valid(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid}
  end

  defp refs(refs) when is_list(refs) and length(refs) <= @refs_cap, do: json(refs)
  defp refs(refs) when is_list(refs), do: {:error, :too_large}
  defp refs(_refs), do: {:error, :invalid}

  defp json(term) do
    if IO.iodata_length(JSON.encode_to_iodata!(term)) <= @text_cap,
      do: :ok,
      else: {:error, :too_large}
  rescue
    _not_json -> {:error, :invalid}
  end

  @impl GenServer
  def init(opts) do
    state = %{
      repo: Keyword.fetch!(opts, :repo),
      embedder: Keyword.fetch!(opts, :embedder),
      ready: false,
      retry_ms: Keyword.get(opts, :retry_ms, @retry_first_ms),
      attempt: 0,
      warned: false
    }

    {:ok, state, {:continue, :init_schema}}
  end

  @impl GenServer
  def handle_continue(:init_schema, state), do: {:noreply, init_schema(state)}

  @impl GenServer
  def handle_call(:context, _from, %{ready: true} = state),
    do: {:reply, {:ok, %{repo: state.repo, embedder: state.embedder, store: self()}}, state}

  def handle_call(:context, _from, state), do: {:reply, {:error, :db_unavailable}, state}

  @impl GenServer
  def handle_cast({:embed_failed, embedder, reason}, %{warned: false} = state) do
    Logger.warning(
      "Vagus.Memory: embedder #{inspect(embedder)} failed (#{inspect(reason)}); " <>
        "memories are stored without vectors and recalled by keyword. Not repeated."
    )

    {:noreply, %{state | warned: true}}
  end

  def handle_cast({:embed_failed, _embedder, _reason}, state), do: {:noreply, state}

  def handle_cast(:schema_lost, %{ready: true} = state) do
    Logger.warning("Vagus.Memory: the schema is gone; initialising it again")
    {:noreply, init_schema(%{state | ready: false, attempt: 0})}
  end

  def handle_cast(:schema_lost, state), do: {:noreply, state}

  # A retry timer is armed only by a failed attempt, so at most one is.
  @impl GenServer
  def handle_info(:init_schema, %{ready: false} = state), do: {:noreply, init_schema(state)}
  def handle_info(_message, state), do: {:noreply, state}

  # `queue: false`: with no connection up, the checkout fails at once
  # instead of waiting out the pool's connect attempts, so the store keeps
  # answering `:context` while Postgres is away.
  defp init_schema(state) do
    ctx = %{repo: state.repo, store: self()}

    case transaction(ctx, &ensure_schema(&1, state.embedder), queue: false) do
      {:ok, %{model: model, dims: dims}} -> ready(state, model, dims)
      {:error, reason} -> retry(state, reason)
    end
  end

  defp ensure_schema(conn, embedder) do
    Postgrex.query!(conn, SQL.init_lock(), [])

    case Postgrex.query!(conn, "SELECT to_regclass('schema_version') IS NOT NULL", []).rows do
      [[true]] ->
        case Postgrex.query!(conn, "SELECT version, model, dims FROM schema_version", []).rows do
          [[1, model, dims]] -> %{model: model, dims: dims}
          other -> Postgrex.rollback(conn, {:schema_version, other})
        end

      [[false]] ->
        dims = embedder.dims()

        if dims not in 1..SQL.max_dims(), do: Postgrex.rollback(conn, {:embedder_dims, dims})

        Enum.each(SQL.schema(dims), &Postgrex.query!(conn, &1, []))

        Postgrex.query!(conn, "INSERT INTO schema_version VALUES ($1, $2, $3)", [
          SQL.version(),
          embedder.model(),
          dims
        ])

        %{model: embedder.model(), dims: dims}
    end
  end

  defp ready(state, model, dims) do
    if model != state.embedder.model() or dims != state.embedder.dims() do
      Logger.warning(
        "Vagus.Memory: the schema's vectors are #{model}/#{dims} but the embedder is " <>
          "#{state.embedder.model()}/#{state.embedder.dims()}; new memories get no vector " <>
          "until Vagus.Memory.reembed/2 switches"
      )
    end

    Logger.info("Vagus.Memory: schema v#{SQL.version()} ready (#{model}, #{dims} dims)")
    %{state | ready: true, attempt: 0}
  end

  # The DB app starting late is ordinary boot, so only every tenth failure
  # is a warning.
  defp retry(state, reason) do
    attempt = state.attempt + 1
    delay = min(state.retry_ms * 2 ** min(attempt - 1, 5), @retry_max_ms)
    message = "Vagus.Memory: schema not ready (#{inspect(reason)}), retrying in #{delay} ms"

    if rem(attempt - 1, 10) == 0, do: Logger.warning(message), else: Logger.debug(message)

    Process.send_after(self(), :init_schema, delay)
    %{state | attempt: attempt}
  end
end
