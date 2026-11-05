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

FAILS CLOSED. An endpoint whose path or method cannot be read out of the
source — a variable endpoint or verb, a first segment chosen at runtime, a
spread that may add a path or override one — is emitted with `"raw": true` and
its source text (and a `reason` where the text alone does not say why), never
dropped: a dropped endpoint reads exactly like "the frontend does not call
this". scripts/test_frontend_hassio_endpoints.py pins each such case, and
core-contract-drift.yml runs it:

  python3 -I scripts/test_frontend_hassio_endpoints.py
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
        # `${base}/x` may well be `hassio/x`.
        if path.lstrip("/").startswith("{"):
            return RAW
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


def object_entries(toks):
    """An object literal's top-level entries, in order: ("key", name, value) or
    ("spread", tokens). Shorthand `{ a }` keeps `a`'s own token as its value."""
    entries = []
    for entry in split_top(toks, ","):
        if entry and entry[0].is_p("..."):
            entries.append(("spread", entry[1:]))
        elif len(entry) >= 2 and entry[0].kind in "is" and entry[1].is_p(":"):
            entries.append(("key", entry[0].value, entry[2:]))
        elif len(entry) == 1 and entry[0].kind == "i":
            entries.append(("key", entry[0].value, entry))
    return entries


def object_keys(toks):
    return {e[1]: e[2] for e in object_entries(toks) if e[0] == "key"}


def method_of(value):
    """None (omitted) is GET, as Core's WS schema defaults it; any non-literal
    is unknowable (None back), shorthand `{ method }` included."""
    if value is None:
        return "GET"
    if len(value) == 1 and value[0].kind == "s":
        return value[0].value.upper()
    return None


REQUEST_KEYS = ("type", "endpoint", "method")


class Extractor:
    def __init__(self, text, where, tables, strings):
        self.text, self.where, self.tables, self.strings = text, where, tables, strings
        # A file that reaches the Supervisor any other way may build its
        # `hassio/` HTTP path anywhere: one that cannot be read must not be dropped.
        self.supervisor_file = any(t in text for t in TRIGGERS)
        self.found = []

    def raw(self, method, path, reason=None):
        entry = {"method": method or "UNKNOWN", "path": path, "raw": True, "source": self.where}
        if reason:
            entry["reason"] = reason
        self.found.append(entry)

    def emit(self, method, expr, alts, require_hassio=False, suffix=""):
        for alt in alts:
            path = normalise(alt + [suffix], require_hassio)
            if path is None:
                continue
            if path is RAW or method is None:
                self.raw(method, source_text(self.text, expr) + suffix)
            else:
                self.found.append({"method": method, "path": path, "source": self.where})

    def table(self, name, seen=()):
        """(key -> value tokens, unresolved spread sources) of a named literal
        object, following spreads of other named objects in the file."""
        if name in seen or name not in self.tables or self.tables[name] is None:
            return None
        keys, unresolved = {}, []
        for entry in self.tables[name]:
            if entry[0] == "key":
                keys[entry[1]] = entry[2]
                continue
            spread = entry[1]
            inner = self.table(spread[0].value, seen + (name,)) if len(spread) == 1 and spread[0].kind == "i" else None
            if inner is None:
                unresolved.append(source_text(self.text, entry[1]))
            else:
                keys.update(inner[0])
                unresolved += inner[1]
        return keys, unresolved

    def endpoint_alts(self, value):
        """`table[key]` as the WHOLE expression reads a named object of literal
        paths; anything more (`table[key] + "/x"`) is not that lookup."""
        if (
            len(value) >= 4
            and value[0].kind == "i"
            and value[1].is_p("[")
            and value[-1].is_p("]")
            and matching(value).get(1) == len(value) - 1
        ):
            table = self.table(value[0].value)
            if table and all(len(v) == 1 and v[0].kind == "s" for v in table[0].values()):
                for spread in table[1]:
                    self.raw(
                        None,
                        source_text(self.text, value),
                        f"`...{spread}` in `{value[0].value}` adds paths no source names",
                    )
                return [[v[0].value] for v in table[0].values()]
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

    def spread_keys(self, toks):
        """What a spread contributes: a dict when every request key it can set
        is known (a named literal object, or inline literals that set none),
        else None."""
        if len(toks) == 1 and toks[0].kind == "i":
            table = self.table(toks[0].value)
            return table[0] if table and not table[1] else None
        while len(toks) >= 2 and toks[0].is_p("(") and toks[-1].is_p(")"):
            toks = toks[1:-1]
        split = ternary(toks)
        branches = [split[1], split[2]] if split else [toks]
        for branch in branches:
            if not (branch and branch[0].is_p("{") and branch[-1].is_p("}")):
                return None
            if any(k in REQUEST_KEYS for k in object_keys(branch[1:-1])):
                return None
        return {}

    def resolve(self, entries):
        """(request keys, unresolved spreads that may set the endpoint or method).

        An unknown spread forgets the endpoint and method before it, not the
        `type`: it can only turn a supervisor/api request into something else,
        and flagging that is the safe side."""
        keys, unresolved = {}, []
        for entry in entries:
            if entry[0] == "key":
                keys[entry[1]] = entry[2]
            else:
                spread = self.spread_keys(entry[1])
                if spread is None:
                    unresolved.append(source_text(self.text, entry[1]))
                    keys.pop("endpoint", None)
                    keys.pop("method", None)
                else:
                    keys.update(spread)
            if "endpoint" in keys and "method" in keys:
                unresolved = []
        return keys, unresolved

    def request_object(self, toks, pairs, i):
        keys, unresolved = self.resolve(object_entries(toks[i + 1 : pairs[i]]))
        kind = keys.get("type")
        if kind and len(kind) == 1 and kind[0].kind == "s" and kind[0].value == "supervisor/api":
            declared = toks[i - 2].value if i >= 2 and toks[i - 1].is_p("=") and toks[i - 2].kind == "i" else None
            self.request(keys, unresolved, declared)

    def request(self, keys, unresolved, declared=None):
        if unresolved:
            spreads = ", ".join(f"...{s}" for s in unresolved)
            where = f"the endpoint-free base command `{declared}`" if declared else "a supervisor/api call site"
            value = keys.get("endpoint")
            path = source_text(self.text, value) if value else spreads
            method = method_of(keys["method"]) if "method" in keys else None
            self.raw(method, path, f"`{spreads}` in {where} can set the endpoint or method")
            return
        if "endpoint" not in keys:
            # A shared `{type, method}` the call sites spread; not itself a call.
            if not declared:
                self.raw(method_of(keys.get("method")), "{}", "a supervisor/api call site with no endpoint")
            return
        value = keys["endpoint"]
        method = method_of(keys.get("method"))
        if len(value) == 1 and value[0].kind == "i" and value[0].value == "endpoint":
            self.raw(method, "{ endpoint }")
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
                self.request(*self.resolve(object_entries(args[1][1:-1])))
            else:
                self.emit(None, args[1], [[RAW]])
        elif name == "supervisorApiCall" and len(args) >= 2:
            method = "GET"
            if len(args) >= 3 and args[2] and args[2][0].is_p("{") and args[2][-1].is_p("}"):
                options, unresolved = self.resolve(object_entries(args[2][1:-1]))
                method = None if unresolved else method_of(options.get("method"))
            elif len(args) >= 3 and args[2]:
                method = None
            self.emit(method, args[1], alternatives(args[1]))
        elif name in ("callApi", "callApiRaw") and len(args) >= 2:
            path = args[1]
            if len(path) == 1 and path[0].kind == "i" and path[0].value in self.strings:
                alts = [[self.strings[path[0].value]]]
            else:
                alts = alternatives(path)
            # `${base}/x` could be `hassio/x`: as unreadable as a bare variable.
            unread = any(RAW in alt or "".join(alt).lstrip("/").startswith("{") for alt in alts)
            if unread and not self.supervisor_file and "hassio" not in source_text(self.text, path):
                return
            self.emit(method_of(args[0]), path, alts, require_hassio=True)
        elif name == "supervisorUrl":
            self.emit("GET", args[0], alternatives(args[0]))
        elif name == "fetchHassioStats" and len(args) >= 2:
            self.emit("GET", args[1], alternatives(args[1]), suffix="/stats")


def literal_tables(toks):
    """`NAME = { … }` at any depth, by name, as object_entries. A name bound to
    two objects maps to None: which one a lookup reads is not knowable here."""
    pairs, tables = matching(toks), {}
    for i in range(len(toks) - 3):
        if toks[i].kind == "i" and toks[i + 1].is_p("=") and toks[i + 2].is_p("{") and (i + 2) in pairs:
            name = toks[i].value
            tables[name] = None if name in tables else object_entries(toks[i + 3 : pairs[i + 2]])
    return tables


def string_constants(toks):
    """`const NAME = "literal"` that nothing else in the file can rebind.

    A second declaration, or the name as a parameter, key or assignment target
    (`name:`, `name =`, `name =>`, `name) =>`, `name?`), could shadow it at the call site,
    so such a name stays unresolved."""
    decls, rebound = {}, set()
    for i, tok in enumerate(toks):
        if tok.kind != "i":
            continue
        prev = toks[i - 1] if i else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if prev is not None and prev.kind == "i" and prev.value in ("const", "let", "var"):
            after = toks[i + 3] if i + 3 < len(toks) else None
            ends = after is None or after.kind != "p" or after.value in (";", ",", "}")
            literal = (
                prev.value == "const"
                and nxt is not None
                and nxt.is_p("=")
                and i + 2 < len(toks)
                and toks[i + 2].kind == "s"
                and ends
            )
            decls.setdefault(tok.value, []).append(toks[i + 2].value if literal else None)
        elif nxt is not None and nxt.kind == "p" and nxt.value in (":", "=", "=>", "?", ")"):
            if nxt.value != ")" or (i + 2 < len(toks) and toks[i + 2].is_p("=>")):
                rebound.add(tok.value)
    return {
        name: values[0]
        for name, values in decls.items()
        if len(values) == 1 and values[0] is not None and name not in rebound
    }


def extract(text, where):
    toks, _ = lex(text)
    extractor = Extractor(text, where, literal_tables(toks), string_constants(toks))
    extractor.walk(toks)
    return extractor.found


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
        found = extract(text, where)
        endpoints += found
        if '"supervisor/api"' in text and not found:
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
