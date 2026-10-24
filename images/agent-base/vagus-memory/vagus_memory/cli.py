from __future__ import annotations

import argparse
import json
import logging
import sys

from .embed import FastEmbedder
from .store import Store


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="memory", description="Board-local agent memory.")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("recall")
    r.add_argument("query")
    r.add_argument("--scope")
    r.add_argument("-k", type=int, default=8)
    r.add_argument("--json", action="store_true")
    m = sub.add_parser("remember")
    m.add_argument("kind")
    m.add_argument("scope")
    m.add_argument("text")
    j = sub.add_parser("journal")
    j.add_argument("task")
    j.add_argument("entry")
    f = sub.add_parser("forget")
    f.add_argument("id", type=int)
    f.add_argument("reason")
    sub.add_parser("status")
    e = sub.add_parser("reembed", help="re-embed every live memory with a new model")
    e.add_argument("--model", help="defaults to VAGUS_MEMORY_MODEL")
    a = p.parse_args(argv)

    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    store = Store(embedder=FastEmbedder(a.model)) if a.cmd == "reembed" else Store()
    try:
        if a.cmd == "recall":
            hits = store.recall(a.query, a.scope, a.k)
            if a.json:
                print(json.dumps(hits, indent=2))
            else:
                for h in hits:
                    print(
                        f"#{h['id']} [{h['kind']}/{h['scope']}] {h['score']:.4f} "
                        f"{h['created_at'][:19]} {h['source_task']}\n  {h['text']}"
                    )
        elif a.cmd == "remember":
            print(store.remember(a.kind, a.scope, a.text))
        elif a.cmd == "journal":
            print(store.journal(a.task, a.entry))
        elif a.cmd == "forget":
            print(store.forget(a.id, a.reason))
        elif a.cmd == "reembed":
            print(f"re-embedded {store.reembed()} memories with {store.embedder.model}")
        else:
            print(json.dumps(store.status(), indent=2, default=str))
    except LookupError as e:
        print(f"memory: {e}", file=sys.stderr)
        return 1
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
