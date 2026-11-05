"""The fixture's `sources` hashes are the fail-closed drift guard; the
endpoint list these cover is the review aid that says what moved. It is only
useful if what it cannot resolve comes out as a raw entry carrying its
source. Each case runs a snippet and the same snippet mutated the way that
once left the output unchanged, and asserts the output now moves."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from frontend_hassio_endpoints import extract  # noqa: E402

WHERE = "src/data/supervisor/supervisor.ts"

COLLECTION = """
export const supervisorCollection = {
  host: "/host/info",
  store: "/store",%s
};
const fetch = (conn, key) =>
  supervisorApiWsRequest(conn, { endpoint: %s });
"""


def run(text):
    return extract(text, WHERE)


def raws(found):
    return [e for e in found if e.get("raw")]


def resolved(found):
    return {(e["method"], e["path"]) for e in found if not e.get("raw")}


class Case(unittest.TestCase):
    def assertMoves(self, base, mutated):
        self.assertNotEqual(run(base), run(mutated))


class SpreadTest(Case):
    def test_spread_in_table_is_raw(self):
        before = run(COLLECTION % ("", "supervisorCollection[key]"))
        after = run(COLLECTION % ("\n  ...extra,", "supervisorCollection[key]"))
        self.assertEqual(resolved(before), {("GET", "/host/info"), ("GET", "/store")})
        self.assertEqual(raws(before), [])
        self.assertEqual(resolved(after), set())
        [raw] = raws(after)
        self.assertIn("supervisorCollection", raw["reason"])
        self.assertIn("...extra", raw["source_text"])

    def test_spread_request_at_call_site_is_raw(self):
        base = 'supervisorApiWsRequest(conn, { endpoint: "/host/info" });\n'
        before = run(base)
        after = run(base + "supervisorApiWsRequest(conn, {...request});\n")
        self.assertEqual(resolved(after), resolved(before))
        self.assertEqual(raws(before), [])
        [raw] = raws(after)
        self.assertEqual(raw["method"], "UNKNOWN")
        self.assertIn("`request`", raw["reason"])
        self.assertEqual(raw["source_text"], "supervisorApiWsRequest(conn, {...request})")

    def test_spread_into_base_command_declaration_is_raw(self):
        before = run('const base = { type: "supervisor/api", method: "GET" };\n')
        after = run('const base = { type: "supervisor/api", ...defaults };\n')
        self.assertEqual(before, [])
        [raw] = raws(after)
        self.assertIn("`defaults`", raw["reason"])
        self.assertIn("...defaults", raw["source_text"])

    def test_spread_of_known_base_command_is_resolved(self):
        found = run(
            'const base = { type: "supervisor/api", method: "GET" };\n'
            'conn.sendMessagePromise({ ...base, endpoint: "/os/info" });\n'
        )
        self.assertEqual(resolved(found), {("GET", "/os/info")})
        self.assertEqual(raws(found), [])

    def test_inline_spread_setting_no_request_key_is_resolved(self):
        found = run(
            'callWS({ type: "supervisor/api", endpoint: "/host/disks/default/usage", method: "get",'
            " ...(depth === undefined ? {} : { params: { max_depth: depth } }) });\n"
        )
        self.assertEqual(resolved(found), {("GET", "/host/disks/default/usage")})
        self.assertEqual(raws(found), [])


class ShorthandMethodTest(Case):
    def test_shorthand_method_is_not_the_default(self):
        before = run('supervisorApiCall(hass, "/store");\n')
        const = run('const method = "post"; supervisorApiCall(hass, "/store", { method });\n')
        param = run('const f = (method) => supervisorApiCall(hass, "/store", { method });\n')
        self.assertEqual(resolved(before), {("GET", "/store")})
        self.assertEqual(resolved(const), {("POST", "/store")})
        self.assertEqual(resolved(param), set())
        [raw] = raws(param)
        self.assertEqual((raw["method"], raw["path"]), ("UNKNOWN", '"/store"'))

    def test_shorthand_method_in_request_object_is_unknown(self):
        found = run('callWS({ type: "supervisor/api", endpoint: "/store", method });\n')
        self.assertEqual(resolved(found), set())
        self.assertEqual(raws(found)[0]["method"], "UNKNOWN")


class TableLookupTest(Case):
    def test_lookup_must_be_the_whole_expression(self):
        before = run(COLLECTION % ("", "supervisorCollection[key]"))
        after = run(COLLECTION % ("", 'supervisorCollection[key] + "/unrouted"'))
        self.assertEqual(raws(before), [])
        self.assertEqual(resolved(after), set())
        [raw] = raws(after)
        self.assertEqual(raw["path"], 'supervisorCollection[key] + "/unrouted"')


class UnresolvedHttpPathTest(Case):
    BASE = 'supervisorApiCall(hass, "/store");\n'

    def test_const_path_is_resolved(self):
        before = run(self.BASE)
        after = run(self.BASE + 'const endpoint = "hassio/addons/unserved"; api.callApi("POST", endpoint);\n')
        self.assertEqual(resolved(after) - resolved(before), {("POST", "/addons/unserved")})
        self.assertEqual(raws(after), [])

    def test_unresolvable_path_is_raw(self):
        after = run(self.BASE + 'api.callApi("POST", endpoint);\n')
        self.assertEqual(resolved(after), resolved(run(self.BASE)))
        [raw] = raws(after)
        self.assertEqual((raw["method"], raw["path"]), ("POST", "endpoint"))

    def test_runtime_prefix_is_raw(self):
        after = run(self.BASE + 'api.callApi("POST", `${base}/addons`);\n')
        [raw] = raws(after)
        self.assertEqual(raw["path"], "`${base}/addons`")

    def test_redeclared_const_is_not_trusted(self):
        after = run(
            self.BASE
            + 'const endpoint = "hassio/addons/a";\n'
            + 'function f() { const endpoint = "hassio/addons/b"; api.callApi("POST", endpoint); }\n'
        )
        self.assertEqual(raws(after)[0]["path"], "endpoint")

    def test_parameter_shadowing_const_is_not_trusted(self):
        after = run(
            self.BASE
            + 'const endpoint = "hassio/addons/a";\n'
            + 'const f = (endpoint: string) => api.callApi("POST", endpoint);\n'
        )
        self.assertEqual(resolved(after), resolved(run(self.BASE)))
        self.assertEqual(raws(after)[0]["path"], "endpoint")

    def test_const_expression_is_not_a_literal(self):
        after = run(self.BASE + 'const endpoint = "hassio/" + rest; api.callApi("POST", endpoint);\n')
        self.assertEqual(raws(after)[0]["path"], "endpoint")

    def test_unrelated_file_still_ignored(self):
        self.assertEqual(extract('api.callApi("GET", url);\n', "src/data/other.ts"), [])


class UnlistedSyntaxTest(Case):
    """Copilot's second round: each construct is outside the whitelist."""

    def test_computed_member_in_table_is_raw(self):
        base = COLLECTION % ("", "supervisorCollection[key]")
        mutated = COLLECTION % ('\n  [newKey]: "/addons/unserved",', "supervisorCollection[key]")
        self.assertMoves(base, mutated)
        self.assertEqual(resolved(run(mutated)), set())
        [raw] = raws(run(mutated))
        self.assertIn('[newKey]: "/addons/unserved"', raw["source_text"])

    def test_nested_spread_is_raw(self):
        base = 'supervisorApiWsRequest(conn, { endpoint: "/host/info" });\n'
        for spread in ("...{...request}", "...(flag ? {} : {...request})"):
            mutated = 'supervisorApiWsRequest(conn, { endpoint: "/host/info", %s });\n' % spread
            self.assertMoves(base, mutated)
            self.assertEqual(resolved(run(mutated)), set())
            self.assertIn(spread, raws(run(mutated))[0]["source_text"])

    HELPER = """
export const supervisorApiCall = async <T>(hass, endpoint: string, options?) =>
  hass.callWS<T>({
    type: "supervisor/api",
    endpoint,
    method: options?.method || %s,
  });
"""

    def test_helper_default_verb_is_in_the_output(self):
        self.assertMoves(self.HELPER % '"get"', self.HELPER % '"post"')
        [raw] = raws(run(self.HELPER % '"post"'))
        self.assertIn('options?.method || "post"', raw["source_text"])

    def test_raw_source_text_tracks_its_expression(self):
        snippet = 'callWS({ type: "supervisor/api", endpoint: ep, method: "get", data: %s });\n'
        [before] = run(snippet % "a")
        [after] = run(snippet % "b")
        self.assertTrue(before["raw"])
        self.assertEqual({k: v for k, v in before.items() if k != "source_text"}, {k: v for k, v in after.items() if k != "source_text"})
        self.assertNotEqual(before["source_text"], after["source_text"])


class ReviewAidTest(Case):
    """Copilot's third round, where a cheap fix makes the summary say more."""

    BASE = 'supervisorApiWsRequest(conn, { endpoint: "/host/info" });\n'

    def test_event_collection_caller_is_extracted(self):
        mutated = self.BASE + 'getSupervisorEventCollection(conn, "addons", "/addons/unserved");\n'
        self.assertMoves(self.BASE, mutated)
        self.assertEqual(resolved(run(mutated)) - resolved(run(self.BASE)), {("GET", "/addons/unserved")})

    def test_unresolved_const_quotes_its_initializer(self):
        snippet = 'const endpoint = pathFor(%s); api.callApi("POST", endpoint);\n'
        self.assertMoves(self.BASE + snippet % '"a"', self.BASE + snippet % '"b"')
        [raw] = raws(run(self.BASE + snippet % '"b"'))
        self.assertIn('endpoint = pathFor("b")', raw["source_text"])


if __name__ == "__main__":
    unittest.main()
