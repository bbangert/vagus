defmodule Vagus.Memory.SQLTest do
  use ExUnit.Case, async: true

  alias Vagus.Memory.SQL

  test "the schema sizes the vector column and indexes it for cosine" do
    statements = Enum.join(SQL.schema(384), "\n")
    assert statements =~ "CREATE EXTENSION IF NOT EXISTS vector"
    assert statements =~ "embedding vector(384)"
    assert statements =~ "USING hnsw (embedding vector_cosine_ops)"
    assert statements =~ "GENERATED ALWAYS AS (to_tsvector('english', text)) STORED"
    assert statements =~ "ON memories (scope) WHERE superseded_by IS NULL"
    assert statements =~ "superseded_by bigint REFERENCES memories (id)"
  end

  test "a width HNSW cannot index is refused" do
    assert_raise FunctionClauseError, fn -> SQL.schema(2001) end
    assert_raise FunctionClauseError, fn -> SQL.resize(0) end
  end

  test "the vector query orders inside a materialized CTE and re-sorts by d + 0" do
    sql = SQL.vector_recall(false)
    assert sql =~ "WITH relaxed AS MATERIALIZED"
    assert sql =~ "ORDER BY embedding <=> $1 LIMIT $2"
    assert sql =~ "ORDER BY d + 0"
    assert sql =~ "superseded_by IS NULL AND kind <> 'tombstone'"
    refute sql =~ "$3"
    assert SQL.vector_recall(true) =~ "AND scope = $3"
  end

  test "the keyword query filters live rows and ranks by ts_rank_cd" do
    sql = SQL.keyword_recall(true)
    assert sql =~ "websearch_to_tsquery('english', $1)"
    assert sql =~ "m.superseded_by IS NULL AND m.kind <> 'tombstone'"
    assert sql =~ "ORDER BY ts_rank_cd(m.tsv, q) DESC, m.id DESC LIMIT $2"
    assert sql =~ "AND m.scope = $3"
  end

  test "the scan settings are transaction-local" do
    assert SQL.scan_settings() =~ "set_config('hnsw.iterative_scan', 'relaxed_order', true)"
    assert SQL.scan_settings() =~ "set_config('hnsw.ef_search', $1, true)"
  end

  test "inserts read the model FOR SHARE and the switch takes it FOR UPDATE" do
    assert SQL.model_for_share() =~ "FOR SHARE"
    assert SQL.model_for_update() =~ "FOR UPDATE"
  end
end
