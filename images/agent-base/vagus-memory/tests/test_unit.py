import pytest

from vagus_memory.store import (
    candidate_pool,
    clamp_k,
    keyword_sql,
    rrf,
    schema_ddl,
    semantic_sql,
    vector_literal,
)


def test_rrf_rewards_agreement_over_a_single_top_rank() -> None:
    fused = rrf([[1, 2, 3], [3, 4]])
    assert fused[0][0] == 3
    assert [i for i, _ in fused] == [3, 1, 4, 2]
    assert fused[0][1] == pytest.approx(1 / 63 + 1 / 61)


def test_rrf_ties_prefer_newer_id() -> None:
    assert [i for i, _ in rrf([[5], [9]])] == [9, 5]


def test_rrf_empty() -> None:
    assert rrf([[], []]) == []


@pytest.mark.parametrize("build", [semantic_sql, keyword_sql])
def test_candidate_sql_excludes_superseded_and_tombstones(build) -> None:
    for scoped in (False, True):
        sql = build(scoped)
        assert "superseded_by IS NULL" in sql
        assert "kind <> 'tombstone'" in sql
        assert ("scope = %(scope)s" in sql) is scoped
        assert "LIMIT %(pool)s" in sql


def test_semantic_sql_uses_cosine_over_embedded_rows() -> None:
    sql = semantic_sql(False)
    assert "embedding <=> %(qvec)s::vector" in sql
    assert "embedding IS NOT NULL" in sql


def test_keyword_sql_uses_websearch_and_cover_density() -> None:
    sql = keyword_sql(False)
    assert "websearch_to_tsquery('english', %(query)s)" in sql
    assert "tsv @@ q" in sql
    assert "ts_rank_cd(tsv, q) DESC" in sql


def test_schema_ddl_sizes_vector_and_indexes() -> None:
    ddl = "\n".join(schema_ddl(384))
    assert "embedding vector(384)" in ddl
    assert "USING hnsw (embedding vector_cosine_ops)" in ddl
    assert "USING gin (tsv)" in ddl
    assert "GENERATED ALWAYS AS (to_tsvector('english', text)) STORED" in ddl


@pytest.mark.parametrize("bad", [0, -1, "384", 3.0, True])
def test_schema_ddl_rejects_bad_dims(bad) -> None:
    with pytest.raises(ValueError):
        schema_ddl(bad)


def test_vector_literal() -> None:
    assert vector_literal([1, 0.5, -2]) == "[1.0,0.5,-2.0]"


def test_rrf_with_non_default_k() -> None:
    assert rrf([[7, 8]], k=10) == [(7, pytest.approx(1 / 11)), (8, pytest.approx(1 / 12))]


@pytest.mark.parametrize(("k", "expected"), [(0, 1), (1, 1), (100, 100), (500, 100), (-3, 1)])
def test_clamp_k(k: int, expected: int) -> None:
    assert clamp_k(k) == expected


def test_candidate_pool_floor_and_ceiling() -> None:
    assert candidate_pool(1) == 200
    assert candidate_pool(clamp_k(500)) == 1000


def test_semantic_sql_resorts_relaxed_candidates() -> None:
    assert semantic_sql(False).endswith("SELECT id FROM c ORDER BY d + 0")


def test_embed_module_does_not_import_fastembed() -> None:
    import sys

    import vagus_memory.embed  # noqa: F401

    assert "fastembed" not in sys.modules
