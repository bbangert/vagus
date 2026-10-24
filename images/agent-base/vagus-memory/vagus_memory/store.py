from __future__ import annotations

import json
import logging
import os
import socket
from collections.abc import Iterable, Sequence
from datetime import UTC, datetime
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .embed import Embedder, FastEmbedder

log = logging.getLogger("vagus_memory")

# The address must match Vagus.Network.Agentnet.memory_ip/0; the orchestrator's
# worker-config and entrypoint.sh carry the same literal.
DEFAULT_DSN = "postgresql://agent@172.30.40.2/memory"
CONNECT_TIMEOUT_S = 5
# Bounds every statement, including the advisory-lock wait behind another worker's
# schema init, so a wedged database surfaces as a tool error instead of a hung worker.
STATEMENT_TIMEOUT = "15s"
MAX_TEXT_BYTES = 64 * 1024
MAX_LABEL_CHARS = 256
MAX_REFS = 64
MAX_K = 100
SCHEMA_VERSION = 1
# "vagusmem"; every process initialising the schema must use the same key.
SCHEMA_LOCK_KEY = 0x76616775736D656D
# Reciprocal rank fusion constant from Cormack et al.; damps the weight of top ranks
# so one list cannot dominate the fused order.
RRF_K = 60
TOMBSTONE = "tombstone"


def schema_ddl(dims: int) -> list[str]:
    if not isinstance(dims, int) or isinstance(dims, bool) or dims <= 0:
        raise ValueError(f"embedding dims must be a positive int, got {dims!r}")
    return [
        f"""CREATE TABLE memories (
            id bigserial PRIMARY KEY,
            kind text NOT NULL,
            scope text NOT NULL,
            text text NOT NULL,
            refs jsonb NOT NULL DEFAULT '[]',
            embedding vector({dims}),
            tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
            source_task text,
            created_at timestamptz NOT NULL DEFAULT now(),
            superseded_by bigint REFERENCES memories(id)
        )""",
        "CREATE INDEX memories_embedding_hnsw ON memories USING hnsw (embedding vector_cosine_ops)",
        "CREATE INDEX memories_tsv_gin ON memories USING gin (tsv)",
        "CREATE INDEX memories_live_scope ON memories (scope) WHERE superseded_by IS NULL",
        """CREATE TABLE tasks (
            id bigserial PRIMARY KEY,
            name text NOT NULL UNIQUE,
            started_at timestamptz NOT NULL DEFAULT now(),
            finished_at timestamptz,
            summary text
        )""",
        """CREATE TABLE journal (
            id bigserial PRIMARY KEY,
            task_id bigint NOT NULL REFERENCES tasks(id),
            at timestamptz NOT NULL DEFAULT now(),
            entry text NOT NULL
        )""",
        """CREATE TABLE devices (
            id text PRIMARY KEY,
            notes text NOT NULL DEFAULT '',
            updated_at timestamptz NOT NULL DEFAULT now()
        )""",
        """CREATE TABLE captures (
            id bigserial PRIMARY KEY,
            path text NOT NULL,
            task_id bigint REFERENCES tasks(id),
            meta jsonb NOT NULL DEFAULT '{}',
            created_at timestamptz NOT NULL DEFAULT now()
        )""",
    ]


def _live_filter(scoped: bool) -> str:
    where = f"superseded_by IS NULL AND kind <> '{TOMBSTONE}'"
    return where + (" AND scope = %(scope)s" if scoped else "")


def semantic_sql(scoped: bool) -> str:
    # relaxed_order iterative scans may return rows slightly out of distance order, so
    # the candidates are materialised and re-sorted, as pgvector's docs prescribe.
    return (
        "WITH c AS MATERIALIZED ("
        "SELECT id, embedding <=> %(qvec)s::vector AS d FROM memories"
        f" WHERE {_live_filter(scoped)} AND embedding IS NOT NULL"
        " ORDER BY d LIMIT %(pool)s"
        ") SELECT id FROM c ORDER BY d"
    )


def candidate_pool(k: int) -> int:
    # Each list must reach well past k for the fusion to matter: a row ranked low in
    # one list but present in both must still be a candidate. 200 floors it so small k
    # still sees enough rows, and with k <= MAX_K it stays within hnsw.ef_search's
    # 1000 ceiling.
    return max(10 * k, 200)


def clamp_k(k: int) -> int:
    return max(1, min(int(k), MAX_K))


def check_text(field: str, value: str, limit: int = MAX_TEXT_BYTES) -> None:
    size = len(value.encode())
    if size > limit:
        raise ValueError(f"{field} is {size} bytes; the limit is {limit}")


def check_label(field: str, value: str) -> None:
    if not value or len(value) > MAX_LABEL_CHARS:
        raise ValueError(f"{field} must be 1..{MAX_LABEL_CHARS} characters")


def keyword_sql(scoped: bool) -> str:
    return (
        "SELECT id FROM memories, websearch_to_tsquery('english', %(query)s) AS q"
        f" WHERE {_live_filter(scoped)} AND tsv @@ q"
        " ORDER BY ts_rank_cd(tsv, q) DESC, id DESC LIMIT %(pool)s"
    )


def vector_literal(vec: Sequence[float]) -> str:
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


def rrf(rankings: Iterable[Sequence[int]], k: int = RRF_K) -> list[tuple[int, float]]:
    scores: dict[int, float] = {}
    for ranking in rankings:
        for rank, item in enumerate(ranking, start=1):
            scores[item] = scores.get(item, 0.0) + 1.0 / (k + rank)
    # Ties go to the newer row (larger id), which is the likelier one to still be true.
    return sorted(scores.items(), key=lambda kv: (-kv[1], -kv[0]))


class Store:
    def __init__(
        self,
        dsn: str | None = None,
        embedder: Embedder | None = None,
        task: str | None = None,
    ) -> None:
        self.dsn = dsn or os.environ.get("VAGUS_MEMORY_DSN") or DEFAULT_DSN
        self.embedder: Embedder = embedder or FastEmbedder()
        self.task = task or os.environ.get("VAGUS_TASK") or socket.gethostname()
        self._conn: psycopg.Connection[dict[str, Any]] | None = None
        self.dims: int | None = None
        self.model: str | None = None

    def conn(self) -> psycopg.Connection[dict[str, Any]]:
        # Connect on first use, not at server start, so the MCP server still comes up
        # (and reports errors per call) while the memory app is down.
        if self._conn is not None and not (self._conn.closed or self._conn.broken):
            # A database restart leaves the socket looking open until it is used. The
            # ping fails on a dead session without side effects, so the real statement
            # then runs once on a fresh connection; retrying the statement itself could
            # duplicate a write whose commit outcome was lost with the connection.
            try:
                self._conn.execute("SELECT 1")
                return self._conn
            except psycopg.OperationalError:
                log.warning("memory connection lost; reconnecting")
                self.close()
        if self._conn is None or self._conn.closed or self._conn.broken:
            conn = psycopg.connect(
                self.dsn,
                autocommit=True,
                row_factory=dict_row,
                connect_timeout=CONNECT_TIMEOUT_S,
            )
            try:
                conn.execute(
                    "SELECT set_config('statement_timeout', %s, false)", (STATEMENT_TIMEOUT,)
                )
                self.ensure_schema(conn)
            except BaseException:
                conn.close()
                raise
            self._conn = conn
        return self._conn

    def close(self) -> None:
        if self._conn is not None:
            conn, self._conn = self._conn, None
            conn.close()

    def ensure_schema(self, c: psycopg.Connection[dict[str, Any]]) -> None:
        # The transaction-scoped advisory lock serialises workers that start together;
        # without it their CREATE TABLEs race on pg_type and one of them errors.
        with c.transaction():
            c.execute("SELECT pg_advisory_xact_lock(%s)", (SCHEMA_LOCK_KEY,))
            c.execute("CREATE EXTENSION IF NOT EXISTS vector")
            c.execute(
                """CREATE TABLE IF NOT EXISTS schema_version (
                    version int PRIMARY KEY,
                    model text NOT NULL,
                    dims int NOT NULL,
                    applied_at timestamptz NOT NULL DEFAULT now()
                )"""
            )
            row = c.execute(
                "SELECT version, model, dims FROM schema_version ORDER BY version DESC LIMIT 1"
            ).fetchone()
            if row is None:
                # The vector column needs its width up front, so the first worker to
                # create the schema pays one embed to learn the model's dims.
                dims = len(self.embedder.embed(["dimension probe"])[0])
                for stmt in schema_ddl(dims):
                    c.execute(stmt)
                c.execute(
                    "INSERT INTO schema_version (version, model, dims) VALUES (%s, %s, %s)",
                    (SCHEMA_VERSION, self.embedder.model, dims),
                )
                row = {"version": SCHEMA_VERSION, "model": self.embedder.model, "dims": dims}
        self.dims, self.model = row["dims"], row["model"]
        if self.model != self.embedder.model:
            log.warning(
                "schema was built for %s but embedder is %s; vectors from a different "
                "model are not comparable",
                self.model,
                self.embedder.model,
            )

    def _vector(self, fn: Any, arg: Any, fallback: str) -> str | None:
        # A failed embed must not lose the write: the row is kept without a vector and
        # recall still reaches it through full-text search.
        try:
            vec = fn(arg)
        except Exception:
            log.exception("embedding failed; %s", fallback)
            return None
        if len(vec) != self.dims:
            log.warning(
                "embedder returned %d dims, schema has %s; %s", len(vec), self.dims, fallback
            )
            return None
        return vector_literal(vec)

    def remember(self, kind: str, scope: str, text: str, refs: list[str] | None = None) -> int:
        if kind == TOMBSTONE:
            raise ValueError(f"kind {TOMBSTONE!r} is reserved for forget")
        check_label("kind", kind)
        check_label("scope", scope)
        check_text("text", text)
        refs = refs or []
        if len(refs) > MAX_REFS:
            raise ValueError(f"at most {MAX_REFS} refs")
        for r in refs:
            check_text("ref", r, 1024)
        c = self.conn()
        qvec = self._vector(lambda t: self.embedder.embed([t])[0], text, "storing without a vector")
        row = c.execute(
            """INSERT INTO memories (kind, scope, text, refs, embedding, source_task)
               VALUES (%s, %s, %s, %s, %s::vector, %s) RETURNING id""",
            (kind, scope, text, Jsonb(refs), qvec, self.task),
        ).fetchone()
        assert row is not None
        return int(row["id"])

    def recall(self, query: str, scope: str | None = None, k: int = 8) -> list[dict[str, Any]]:
        check_text("query", query)
        k = clamp_k(k)
        pool = candidate_pool(k)
        params: dict[str, Any] = {"query": query, "scope": scope, "pool": pool}
        scoped = scope is not None
        rankings: list[list[int]] = []
        c = self.conn()
        qvec = self._vector(self.embedder.embed_query, query, "recalling by keyword only")
        if qvec is not None:
            with c.transaction():
                # HNSW applies the live/scope filter after its scan; without iterative
                # scans a scope holding few of the nearest rows gets no semantic hits.
                c.execute("SELECT set_config('hnsw.iterative_scan', 'relaxed_order', true)")
                c.execute("SELECT set_config('hnsw.ef_search', %s, true)", (str(pool),))
                rows = c.execute(semantic_sql(scoped), {**params, "qvec": qvec}).fetchall()
            rankings.append([r["id"] for r in rows])
        rankings.append([r["id"] for r in c.execute(keyword_sql(scoped), params).fetchall()])
        fused = rrf(rankings)[:k]
        if not fused:
            return []
        rows = c.execute(
            """SELECT id, kind, scope, text, created_at, source_task
               FROM memories WHERE id = ANY(%s)""",
            ([i for i, _ in fused],),
        ).fetchall()
        by_id = {r["id"]: r for r in rows}
        out = []
        for mid, score in fused:
            r = by_id[mid]
            out.append({**r, "score": round(score, 6), "created_at": r["created_at"].isoformat()})
        return out

    def _one(self, sql: str, params: Any) -> dict[str, Any]:
        row = self.conn().execute(sql, params).fetchone()
        assert row is not None
        return row

    def _task_id(self, name: str) -> int:
        row = self._one(
            """INSERT INTO tasks (name) VALUES (%s)
               ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id""",
            (name,),
        )
        return int(row["id"])

    def journal(self, task: str, entry: str) -> int:
        check_label("task", task)
        check_text("entry", entry)
        tid = self._task_id(task)
        row = self._one(
            "INSERT INTO journal (task_id, entry) VALUES (%s, %s) RETURNING id", (tid, entry)
        )
        return int(row["id"])

    def device_note(self, device_id: str, text: str) -> dict[str, Any]:
        check_label("device_id", device_id)
        check_text("text", text)
        stamped = f"[{datetime.now(UTC).strftime('%Y-%m-%dT%H:%M:%SZ')}] {text}"
        row = self._one(
            """INSERT INTO devices (id, notes) VALUES (%s, %s)
               ON CONFLICT (id) DO UPDATE
               SET notes = devices.notes || E'\\n' || EXCLUDED.notes, updated_at = now()
               RETURNING id, notes, updated_at""",
            (device_id, stamped),
        )
        return {**row, "updated_at": row["updated_at"].isoformat()}

    def capture_register(self, path: str, meta: dict[str, Any] | None = None) -> int:
        check_text("path", path, 4096)
        check_text("meta", json.dumps(meta or {}))
        tid = self._task_id(self.task)
        row = self._one(
            "INSERT INTO captures (path, task_id, meta) VALUES (%s, %s, %s) RETURNING id",
            (path, tid, Jsonb(meta or {})),
        )
        return int(row["id"])

    def forget(self, memory_id: int, reason: str) -> int:
        check_text("reason", reason)
        c = self.conn()
        with c.transaction():
            target = c.execute(
                "SELECT scope FROM memories WHERE id = %s AND superseded_by IS NULL FOR UPDATE",
                (memory_id,),
            ).fetchone()
            if target is None:
                raise LookupError(f"no live memory with id {memory_id}")
            # Never deleted: the tombstone keeps who forgot what and why.
            tomb = c.execute(
                """INSERT INTO memories (kind, scope, text, refs, source_task)
                   VALUES (%s, %s, %s, %s, %s) RETURNING id""",
                (
                    TOMBSTONE,
                    target["scope"],
                    f"forgot #{memory_id}: {reason}",
                    Jsonb([str(memory_id)]),
                    self.task,
                ),
            ).fetchone()
            assert tomb is not None
            c.execute(
                "UPDATE memories SET superseded_by = %s WHERE id = %s", (tomb["id"], memory_id)
            )
        return int(tomb["id"])

    def status(self) -> dict[str, Any]:
        c = self.conn()
        sv = c.execute(
            "SELECT version, model, dims FROM schema_version ORDER BY version DESC LIMIT 1"
        ).fetchone()
        counts = c.execute(
            """SELECT
                 count(*) FILTER (WHERE superseded_by IS NULL AND kind <> %(t)s) AS live,
                 count(*) FILTER (WHERE superseded_by IS NOT NULL) AS forgotten,
                 count(*) FILTER (WHERE embedding IS NULL AND kind <> %(t)s) AS unembedded,
                 (SELECT count(*) FROM tasks) AS tasks,
                 (SELECT count(*) FROM journal) AS journal,
                 (SELECT count(*) FROM devices) AS devices,
                 (SELECT count(*) FROM captures) AS captures
               FROM memories""",
            {"t": TOMBSTONE},
        ).fetchone()
        return {"schema": sv, "embedder": self.embedder.model, "counts": counts}
