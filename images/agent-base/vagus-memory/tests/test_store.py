import logging
import string
import threading

import psycopg
import pytest

from vagus_memory.store import Store

from .conftest import DIMS, FakeEmbedder, with_options


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
    barrier = threading.Barrier(n, timeout=10)
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
        t.join(timeout=30)
    assert not any(t.is_alive() for t in threads)
    for s in stores:
        s.close()
    assert errors == []
    with psycopg.connect(dsn) as c:
        assert c.execute("SELECT count(*) FROM schema_version").fetchone() == (1,)


def test_scoped_semantic_recall_past_the_hnsw_candidate_window(base_dsn: str, schema: str) -> None:
    # A selective scope is served by the scope index; the HNSW path (scope filtered
    # after the scan) is what the planner takes for a broad one. Dropping that index and
    # seq scans forces the HNSW path on a test-sized table.
    dsn = with_options(base_dsn, f"-csearch_path={schema},public -cenable_seqscan=off")
    s = Store(dsn, FakeEmbedder(), task="t")
    s.conn().execute("DROP INDEX memories_live_scope")
    letters = string.ascii_lowercase
    # More near neighbours than the default ef_search (40) returns, all in another scope.
    for i in range(300):
        s.remember("fact", "other", f"board reboots z{letters[i % 26]}{letters[i // 26]}")
    s.remember("fact", "mine", "wifi association needs the regulatory domain set")
    target = s.remember("gotcha", "mine", "the board reboots when the fan spins up")
    hits = s.recall("device restarts", scope="mine")
    s.close()
    assert hits and hits[0]["id"] == target


def test_reconnects_after_the_session_is_killed(base_dsn: str, store: Store) -> None:
    store.remember("fact", "x", "before")
    pid = store.conn().info.backend_pid
    with psycopg.connect(base_dsn, autocommit=True) as c:
        c.execute("SELECT pg_terminate_backend(%s)", (pid,))
    mid = store.remember("fact", "x", "after the restart")
    assert store.conn().info.backend_pid != pid
    assert mid in ids(store.recall("restart"))


@pytest.mark.parametrize(
    "call",
    [
        lambda s: s.remember("fact", "x", "a" * (64 * 1024 + 1)),
        lambda s: s.journal("t", "é" * (32 * 1024 + 1)),
        lambda s: s.device_note("dev", "a" * (64 * 1024 + 1)),
        lambda s: s.recall("a" * (64 * 1024 + 1)),
        lambda s: s.remember("fact", "", "empty scope"),
        lambda s: s.remember("fact", "x", "refs", [str(i) for i in range(65)]),
    ],
)
def test_oversized_or_empty_input_is_refused(store: Store, call) -> None:
    with pytest.raises(ValueError):
        call(store)
    assert store.status()["counts"]["live"] == 0


def test_text_at_the_limit_is_accepted(store: Store) -> None:
    assert store.remember("fact", "x", "a" * (64 * 1024)) > 0


def test_tombstone_kind_is_reserved(store: Store) -> None:
    with pytest.raises(ValueError, match="reserved"):
        store.remember("tombstone", "x", "forge a tombstone")


def test_dims_mismatch_stores_null_with_warning(dsn: str, caplog) -> None:
    Store(dsn, FakeEmbedder(), task="t").conn().close()
    s = Store(dsn, FakeEmbedder(dims=DIMS + 1), task="t")
    with caplog.at_level(logging.WARNING, logger="vagus_memory"):
        mid = s.remember("fact", "q6a", "picocom needs the dialout group")
    row = s.conn().execute("SELECT embedding FROM memories WHERE id = %s", (mid,)).fetchone()
    assert row == {"embedding": None}
    assert any("dims" in r.getMessage() for r in caplog.records)
    assert ids(s.recall("picocom")) == [mid]
    s.close()


def test_mixed_null_and_embedded_rows(dsn: str) -> None:
    healthy = Store(dsn, FakeEmbedder(), task="t")
    healthy.conn()
    broken = Store(dsn, FakeEmbedder(fail=True), task="t")
    unembedded = broken.remember("fact", "q6a", "the fan header is ufshc adjacent")
    broken.close()
    paraphrase = healthy.remember("gotcha", "q6a", "the board reboots when the cooler spins")
    hits = ids(healthy.recall("ufshc or device restarts"))
    healthy.close()
    assert set(hits) == {unembedded, paraphrase}


@pytest.mark.parametrize(("k", "expected"), [(0, 1), (1, 1), (100, 100), (500, 100)])
def test_k_is_clamped(store: Store, k: int, expected: int) -> None:
    for i in range(120):
        store.remember("fact", "x", f"ufshc note {i}")
    assert len(store.recall("ufshc", k=k)) == expected


def test_model_mismatch_disables_vectors_until_reembed(dsn: str, caplog) -> None:
    old = Store(dsn, FakeEmbedder(), task="t")
    para = old.remember("gotcha", "q6a", "the board reboots when the fan spins up")
    old.close()

    # Same width on purpose: only the model name tells these vectors apart.
    new_embedder = FakeEmbedder(model="fake-v2")
    s = Store(dsn, new_embedder, task="t")
    with caplog.at_level(logging.WARNING, logger="vagus_memory"):
        kw = s.remember("fact", "q6a", "picocom needs the dialout group")
        s.remember("fact", "q6a", "picocom twice")
    assert sum("memory reembed" in r.getMessage() for r in caplog.records) == 1
    row = s.conn().execute("SELECT embedding FROM memories WHERE id = %s", (kw,)).fetchone()
    assert row == {"embedding": None}
    assert ids(s.recall("picocom dialout")) == [kw]
    assert para not in ids(s.recall("device restarts"))

    assert s.reembed(batch=1) == 3
    assert s.reembed() == 0
    st = s.status()
    assert st["schema"]["model"] == "fake-v2" and st["schema"]["dims"] == DIMS
    assert st["vectors_enabled"] and st["counts"]["unembedded"] == 0
    assert ids(s.recall("device restarts"))[0] == para
    s.close()

    # A worker still on the old model notices the switch on its next call.
    stale = Store(dsn, FakeEmbedder(), task="t")
    stale.conn()
    mid = stale.remember("fact", "q6a", "written by a stale worker")
    row = stale.conn().execute("SELECT embedding FROM memories WHERE id = %s", (mid,)).fetchone()
    assert row == {"embedding": None}
    stale.close()


def test_running_worker_adopts_a_reembed(dsn: str) -> None:
    worker = Store(dsn, FakeEmbedder(), task="w")
    worker.remember("fact", "x", "first")
    Store(dsn, FakeEmbedder(model="fake-v2"), task="m").reembed()
    mid = worker.remember("fact", "x", "after the switch")
    row = worker.conn().execute("SELECT embedding FROM memories WHERE id = %s", (mid,)).fetchone()
    assert row == {"embedding": None}
    worker.close()


def test_reembed_changes_the_vector_width(dsn: str) -> None:
    Store(dsn, FakeEmbedder(), task="t").remember("gotcha", "q6a", "the board reboots")
    s = Store(dsn, FakeEmbedder(dims=DIMS + 8, model="fake-wide"), task="t")
    assert s.reembed() == 1
    assert s.status()["schema"]["dims"] == DIMS + 8
    assert len(s.recall("device restarts")) == 1
    q = (
        "SELECT format_type(atttypid, atttypmod) AS t FROM pg_attribute"
        " WHERE attrelid = 'memories'::regclass AND attname = 'embedding'"
    )
    typ = s.conn().execute(q).fetchone()
    assert typ == {"t": f"vector({DIMS + 8})"}
    s.close()
