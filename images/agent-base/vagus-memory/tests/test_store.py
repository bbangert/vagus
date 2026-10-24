import threading

import psycopg
import pytest

from vagus_memory.store import Store

from .conftest import DIMS, FakeEmbedder


def ids(hits):
    return [h["id"] for h in hits]


def test_semantic_paraphrase_hit(store: Store) -> None:
    target = store.remember("gotcha", "q6a", "the board reboots when the fan spins up")
    store.remember("fact", "q6a", "wifi association needs the regulatory domain set")
    hits = store.recall("device restarts")
    assert hits and hits[0]["id"] == target
    assert set(hits[0]) == {"id", "kind", "scope", "text", "score", "created_at", "source_task"}
    assert hits[0]["source_task"] == "test-task"


def test_keyword_hit(store: Store) -> None:
    store.remember("fact", "q6a", "wifi association needs the regulatory domain set")
    target = store.remember("fact", "q6a", "edk2 disables ufshc on non-UFS boot")
    store.remember("fact", "rpi", "gpu_mem 16 frees memory on headless boards")
    assert store.recall("ufshc")[0]["id"] == target


def test_scope_filter(store: Store) -> None:
    store.remember("fact", "a", "ufshc probe order")
    b = store.remember("fact", "b", "ufshc probe order")
    assert ids(store.recall("ufshc", scope="b")) == [b]


def test_forget_hides_and_keeps_tombstone(store: Store) -> None:
    mid = store.remember("fact", "q6a", "ufshc is always enabled")
    tomb = store.forget(mid, "wrong: EDK2 disables it")
    assert mid not in ids(store.recall("ufshc"))
    assert tomb not in ids(store.recall("ufshc EDK2 wrong"))
    row = (
        store.conn().execute("SELECT superseded_by FROM memories WHERE id = %s", (mid,)).fetchone()
    )
    assert row == {"superseded_by": tomb}
    with pytest.raises(LookupError):
        store.forget(mid, "again")


def test_embed_failure_keeps_write_and_keyword_recall(dsn: str) -> None:
    Store(dsn, FakeEmbedder(), task="t").conn().close()  # schema built by a healthy embedder
    s = Store(dsn, FakeEmbedder(fail=True), task="t")
    mid = s.remember("fact", "q6a", "picocom needs the dialout group")
    row = s.conn().execute("SELECT embedding FROM memories WHERE id = %s", (mid,)).fetchone()
    assert row == {"embedding": None}
    assert ids(s.recall("picocom dialout")) == [mid]
    assert s.status()["counts"]["unembedded"] == 1
    s.close()


def test_journal_devices_captures(store: Store) -> None:
    j1 = store.journal("flash-q6a", "started")
    j2 = store.journal("flash-q6a", "done")
    assert j2 > j1
    store.device_note("q6a-58", "UFS 128 GB")
    notes = store.device_note("q6a-58", "fan on PoE hat")["notes"].splitlines()
    assert len(notes) == 2 and notes[0].endswith("UFS 128 GB") and notes[1].startswith("[")
    cid = store.capture_register("/work/captures/boot.log", {"board": "q6a"})
    q = "SELECT c.meta, t.name FROM captures c JOIN tasks t ON t.id = c.task_id WHERE c.id = %s"
    row = store.conn().execute(q, (cid,)).fetchone()
    assert row == {"meta": {"board": "q6a"}, "name": "test-task"}
    st = store.status()["counts"]
    assert (st["tasks"], st["journal"], st["devices"], st["captures"]) == (2, 2, 1, 1)


def test_schema_idempotent(dsn: str) -> None:
    for _ in range(3):
        s = Store(dsn, FakeEmbedder(), task="t")
        s.remember("fact", "x", "hello")
        s.close()
    with psycopg.connect(dsn) as c:
        assert c.execute("SELECT version, model, dims FROM schema_version").fetchall() == [
            (1, "fake-concepts", DIMS)
        ]
        assert c.execute("SELECT count(*) FROM memories").fetchone() == (3,)


def test_concurrent_schema_init(dsn: str) -> None:
    n = 6
    barrier = threading.Barrier(n)
    errors: list[BaseException] = []
    stores = [Store(dsn, FakeEmbedder(), task=f"w{i}") for i in range(n)]

    def start(s: Store) -> None:
        try:
            barrier.wait()
            s.conn()
        except BaseException as e:
            errors.append(e)

    threads = [threading.Thread(target=start, args=(s,)) for s in stores]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for s in stores:
        s.close()
    assert errors == []
    with psycopg.connect(dsn) as c:
        assert c.execute("SELECT count(*) FROM schema_version").fetchone() == (1,)
