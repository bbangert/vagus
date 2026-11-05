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

There is no TypeScript parser in the stdlib, so this lexes rather than parses.

A construct is resolved only when every part that can set its path or method
is syntax listed here: a string literal; a template literal whose `${…}` holes
are identifiers or `a.b` member chains; `cond ? <path> : <path>`; `key:
<literal>` and a verb literal for `method`; an identifier or shorthand naming
a once-declared, never-rebound `const` string; a spread of a once-declared,
never-mutated literal object, or of inline object literals (`...(c ? {} :
{…})`) that set no request key; and `table[ident]` as the whole path, over
such an object whose members are all `key: "literal"`. Anything else fails
closed: the whole construct becomes one `"raw": true` entry whose
`source_text` is its source (and any declaration it read) with whitespace
collapsed, so editing an unresolved construct always changes the output.
scripts/test_frontend_hassio_endpoints.py pins this, and
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

PUNCT3 = ("===", "!==", "...", "??=", "**=", "||=", "&&=")
PUNCT2 = ("=>", "?.", "??", "==", "!=", "&&", "||", "<=", ">=", "++", "--", "+=", "-=")
# After these a `/` starts a regex literal rather than dividing.
REGEX_AFTER_PUNCT = set("(,=:[!&|?{};+-*%<>~^") | {"=>", "&&", "||", "??", "===", "!==", "==", "!="}
REGEX_AFTER_WORD = {"return", "typeof", "case", "do", "else", "in", "of", "yield", "await", "void"}


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


class Unresolved(Exception):
    """A part of a construct outside the whitelist; the message says which."""


REQUEST_KEYS = ("type", "endpoint", "method")
VERBS = ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD")
ASSIGN = ("=", "+=", "-=", "**=", "??=", "||=", "&&=")
CALLS = ("supervisorApiCall", "supervisorApiWsRequest", "callApi", "callApiRaw", "supervisorUrl", "fetchHassioStats")


def collapse(text, toks):
    return " ".join(text[toks[0].start : toks[-1].end].split()) if toks else ""


def unwrap(toks):
    while len(toks) >= 2 and toks[0].is_p("(") and toks[-1].is_p(")") and matching(toks).get(0) == len(toks) - 1:
        toks = toks[1:-1]
    return toks


def is_object(toks):
    return len(toks) >= 2 and toks[0].is_p("{") and matching(toks).get(0) == len(toks) - 1


def is_chain(toks):
    """`a` or `a.b.c`: a value as opaque as an identifier, so it is a placeholder."""
    return (
        len(toks) % 2 == 1
        and all(t.kind == "i" for t in toks[::2])
        and all(t.is_p(".") for t in toks[1::2])
    )


def normalise(path, require_hassio):
    """A Supervisor path, or None when it is not one."""
    path = path.split("?", 1)[0]
    if require_hassio:
        if path.lstrip("/").startswith("{"):
            raise Unresolved("the path may be `hassio/…` behind a runtime prefix")
        if not path.startswith("hassio/"):
            return None
        path = path[len("hassio/") :]
    path = "/" + path.lstrip("/")
    path = path.rstrip("/") or "/"
    segments = path.split("/")[1:]
    # A runtime-chosen first segment (`/${container}/stats`) could be any
    # surface, so no route can be said to serve it.
    if not segments or segments[0].startswith("{"):
        raise Unresolved("the first path segment is chosen at runtime")
    if "" in segments or ("{" in path and not re.fullmatch(r"(/([\w.-]+|\{\w+\}))+", path)):
        raise Unresolved("a placeholder shares a segment, or a segment is empty")
    return path


def call_args(toks, pairs, i):
    """(args, index of the closing paren) of a call whose callee is toks[i], skipping `<T>`."""
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
        return None, None
    return split_top(toks[j + 1 : pairs[j]], ","), pairs[j]


def constants(toks, pairs):
    """(const strings, literal objects, every `NAME = {…}` span) by name.

    A string or object is trusted only when declared exactly once, as `const
    NAME = <literal>`, and never rebound: a second declaration, or the name as
    a parameter, destructured binding, key or assignment target, could shadow
    it at the use. An object must also be used only as
    `NAME[ident]` (never assigned through), `...NAME` or `typeof NAME`: any
    other use could mutate it. The spans, trusted or not, let a raw entry
    quote what it read."""
    decls, rebound, uses, spans = {}, set(), {}, {}
    for i, tok in enumerate(toks):
        # Everything in a `(…)` followed by `=>`, `{` or `:` may be a parameter
        # (over-matching `if (…) {` only leaves more raw), and everything in a
        # `{…}`/`[…]` after `const`/`let`/`var` is destructured into a binding.
        after = toks[pairs[i] + 1] if i in pairs and pairs[i] + 1 < len(toks) else None
        binds = tok.is_p("(") and after is not None and after.kind == "p" and after.value in ("=>", "{", ":")
        binds = binds or (
            tok.kind == "p" and tok.value in "{[" and i and toks[i - 1].kind == "i" and toks[i - 1].value in ("const", "let", "var")
        )
        if binds and pairs[i] > i:
            rebound.update(t.value for t in toks[i + 1 : pairs[i]] if t.kind == "i")
        if tok.kind != "i":
            continue
        prev = toks[i - 1] if i else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if nxt is not None and nxt.is_p("=") and i + 2 < len(toks) and toks[i + 2].is_p("{") and (i + 2) in pairs:
            spans.setdefault(tok.value, []).append((i, pairs[i + 2]))
        if prev is not None and prev.kind == "i" and prev.value in ("const", "let", "var"):
            decl = None
            if prev.value == "const" and nxt is not None and nxt.is_p("=") and i + 2 < len(toks):
                init = toks[i + 2]
                after = toks[i + 3] if i + 3 < len(toks) else None
                ends = after is None or after.kind != "p" or after.value in (";", ",", "}")
                if init.kind == "s" and ends:
                    decl = ("string", init.value, i, i + 2)
                elif init.is_p("{") and (i + 2) in pairs:
                    decl = ("object", i + 2, i, pairs[i + 2])
            decls.setdefault(tok.value, []).append(decl)
        else:
            uses.setdefault(tok.value, []).append(i)
            if nxt is not None and nxt.kind == "p" and nxt.value in (":", "=", "=>", "?"):
                rebound.add(tok.value)

    def object_use(u):
        prev = toks[u - 1] if u else None
        if prev is not None and (prev.is_p("...") or (prev.kind == "i" and prev.value == "typeof")):
            return True
        if u + 3 < len(toks) and toks[u + 1].is_p("[") and pairs.get(u + 1) == u + 3 and toks[u + 2].kind == "i":
            after = toks[u + 4] if u + 4 < len(toks) else None
            return after is None or not (after.kind == "p" and after.value in ASSIGN)
        return False

    strings, objects = {}, {}
    for name, found in decls.items():
        if len(found) != 1 or found[0] is None or name in rebound:
            continue
        kind, value, start, end = found[0]
        if kind == "string":
            strings[name] = (value, start, end)
        elif all(object_use(u) for u in uses.get(name, [])):
            objects[name] = (value, start, end)
    return strings, objects, spans


def object_entries(toks):
    """An object literal's top-level members: ("key", name, value tokens),
    ("spread", tokens) or ("other", tokens). Shorthand `{ a }` keeps `a`'s
    own token as its value."""
    entries = []
    for entry in split_top(toks, ","):
        if not entry:
            continue
        if entry[0].is_p("..."):
            entries.append(("spread", entry[1:]))
        elif len(entry) >= 3 and entry[0].kind in ("i", "s") and entry[1].is_p(":"):
            entries.append(("key", entry[0].value, entry[2:]))
        elif len(entry) == 1 and entry[0].kind == "i":
            entries.append(("key", entry[0].value, entry))
        else:
            entries.append(("other", entry))
    return entries


class Extractor:
    def __init__(self, text, where):
        self.text, self.where = text, where
        self.toks, _ = lex(text)
        self.pairs = matching(self.toks)
        self.strings, self.objects, self.spans = constants(self.toks, self.pairs)
        # A file that reaches the Supervisor any other way may build its
        # `hassio/` HTTP path anywhere: one that cannot be read must not be dropped.
        self.supervisor_file = any(t in text for t in TRIGGERS)
        self.found = []
        self.deps = []

    def src(self, toks):
        return collapse(self.text, toks)

    def read(self, start, end):
        """Note a declaration a construct read, for its raw entry's source_text."""
        text = self.src(self.toks[start : end + 1])
        if text not in self.deps:
            self.deps.append(text)

    def const_string(self, name):
        if name not in self.strings:
            raise Unresolved(f"`{name}` is not a once-declared, never-rebound const string")
        value, start, end = self.strings[name]
        self.read(start, end)
        return value

    def const_object(self, name):
        for start, end in self.spans.get(name, []):
            self.read(start, end)
        if name not in self.objects:
            raise Unresolved(f"`{name}` is not a once-declared, never-mutated literal object")
        opened, _, end = self.objects[name]
        return self.toks[opened + 1 : end]

    def members(self, toks, seen=()):
        """Request keys -> value tokens; the last one wins, as at runtime."""
        keys = {}
        for entry in object_entries(toks):
            if entry[0] == "key":
                if entry[1] in REQUEST_KEYS:
                    keys[entry[1]] = entry[2]
            elif entry[0] == "spread":
                keys.update(self.spread(entry[1], seen))
            else:
                raise Unresolved(f"`{self.src(entry[1])}` is not a `key: value` member")
        return keys

    def spread(self, toks, seen):
        if len(toks) == 1 and toks[0].kind == "i":
            name = toks[0].value
            if name in seen:
                raise Unresolved(f"`...{name}` spreads itself")
            return self.members(self.const_object(name), seen + (name,))
        inner = unwrap(toks)
        split = ternary(inner)
        for branch in [split[1], split[2]] if split else [inner]:
            branch = unwrap(branch)
            if not is_object(branch):
                raise Unresolved(f"`...{self.src(toks)}` is not a spread of a literal object")
            if self.members(branch[1:-1], seen):
                raise Unresolved(f"`...{self.src(toks)}` sets a request key inline")
        return {}

    def string(self, toks):
        toks = unwrap(toks)
        if len(toks) == 1 and toks[0].kind == "s":
            return toks[0].value
        if len(toks) == 1 and toks[0].kind == "i":
            return self.const_string(toks[0].value)
        raise Unresolved(f"`{self.src(toks)}` is not a string literal")

    def verb(self, toks):
        verb = self.string(toks).upper()
        if verb not in VERBS:
            raise Unresolved(f"`{verb}` is not an HTTP verb")
        return verb

    def paths(self, toks):
        """Every string a path expression can be, a `${x}` hole as a placeholder."""
        toks = unwrap(toks)
        split = ternary(toks)
        if split:
            # The condition only picks between paths that are both listed.
            return self.paths(split[1]) + self.paths(split[2])
        if len(toks) == 1 and toks[0].kind == "t":
            options = []
            for part in toks[0].value:
                if isinstance(part, str):
                    options.append([part])
                elif is_chain(part):
                    options.append([placeholder(part[-1].value)])
                else:
                    raise Unresolved(f"`${{{self.src(part)}}}` is not an identifier or `a.b` chain")
            return ["".join(combo) for combo in product(*options)]
        if (
            len(toks) == 4
            and toks[0].kind == "i"
            and toks[1].is_p("[")
            and toks[2].kind == "i"
            and toks[3].is_p("]")
        ):
            values = []
            for entry in object_entries(self.const_object(toks[0].value)):
                if entry[0] != "key" or len(entry[2]) != 1 or entry[2][0].kind != "s":
                    raise Unresolved(f"`{toks[0].value}` has a member that is not `key: \"literal\"`")
                values.append(entry[2][0].value)
            return values
        return [self.string(toks)]

    def resolve(self, method, path_toks, suffix="", require_hassio=False):
        """[(method, path)], dropping alternatives that are not Supervisor paths."""
        out = []
        for alt in self.paths(path_toks) if path_toks is not None else []:
            path = normalise(alt + suffix, require_hassio)
            if path is not None:
                out.append((method, path))
        return out

    def emit(self, construct, attempt, method_toks=None, path_toks=None, skip_unread=False, method=None):
        self.deps = []
        try:
            for method, path in attempt():
                self.found.append({"method": method, "path": path, "source": self.where})
        except Unresolved as err:
            if skip_unread:
                return
            try:
                method = method or (self.verb(method_toks) if method_toks else "UNKNOWN")
            except Unresolved:
                method = "UNKNOWN"
            text = self.src(construct)
            if self.deps:
                text += " where " + " ; ".join(self.deps)
            self.found.append(
                {
                    "method": method,
                    "path": self.src(path_toks) if path_toks else "",
                    "raw": True,
                    "reason": str(err),
                    "source": self.where,
                    "source_text": text,
                }
            )

    def walk(self, toks):
        pairs = self.pairs if toks is self.toks else matching(toks)
        for i, tok in enumerate(toks):
            if tok.kind == "t":
                for part in tok.value:
                    if not isinstance(part, str):
                        self.walk(part)
            elif tok.is_p("{") and i in pairs:
                self.request_object(toks, pairs, i)
            elif tok.kind == "i" and tok.value in CALLS:
                self.call(toks, pairs, i)

    def supervisor_object(self, inner, seen=()):
        """Whether an object names the supervisor/api type, read leniently so a
        request with an unresolvable member is still caught."""
        for entry in object_entries(inner):
            if entry[0] == "key" and entry[1] == "type" and len(entry[2]) == 1:
                value = entry[2][0]
                if value.kind == "s" and value.value == "supervisor/api":
                    return True
                if value.kind == "i" and self.strings.get(value.value, (None,))[0] == "supervisor/api":
                    return True
            elif entry[0] == "spread" and len(entry[1]) == 1 and entry[1][0].kind == "i":
                name = entry[1][0].value
                for start, end in [] if name in seen else self.spans.get(name, []):
                    if self.supervisor_object(self.toks[start + 3 : end], seen + (name,)):
                        return True
        return False

    def direct(self, inner, key):
        found = [e[2] for e in object_entries(inner) if e[0] == "key" and e[1] == key]
        return found[-1] if found else None

    def request_object(self, toks, pairs, i):
        inner = toks[i + 1 : pairs[i]]
        if not self.supervisor_object(inner):
            return
        declared = i >= 2 and toks[i - 1].is_p("=") and toks[i - 2].kind == "i"

        def attempt():
            keys = self.members(inner)
            if self.string(keys.get("type", [])) != "supervisor/api":
                raise Unresolved("the request type is overridden")
            return self.request(keys, declared)

        self.emit(toks[i : pairs[i] + 1], attempt, self.direct(inner, "method"), self.direct(inner, "endpoint"))

    def request(self, keys, declared=False):
        if "endpoint" not in keys:
            # A shared `{type, method}` the call sites spread; not itself a call.
            if declared:
                return []
            raise Unresolved("a supervisor/api request with no endpoint")
        method = self.verb(keys["method"]) if "method" in keys else "GET"
        return self.resolve(method, keys["endpoint"])

    def call(self, toks, pairs, i):
        name = toks[i].value
        args, close = call_args(toks, pairs, i)
        if not args or not args[0]:
            return
        construct = toks[i : close + 1]

        def arg(n):
            return args[n] if len(args) > n and args[n] else None

        if name == "supervisorApiWsRequest" and arg(1):
            # Its object carries no `type`: the helper merges that in.
            def attempt():
                if not is_object(arg(1)):
                    raise Unresolved(f"`{self.src(arg(1))}` is not an object literal")
                return self.request(self.members(arg(1)[1:-1]))

            inner = arg(1)[1:-1] if is_object(arg(1)) else []
            self.emit(construct, attempt, self.direct(inner, "method"), self.direct(inner, "endpoint"))
        elif name == "supervisorApiCall" and arg(1):
            options = arg(2)

            def attempt():
                method = "GET"
                if options is not None:
                    if not is_object(options):
                        raise Unresolved(f"`{self.src(options)}` is not an object literal")
                    keys = self.members(options[1:-1])
                    method = self.verb(keys["method"]) if "method" in keys else "GET"
                return self.resolve(method, arg(1))

            method_toks = self.direct(options[1:-1], "method") if options and is_object(options) else None
            self.emit(construct, attempt, method_toks, arg(1), method=None if options else "GET")
        elif name in ("callApi", "callApiRaw") and arg(1):
            path = arg(1)

            def attempt():
                # The verb only matters once the path is a Supervisor one.
                if not self.resolve("GET", path, require_hassio=True):
                    return []
                return self.resolve(self.verb(args[0]), path, require_hassio=True)

            unread = not self.supervisor_file and "hassio" not in self.src(path)
            self.emit(construct, attempt, args[0], path, skip_unread=unread)
        elif name == "supervisorUrl":
            self.emit(construct, lambda: self.resolve("GET", args[0]), None, args[0], method="GET")
        elif name == "fetchHassioStats" and arg(1):
            self.emit(construct, lambda: self.resolve("GET", arg(1), suffix="/stats"), None, arg(1), method="GET")


def extract(text, where):
    extractor = Extractor(text, where)
    extractor.walk(extractor.toks)
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
    ordered = sorted(
        (json.loads(e) for e in unique),
        key=lambda e: (e["path"], e["method"], e["source"], json.dumps(e, sort_keys=True)),
    )
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
