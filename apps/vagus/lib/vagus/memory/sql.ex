defmodule Vagus.Memory.SQL do
  @moduledoc """
  The memory schema's statements. Pure, so the text the server sends is
  testable without a database. Only integers are ever interpolated; every
  value a caller supplies is a parameter.
  """

  @version 1

  # Any constant works as long as nothing else on the DB takes the same
  # advisory key; two Vagus nodes or a restarted Store initialising at once
  # serialise on it.
  @init_lock 0x7661_6775_736D_656D

  # HNSW indexes at most 2000 dimensions of `vector`.
  @max_dims 2000

  @spec version() :: pos_integer()
  def version, do: @version

  @spec max_dims() :: pos_integer()
  def max_dims, do: @max_dims

  @spec init_lock() :: String.t()
  def init_lock, do: "SELECT pg_advisory_xact_lock(#{@init_lock})"

  @spec schema(pos_integer()) :: [String.t()]
  def schema(dims) when is_integer(dims) and dims in 1..@max_dims do
    [
      "CREATE EXTENSION IF NOT EXISTS vector",
      "CREATE TABLE schema_version (version int NOT NULL, model text NOT NULL, dims int NOT NULL)",
      """
      CREATE TABLE memories (
        id bigserial PRIMARY KEY,
        kind text NOT NULL,
        scope text,
        text text NOT NULL,
        refs jsonb NOT NULL DEFAULT '[]',
        embedding vector(#{dims}),
        tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
        source_task text,
        created_at timestamptz NOT NULL DEFAULT now(),
        superseded_by bigint REFERENCES memories (id)
      )
      """,
      embedding_index(),
      "CREATE INDEX memories_tsv_idx ON memories USING gin (tsv)",
      "CREATE INDEX memories_scope_live_idx ON memories (scope) WHERE superseded_by IS NULL",
      """
      CREATE TABLE tasks (
        id bigserial PRIMARY KEY,
        name text NOT NULL UNIQUE,
        started_at timestamptz NOT NULL DEFAULT now(),
        finished_at timestamptz,
        summary text
      )
      """,
      """
      CREATE TABLE journal (
        id bigserial PRIMARY KEY,
        task_id bigint NOT NULL REFERENCES tasks (id),
        at timestamptz NOT NULL DEFAULT now(),
        entry text NOT NULL
      )
      """,
      "CREATE INDEX journal_task_idx ON journal (task_id, at)",
      """
      CREATE TABLE devices (
        id text PRIMARY KEY,
        notes text NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE captures (
        id bigserial PRIMARY KEY,
        path text NOT NULL,
        task_id bigint REFERENCES tasks (id),
        meta jsonb NOT NULL DEFAULT '{}',
        created_at timestamptz NOT NULL DEFAULT now()
      )
      """
    ]
  end

  @spec embedding_index() :: String.t()
  def embedding_index,
    do: "CREATE INDEX memories_embedding_idx ON memories USING hnsw (embedding vector_cosine_ops)"

  # A new width drops the column with its index; the rows keep everything
  # else and are refilled.
  @spec resize(pos_integer()) :: [String.t()]
  def resize(dims) when is_integer(dims) and dims in 1..@max_dims do
    [
      "ALTER TABLE memories DROP COLUMN embedding",
      "ALTER TABLE memories ADD COLUMN embedding vector(#{dims})",
      embedding_index()
    ]
  end

  defp live(prefix \\ ""),
    do: "#{prefix}superseded_by IS NULL AND #{prefix}kind <> 'tombstone'"

  @doc """
  The nearest live rows by cosine distance. Relaxed iterative scan keeps
  the HNSW scan going past `ef_search` when the filters discard candidates,
  at the price of slightly out-of-order rows, which the materialized CTE's
  outer sort puts back. `+ 0` stops Postgres 17 from treating that sort as
  already satisfied by the index order (pgvector's README).
  """
  @spec vector_recall(boolean()) :: String.t()
  def vector_recall(scoped?) do
    scope = if scoped?, do: " AND scope = $3", else: ""

    """
    WITH relaxed AS MATERIALIZED (
      SELECT id, embedding <=> $1 AS d FROM memories
      WHERE #{live()} AND embedding IS NOT NULL#{scope}
      ORDER BY embedding <=> $1 LIMIT $2
    )
    SELECT id FROM relaxed ORDER BY d + 0, id DESC
    """
  end

  @doc "Settings the vector query needs, local to its transaction."
  @spec scan_settings() :: String.t()
  def scan_settings,
    do:
      "SELECT set_config('hnsw.iterative_scan', 'relaxed_order', true), " <>
        "set_config('hnsw.ef_search', $1, true)"

  @spec keyword_recall(boolean()) :: String.t()
  def keyword_recall(scoped?) do
    scope = if scoped?, do: " AND m.scope = $3", else: ""

    """
    SELECT m.id FROM memories m CROSS JOIN websearch_to_tsquery('english', $1) q
    WHERE m.tsv @@ q AND #{live("m.")}#{scope}
    ORDER BY ts_rank_cd(m.tsv, q) DESC, m.id DESC LIMIT $2
    """
  end

  @spec fetch_rows() :: String.t()
  def fetch_rows,
    do: "SELECT id, kind, scope, text, created_at, source_task FROM memories WHERE id = ANY($1)"

  @spec model_for_share() :: String.t()
  def model_for_share, do: "SELECT model, dims FROM schema_version FOR SHARE"

  @spec model_for_update() :: String.t()
  def model_for_update, do: "SELECT model, dims FROM schema_version FOR UPDATE"

  @spec insert_memory() :: String.t()
  def insert_memory,
    do:
      "INSERT INTO memories (kind, scope, text, refs, embedding, source_task) " <>
        "VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, created_at"

  # A tombstone or an already superseded row cannot be forgotten again.
  @spec supersede() :: String.t()
  def supersede,
    do: "UPDATE memories SET superseded_by = $2 WHERE id = $1 AND #{live()} RETURNING id"

  @spec live_scope() :: String.t()
  def live_scope,
    do: "SELECT scope FROM memories WHERE id = $1 AND #{live()} FOR UPDATE"

  @spec upsert_task() :: String.t()
  def upsert_task,
    do:
      "INSERT INTO tasks (name) VALUES ($1) " <>
        "ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id"

  @spec finish_task() :: String.t()
  def finish_task,
    do: "UPDATE tasks SET summary = $2, finished_at = now() WHERE id = $1"

  @spec insert_journal() :: String.t()
  def insert_journal,
    do: "INSERT INTO journal (task_id, entry) VALUES ($1, $2) RETURNING id, at"

  # Notes accumulate; the WHERE keeps the row inside the cap, and an update
  # it refuses returns no row.
  @spec append_device_note(pos_integer()) :: String.t()
  def append_device_note(cap) when is_integer(cap) do
    """
    INSERT INTO devices AS d (id, notes) VALUES ($1, $2)
    ON CONFLICT (id) DO UPDATE
      SET notes = d.notes || E'\\n' || EXCLUDED.notes, updated_at = now()
      WHERE octet_length(d.notes) + 1 + octet_length(EXCLUDED.notes) <= #{cap}
    RETURNING id, updated_at
    """
  end

  @spec insert_capture() :: String.t()
  def insert_capture,
    do: "INSERT INTO captures (path, task_id, meta) VALUES ($1, $2, $3) RETURNING id, created_at"

  @spec unembedded_batch() :: String.t()
  def unembedded_batch,
    do:
      "SELECT id, text FROM memories WHERE embedding IS NULL AND #{live()} AND id > $1 " <>
        "ORDER BY id LIMIT $2"

  @spec set_embedding() :: String.t()
  def set_embedding,
    do: "UPDATE memories SET embedding = $2 WHERE id = $1 AND embedding IS NULL"

  @spec clear_embeddings() :: String.t()
  def clear_embeddings, do: "UPDATE memories SET embedding = NULL WHERE embedding IS NOT NULL"

  @spec switch_model() :: String.t()
  def switch_model, do: "UPDATE schema_version SET model = $1, dims = $2"

  @spec counts() :: String.t()
  def counts do
    """
    SELECT
      (SELECT count(*) FROM memories WHERE #{live()}),
      (SELECT count(*) FROM memories WHERE #{live()} AND embedding IS NULL),
      (SELECT count(*) FROM memories WHERE superseded_by IS NOT NULL),
      (SELECT count(*) FROM memories WHERE kind = 'tombstone'),
      (SELECT count(*) FROM tasks),
      (SELECT count(*) FROM journal),
      (SELECT count(*) FROM devices),
      (SELECT count(*) FROM captures)
    """
  end
end
