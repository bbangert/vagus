"""Extract Core's Supervisor-integration surface from its source, by AST.

Reads homeassistant/components/hassio/*.py and prints the JSON that
apps/vagus/test/fixtures/core-<tag>-hassio-views.json holds: every view URL
the integration registers, and every WebSocket command type it registers.

Deliberately extracts EVERY command, with no filter on domain. Filtering here
to the names Vagus.Core.Reserved already accepts would make the fixture — and
so the contract test and the weekly drift workflow — incapable of reporting the
one thing they exist to report: Core registering a Supervisor-privileged
endpoint under a name the reservation does not cover. Deciding which extracted
names are reserved is reserved_contract_test.exs's job, and a failure there is
a design question, not a fixture update.

AST rather than grep for the same reason the caller resolves constants:
`@websocket_api.websocket_command({vol.Required(WS_TYPE): WS_TYPE_SUBSCRIBE})`
names its command through two constants, and the handler it decorates is called
`websocket_supervisor_subscribe` — reading either the decorator or the handler
name suggests `hassio/subscribe`, while what Core dispatches on is
`supervisor/subscribe`. Only resolving the constant gets this right.
"""

import ast
import json
import sys
from pathlib import Path

WS_TYPE_KEY = "type"


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


def command_from_schema(node: ast.AST, constants: dict[str, str]) -> str | None:
    if not isinstance(node, ast.Dict):
        return None
    for key, value in zip(node.keys, node.values):
        if key is not None and unwrap_key(key, constants) == WS_TYPE_KEY:
            return resolve(value, constants)
    return None


def collect(tree: ast.Module, constants: dict[str, str]) -> tuple[set[str], set[str]]:
    urls, commands = set(), set()

    for node in ast.walk(tree):
        # Views: `url = "/api/..."`, a HomeAssistantView class attribute.
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "url":
                    url = resolve(node.value, constants)
                    if url and url.startswith("/api/"):
                        urls.add(url)

        # Commands: any `websocket_command(<schema>)` call, decorator or not.
        if isinstance(node, ast.Call):
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
            if name == "websocket_command" and node.args:
                command = command_from_schema(node.args[0], constants)
                if command:
                    commands.add(command)

    return urls, commands


def main() -> int:
    src, version = Path(sys.argv[1]), sys.argv[2]
    trees = {path: ast.parse(path.read_text(errors="ignore")) for path in sorted(src.glob("*.py"))}

    # One constants map across the whole integration: the WS_TYPE_* values live
    # in const.py while the schemas that reference them live in websocket_api.py.
    constants: dict[str, str] = {}
    for tree in trees.values():
        constants.update(string_constants(tree))

    urls: set[str] = set()
    commands: set[str] = set()
    for tree in trees.values():
        file_urls, file_commands = collect(tree, constants)
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
    raise SystemExit(main())
