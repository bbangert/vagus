from __future__ import annotations

import hashlib
import os
import re
import uuid
from collections.abc import Iterator, Sequence

import psycopg
import pytest

from vagus_memory.store import Store

DIMS = 16
# Paraphrases share a concept bucket but no English stem, so a hit between them can
# only have come from the vector side.
CONCEPTS = {
    "board": 0,
    "device": 0,
    "reboot": 1,
    "reboots": 1,
    "restart": 1,
    "restarts": 1,
    "fan": 2,
    "cooler": 2,
}


class FakeEmbedder:
    model = "fake-concepts"

    def __init__(self, fail: bool = False) -> None:
        self.fail = fail

    def _vec(self, text: str) -> list[float]:
        if self.fail:
            raise RuntimeError("embedder down")
        v = [0.0] * DIMS
        v[DIMS - 1] = 0.1  # never the zero vector, whose cosine distance is NaN
        for w in re.findall(r"[a-z]+", text.lower()):
            i = CONCEPTS.get(w)
            if i is None:
                i = 3 + int(hashlib.sha1(w.encode()).hexdigest(), 16) % (DIMS - 4)
            v[i] += 1.0
        return v

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        return [self._vec(t) for t in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._vec(text)


@pytest.fixture
def dsn() -> Iterator[str]:
    base = os.environ.get("VAGUS_MEMORY_TEST_DSN")
    if not base:
        pytest.skip("set VAGUS_MEMORY_TEST_DSN to a throwaway pgvector Postgres to run")
    # A fresh schema per test isolates tables while the vector extension stays shared.
    schema = f"t_{uuid.uuid4().hex[:12]}"
    with psycopg.connect(base, autocommit=True) as c:
        c.execute("CREATE EXTENSION IF NOT EXISTS vector")
        c.execute(f"CREATE SCHEMA {schema}")
    sep = "&" if "?" in base else "?"
    yield f"{base}{sep}options=-csearch_path%3D{schema},public"
    with psycopg.connect(base, autocommit=True) as c:
        c.execute(f"DROP SCHEMA {schema} CASCADE")


@pytest.fixture
def store(dsn: str) -> Iterator[Store]:
    s = Store(dsn, FakeEmbedder(), task="test-task")
    yield s
    s.close()
