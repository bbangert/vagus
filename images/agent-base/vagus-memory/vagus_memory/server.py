from __future__ import annotations

import logging
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP

from .store import Store

# Tool docstrings are the descriptions the model sees, so they say when to use each tool.
INSTRUCTIONS = (
    "Board-local long-term memory shared by every agent on this board. recall before "
    "starting work that may have been done before; remember durable findings (fixes, "
    "gotchas, decisions), not progress chatter."
)


def build(store: Store) -> FastMCP:
    mcp = FastMCP("vagus-memory", instructions=INSTRUCTIONS)

    @mcp.tool()
    def remember(kind: str, scope: str, text: str, refs: list[str] | None = None) -> int:
        """Store a durable memory and return its id.

        kind: e.g. fact, gotcha, decision, fix. scope: what it is about (a device id,
        a repo, "board"). refs: optional paths, URLs or memory ids it relates to.
        """
        return store.remember(kind, scope, text, refs)

    @mcp.tool()
    def recall(query: str, scope: str | None = None, k: int = 8) -> list[dict[str, Any]]:
        """Search memories by meaning and keywords; forgotten memories are excluded."""
        return store.recall(query, scope, k)

    @mcp.tool()
    def journal(task: str, entry: str) -> int:
        """Append a timestamped progress entry to a task's journal."""
        return store.journal(task, entry)

    @mcp.tool()
    def device_note(device_id: str, text: str) -> dict[str, Any]:
        """Append a timestamped note to a device's running notes."""
        return store.device_note(device_id, text)

    @mcp.tool()
    def capture_register(path: str, meta: dict[str, Any] | None = None) -> int:
        """Record a capture file (log, trace, image) produced by the current task."""
        return store.capture_register(path, meta)

    @mcp.tool()
    def forget(id: int, reason: str) -> int:
        """Hide a wrong or stale memory from recall; returns the tombstone id."""
        return store.forget(id, reason)

    return mcp


def main() -> None:
    # stdout carries the MCP protocol, so logs must go to stderr.
    logging.basicConfig(stream=sys.stderr, level=logging.INFO)
    build(Store()).run("stdio")


if __name__ == "__main__":
    main()
