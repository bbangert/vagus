"""Extract every Supervisor endpoint the Home Assistant frontend can request.

Reads a checkout of the frontend's src/ and prints the JSON that
apps/vagus/test/fixtures/frontend-<tag>-hassio-endpoints.json holds.

The frontend reaches the Supervisor through Core without a typed client: the
untyped `supervisor/api` WS proxy and the `/api/hassio/<path>` HTTP view. So
there is no model to dump, only call sites to read. The forms read here:

  callWS({type: "supervisor/api", endpoint, method})   method defaults to GET,
  supervisorApiWsRequest(conn, {endpoint, method})      as Core's WS schema does
  supervisorApiCall(hass, path, {method})
  callApi / callApiRaw("METHOD", "hassio/<path>")
  supervisorUrl("<path>")                               an <img>/download GET
  fetchHassioStats(callWS, "<prefix>")                  GET <prefix>/stats

There is no TypeScript parser in the stdlib, so this lexes rather than parses;
it understands enough (nested template literals, ternaries) to expand the log
URLs, which branch on the provider and the boot inside one template.

FAILS VISIBLY. An endpoint whose path or method cannot be read out of the
source — a variable endpoint, a first segment chosen at runtime — is emitted
with `"raw": true` and its source text, never dropped: a dropped endpoint reads
exactly like "the frontend does not call this".
"""

import json
import re
import sys
from itertools import product
from pathlib import Path

TRIGGERS = (
    "supervisor/api",
    "supervisorApiCall",
    "supervisorApiWsRequest",
    "supervisorUrl",
    "fetchHassioStats",
    "hassio/",
)

PUNCT3 = ("===", "!==", "...", "??=", "**=")
PUNCT2 = ("=>", "?.", "??", "==", "!=", "&&", "||", "<=", ">=", "++", "--", "+=", "-=")
# After these a `/` starts a regex literal rather than dividing.
REGEX_AFTER_PUNCT = set("(,=:[!&|?{};+-*%<>~^") | {"=>", "&&", "||", "??", "===", "!==", "==", "!="}
REGEX_AFTER_WORD = {"return", "typeof", "case", "do", "else", "in", "of", "yield", "await", "void"}

RAW = object()


class Tok:
    __slots__ = ("kind", "value", "start", "end")

    def __init__(self, kind, value, start, end):
        self.kind, self.value, self.start, self.end = kind, value, start, end

    def is_p(self, value):
        return self.kind == "p" and self.value == value


def lex(text, pos=0, in_template=False):
    """Tokens up to EOF, or up to the `}` closing a template's `${`."""
    toks, depth = [], 0
    n = len(text)
    while pos < n:
        c = text[pos]
        if c.isspace():
            pos += 1
        elif text.startswith("//", pos):
            pos = text.find("\n", pos)
            pos = n if pos < 0 else pos
        elif text.startswith("/*", pos):
            end = text.find("*/", pos + 2)
            pos = n if end < 0 else end + 2
        elif c in "\"'":
            start, pos, buf = pos, pos + 1, []
            while pos < n and text[pos] != c:
                if text[pos] == "\\":
                    pos += 1
                buf.append(text[pos])
                pos += 1
            toks.append(Tok("s", "".join(buf), start, pos + 1))
            pos += 1
        elif c == "`":
            start = pos
            parts, pos = lex_template(text, pos + 1)
            toks.append(Tok("t", parts, start, pos))
        elif c == "/" and regex_allowed(toks):
            start, pos, in_class = pos, pos + 1, False
            while pos < n and (in_class or text[pos] != "/") and text[pos] != "\n":
                if text[pos] == "\\":
                    pos += 1
                elif text[pos] == "[":
                    in_class = True
                elif text[pos] == "]":
                    in_class = False
                pos += 1
            pos += 1
            while pos < n and text[pos].isalpha():
                pos += 1
            toks.append(Tok("r", text[start:pos], start, pos))
        elif c.isalpha() or c in "_$":
            m = re.compile(r"[\w$]+").match(text, pos)
            toks.append(Tok("i", m.group(), pos, m.end()))
            pos = m.end()
        elif c.isdigit():
            m = re.compile(r"[\w.]+").match(text, pos)
            toks.append(Tok("n", m.group(), pos, m.end()))
            pos = m.end()
        else:
            if in_template and c == "}" and depth == 0:
                return toks, pos + 1
            depth += c == "{"
            depth -= c == "}"
            for width, table in ((3, PUNCT3), (2, PUNCT2)):
                if text[pos : pos + width] in table:
                    # `?.5` is a ternary on a number, not optional chaining.
                    if text[pos : pos + 2] == "?." and text[pos + 2 : pos + 3].isdigit():
                        continue
                    toks.append(Tok("p", text[pos : pos + width], pos, pos + width))
                    pos += width
                    break
            else:
                toks.append(Tok("p", c, pos, pos + 1))
                pos += 1
    return toks, pos


def lex_template(text, pos):
    """Template parts: literal strings and lexed `${…}` token lists."""
    parts, buf = [], []
    while pos < len(text):
        c = text[pos]
        if c == "\\":
            buf.append(text[pos + 1])
            pos += 2
        elif c == "`":
            parts.append("".join(buf))
            return parts, pos + 1
        elif text.startswith("${", pos):
            parts.append("".join(buf))
            buf = []
            inner, pos = lex(text, pos + 2, in_template=True)
            parts.append(inner)
        else:
            buf.append(c)
            pos += 1
    raise SyntaxError("unterminated template literal")


def regex_allowed(toks):
    if not toks:
        return True
    last = toks[-1]
    if last.kind == "p":
        return last.value in REGEX_AFTER_PUNCT
    return last.kind == "i" and last.value in REGEX_AFTER_WORD


def matching(toks):
    """Index of each bracket's partner, so calls and objects can be sliced."""
    pairs, stack = {}, []
    for i, tok in enumerate(toks):
        if tok.kind == "p" and tok.value in "([{":
            stack.append(i)
        elif tok.kind == "p" and tok.value in ")]}" and stack:
            j = stack.pop()
            pairs[i], pairs[j] = j, i
    return pairs


def split_top(toks, sep):
    """Split a token slice on `sep` outside any bracket."""
    out, cur, depth = [], [], 0
    for tok in toks:
        if tok.kind == "p" and tok.value in "([{":
            depth += 1
        elif tok.kind == "p" and tok.value in ")]}":
            depth -= 1
        if depth == 0 and tok.is_p(sep):
            out.append(cur)
            cur = []
        else:
            cur.append(tok)
    out.append(cur)
    return out


def ternary(toks):
    """(cond, a, b) for a top-level `c ? a : b`, else None."""
    depth, q = 0, None
    for i, tok in enumerate(toks):
        if tok.kind == "p" and tok.value in "([{":
            depth += 1
        elif tok.kind == "p" and tok.value in ")]}":
            depth -= 1
        elif depth == 0 and tok.is_p("?"):
            q = i
            break
    if q is None:
        return None
    depth, nested = 0, 0
    for i in range(q + 1, len(toks)):
        tok = toks[i]
        if tok.kind == "p" and tok.value in "([{":
            depth += 1
        elif tok.kind == "p" and tok.value in ")]}":
            depth -= 1
        elif depth == 0 and tok.is_p("?"):
            nested += 1
        elif depth == 0 and tok.is_p(":"):
            if nested == 0:
                return toks[:q], toks[q + 1 : i], toks[i + 1 :]
            nested -= 1
    return None


def placeholder(name):
    name = name.lower()
    if name == "addon" or "slug" in name:
        return "{slug}"
    if "version" in name:
        return "{version}"
    if "token" in name:
        return "{token}"
    return "{param}"


def alternatives(toks):
    """Every string an expression can evaluate to, `${x}` as a placeholder.

    Each alternative is a list of str pieces, or contains RAW when some piece
    is not knowable from the source.
    """
    while len(toks) >= 2 and toks[0].is_p("(") and toks[-1].is_p(")"):
        toks = toks[1:-1]
    split = ternary(toks)
    if split:
        return alternatives(split[1]) + alternatives(split[2])
    if len(toks) == 1 and toks[0].kind == "s":
        return [[toks[0].value]]
    if len(toks) == 1 and toks[0].kind == "t":
        options = []
        for part in toks[0].value:
            if isinstance(part, str):
                options.append([[part]])
            else:
                options.append(interpolation(part))
        return [[piece for alt in combo for piece in alt] for combo in product(*options)]
    return [[RAW]]


def interpolation(toks):
    """A `${…}`: a member chain names a placeholder; anything else must evaluate."""
    if toks and all(t.kind == "i" or t.is_p(".") or t.is_p("?.") for t in toks) and toks[-1].kind == "i":
        return [[placeholder(toks[-1].value)]]
    return alternatives(toks)


def source_text(text, toks):
    return " ".join(text[toks[0].start : toks[-1].end].split()) if toks else ""


def normalise(pieces, require_hassio):
    """A Supervisor path, or None when it is not one, or RAW."""
    if RAW in pieces:
        return RAW
    path = "".join(pieces).split("?", 1)[0]
    if require_hassio:
        if not path.startswith("hassio/"):
            return None
        path = path[len("hassio/") :]
    path = "/" + path.lstrip("/")
    path = path.rstrip("/") or "/"
    segments = path.split("/")[1:]
    # A runtime-chosen first segment (`/${container}/stats`) could be any
    # surface, so no route can be said to serve it.
    if not segments or segments[0].startswith("{") or "" in segments:
        return RAW
    if "{" in path and not re.fullmatch(r"(/([\w.-]+|\{\w+\}))+", path):
        return RAW
    return path


def call_args(toks, pairs, i):
    """Args of a call whose callee identifier is toks[i], skipping `<T>`."""
    j = i + 1
    if j < len(toks) and toks[j].is_p("<"):
        depth = 0
        while j < len(toks):
            if toks[j].is_p("<"):
                depth += 1
            elif toks[j].is_p(">"):
                depth -= 1
                if depth == 0:
                    break
            j += 1
        j += 1
    if j >= len(toks) or not toks[j].is_p("(") or j not in pairs:
        return None
    return split_top(toks[j + 1 : pairs[j]], ",")


def object_keys(toks):
    """Top-level `key: value` pairs of an object literal's inner tokens."""
    keys = {}
    for entry in split_top(toks, ","):
        if len(entry) >= 2 and entry[0].kind in "is" and entry[1].is_p(":"):
            keys[entry[0].value] = entry[2:]
        elif len(entry) == 1 and entry[0].kind == "i":
            keys[entry[0].value] = None
    return keys


def method_of(value):
    if value is None:
        return "GET"
    if len(value) == 1 and value[0].kind == "s":
        return value[0].value.upper()
    return None


class Extractor:
    def __init__(self, text, where, constants):
        self.text, self.where, self.constants = text, where, constants
        self.found = []

    def emit(self, method, expr, alts, require_hassio=False, suffix=""):
        for alt in alts:
            path = normalise(alt + [suffix], require_hassio)
            if path is None:
                continue
            if path is RAW or method is None:
                self.found.append(
                    {
                        "method": method or "UNKNOWN",
                        "path": source_text(self.text, expr) + suffix,
                        "raw": True,
                        "source": self.where,
                    }
                )
            else:
                self.found.append({"method": method, "path": path, "source": self.where})

    def endpoint_alts(self, value):
        # `endpoint: table[key]` names a module-level object of literal paths.
        if len(value) >= 2 and value[0].kind == "i" and value[1].is_p("[") and value[0].value in self.constants:
            return [[v] for v in self.constants[value[0].value]]
        return alternatives(value)

    def walk(self, toks):
        pairs = matching(toks)
        for i, tok in enumerate(toks):
            if tok.kind == "t":
                for part in tok.value:
                    if not isinstance(part, str):
                        self.walk(part)
            elif tok.is_p("{") and i in pairs:
                self.request_object(toks, pairs, i)
            elif tok.kind == "i":
                self.call(toks, pairs, i)

    def request_object(self, toks, pairs, i):
        keys = object_keys(toks[i + 1 : pairs[i]])
        kind = keys.get("type")
        if kind and len(kind) == 1 and kind[0].kind == "s" and kind[0].value == "supervisor/api":
            self.request(keys)

    def request(self, keys):
        if "endpoint" not in keys:
            return
        value = keys["endpoint"]
        method = method_of(keys.get("method"))
        if value is None:
            self.found.append(
                {"method": method or "UNKNOWN", "path": "{ endpoint }", "raw": True, "source": self.where}
            )
        else:
            self.emit(method, value, self.endpoint_alts(value))

    def call(self, toks, pairs, i):
        name = toks[i].value
        if name not in (
            "supervisorApiCall",
            "supervisorApiWsRequest",
            "callApi",
            "callApiRaw",
            "supervisorUrl",
            "fetchHassioStats",
        ):
            return
        args = call_args(toks, pairs, i)
        if not args or not args[0]:
            return
        if name == "supervisorApiWsRequest" and len(args) >= 2:
            # Its object carries no `type`: the helper merges that in.
            if args[1] and args[1][0].is_p("{") and args[1][-1].is_p("}"):
                self.request(object_keys(args[1][1:-1]))
            else:
                self.emit(None, args[1], [[RAW]])
        elif name == "supervisorApiCall" and len(args) >= 2:
            method = "GET"
            if len(args) >= 3 and args[2] and args[2][0].is_p("{"):
                method = method_of(object_keys(args[2][1:-1]).get("method"))
            elif len(args) >= 3 and args[2]:
                method = None
            self.emit(method, args[1], alternatives(args[1]))
        elif name in ("callApi", "callApiRaw") and len(args) >= 2:
            alts = alternatives(args[1])
            if any(RAW in alt for alt in alts) and "hassio" not in source_text(self.text, args[1]):
                return
            self.emit(method_of(args[0]), args[1], alts, require_hassio=True)
        elif name == "supervisorUrl":
            self.emit("GET", args[0], alternatives(args[0]))
        elif name == "fetchHassioStats" and len(args) >= 2:
            self.emit("GET", args[1], alternatives(args[1]), suffix="/stats")


def literal_tables(toks):
    """`const NAME = { key: "literal", … }` at any depth, by name."""
    pairs, tables = matching(toks), {}
    for i in range(len(toks) - 3):
        if toks[i].kind == "i" and toks[i + 1].is_p("=") and toks[i + 2].is_p("{") and (i + 2) in pairs:
            values = object_keys(toks[i + 3 : pairs[i + 2]]).values()
            if values and all(v and len(v) == 1 and v[0].kind == "s" for v in values):
                tables[toks[i].value] = [v[0].value for v in values]
    return tables


def main() -> int:
    src = Path(sys.argv[1])
    tag = sys.argv[2]
    root = src.parent

    endpoints, silent = [], []
    for path in sorted(src.rglob("*.ts")):
        text = path.read_text(errors="ignore")
        if not any(t in text for t in TRIGGERS):
            continue
        where = str(path.relative_to(root))
        toks, _ = lex(text)
        extractor = Extractor(text, where, literal_tables(toks))
        extractor.walk(toks)
        endpoints += extractor.found
        if '"supervisor/api"' in text and not extractor.found:
            silent.append(where)

    # A module that builds `supervisor/api` requests but yielded none means the
    # extractor no longer understands its shape.
    if silent or not endpoints:
        print(f"no endpoints read from: {silent or src}", file=sys.stderr)
        return 2

    unique = {json.dumps(e, sort_keys=True) for e in endpoints}
    ordered = sorted((json.loads(e) for e in unique), key=lambda e: (e["path"], e["method"], e["source"]))
    json.dump(
        {
            "_frontend": tag,
            "_source": f"home-assistant/frontend src/**/*.ts at tag {tag}",
            "endpoints": ordered,
        },
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
