"""Extract Core's Supervisor-integration surface from its source, by AST.

Reads a checkout of homeassistant/components/hassio/ and prints the JSON that
apps/vagus/test/fixtures/core-<tag>-hassio-views.json holds: every view URL the
integration registers, and every WebSocket command type it registers.

Three properties, each of which exists because the alternative fails open — the
same way the bug this whole fixture guards against did.

EXTRACTS EVERYTHING. No filter on command domain. Filtering here to the names
Vagus.Core.Reserved already accepts would make the fixture — and so the contract
test and the weekly drift workflow — incapable of reporting the one thing they
exist to report: Core registering a Supervisor-privileged endpoint under a name
the reservation does not cover. Deciding which extracted names are reserved is
reserved_contract_test.exs's job, and a failure there is a design question, not
a fixture update. (URLs keep a `/api/` filter, which is a REACHABILITY bound
rather than a reservation one: a view outside `/api/` cannot be addressed
through `/core/api/*` at all, so it is not part of this surface.)

FAILS CLOSED. A registration whose type or url cannot be resolved — a schema
that is not an inline dict, a constant defined somewhere this does not read, an
f-string — raises rather than being skipped. Skipping would shrink the fixture
silently, and a shrinking fixture reads exactly like "Core registers nothing
new". Support for a new shape is then added deliberately, having been told.

RESOLVES CONSTANTS. `@websocket_api.websocket_command({vol.Required(WS_TYPE):
WS_TYPE_SUBSCRIBE})` names its command through two constants, and the handler it
decorates is called `websocket_supervisor_subscribe` — reading either the
decorator or the handler name suggests `hassio/subscribe`, while what Core
dispatches on is `supervisor/subscribe`.
"""

import ast
import json
import sys
from pathlib import Path

WS_TYPE_KEY = "type"


class Unresolved(Exception):
    """A registration exists but its name could not be read out of the source."""


def string_constants(tree: ast.Module) -> dict[str, str]:
    """Module-level NAME = "literal" assignments, for resolving Name nodes."""
    out = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant):
            if isinstance(node.value.value, str):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        out[target.id] = node.value.value
    return out


def resolve(node: ast.AST, constants: dict[str, str]) -> str | None:
    """A string literal, or a Name bound to one. Anything else is unknowable."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return constants.get(node.id)
    return None


def unwrap_key(node: ast.AST, constants: dict[str, str]) -> str | None:
    """Schema keys are `vol.Required(X)` / `vol.Optional(X)`, or bare."""
    if isinstance(node, ast.Call) and node.args:
        return resolve(node.args[0], constants)
    return resolve(node, constants)


def command_from_schema(node: ast.AST, constants: dict[str, str]) -> str:
    if not isinstance(node, ast.Dict):
        raise Unresolved(f"schema is {type(node).__name__}, not an inline dict")

    for key, value in zip(node.keys, node.values):
        if key is not None and unwrap_key(key, constants) == WS_TYPE_KEY:
            command = resolve(value, constants)
            if command is None:
                raise Unresolved("`type` value is not a literal or a known constant")
            return command

    raise Unresolved("schema has no `type` key")


def collect(tree: ast.Module, constants: dict[str, str], where: str) -> tuple[set[str], set[str]]:
    urls, commands = set(), set()

    # Views declare `url` as a class attribute. Scoped to the class body on
    # purpose: `ingress.py` has a legitimate local `url = self._create_url(...)`
    # inside a method, and failing closed on every unresolvable `url` name would
    # trip over it.
    #
    # EVERY class, not just ones whose base looks like a View. Matching bases by
    # name misses a subclass of a subclass — `HassIOAuth(HassIOBaseAuth)`, whose
    # base is itself the `HomeAssistantView` — which silently dropped
    # `/api/hassio_auth` and `/api/hassio_auth/password_reset`, i.e. the exact
    # pair this fixture exists for. A class-level `url` is a route declaration
    # whoever declares it.
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            for stmt in node.body:
                if not isinstance(stmt, ast.Assign):
                    continue
                if not any(isinstance(t, ast.Name) and t.id == "url" for t in stmt.targets):
                    continue

                url = resolve(stmt.value, constants)
                if url is None:
                    raise Unresolved(
                        f"{where}:{stmt.lineno}: {node.name}.url is not a literal or a known constant"
                    )
                if url.startswith("/api/"):
                    urls.add(url)

    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
            if name != "websocket_command":
                continue
            if not node.args:
                raise Unresolved(f"{where}:{node.lineno}: websocket_command() with no schema")
            try:
                commands.add(command_from_schema(node.args[0], constants))
            except Unresolved as err:
                raise Unresolved(f"{where}:{node.lineno}: {err}") from err

    return urls, commands


def main() -> int:
    src, version = Path(sys.argv[1]), sys.argv[2]

    # rglob, and keyed by path relative to the component root: Core adding a
    # subpackage would otherwise collide basenames (every `__init__.py`, and any
    # second `websocket_api.py`) and drop a module's whole surface.
    sources = sorted(src.rglob("*.py"))
    if not sources:
        print(f"no python sources under {src}", file=sys.stderr)
        return 1

    trees = {path.relative_to(src): ast.parse(path.read_text(errors="ignore")) for path in sources}

    # One constants map across the whole integration: the WS_TYPE_* values live
    # in const.py while the schemas that reference them live in websocket_api.py.
    constants: dict[str, str] = {}
    for tree in trees.values():
        constants.update(string_constants(tree))

    urls: set[str] = set()
    commands: set[str] = set()
    for where, tree in trees.items():
        file_urls, file_commands = collect(tree, constants, str(where))
        urls |= file_urls
        commands |= file_commands

    json.dump(
        {
            "_core_version": version,
            "_source": f"homeassistant/components/hassio/**/*.py at tag {version}",
            "urls": sorted(urls),
            "ws_commands": sorted(commands),
        },
        sys.stdout,
        indent=2,
    )
    print()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Unresolved as err:
        print(f"unresolvable registration: {err}", file=sys.stderr)
        print(
            "Extraction stops rather than emitting a fixture that is quietly "
            "missing an endpoint. Teach the extractor this shape, then rerun.",
            file=sys.stderr,
        )
        raise SystemExit(2) from None
