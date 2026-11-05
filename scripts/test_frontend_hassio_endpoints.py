"""The extractor backs a drift guard, so anything it cannot resolve must come
out as a raw entry. Each case runs a snippet and the same snippet mutated the
way that once left the output unchanged, and asserts the output now moves."""

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


class SpreadTest(unittest.TestCase):
    def test_spread_in_table_is_raw(self):
        before = run(COLLECTION % ("", "supervisorCollection[key]"))
        after = run(COLLECTION % ("\n  ...extra,", "supervisorCollection[key]"))
        self.assertEqual(resolved(before), {("GET", "/host/info"), ("GET", "/store")})
        self.assertEqual(raws(before), [])
        self.assertEqual(resolved(after), resolved(before))
        [raw] = raws(after)
        self.assertIn("...extra", raw["reason"])
        self.assertIn("supervisorCollection", raw["reason"])

    def test_spread_request_at_call_site_is_raw(self):
        base = 'supervisorApiWsRequest(conn, { endpoint: "/host/info" });\n'
        before = run(base)
        after = run(base + "supervisorApiWsRequest(conn, {...request});\n")
        self.assertEqual(resolved(after), resolved(before))
        self.assertEqual(raws(before), [])
        [raw] = raws(after)
        self.assertEqual((raw["method"], raw["path"]), ("UNKNOWN", "...request"))
        self.assertIn("call site", raw["reason"])

    def test_spread_into_base_command_declaration_is_raw(self):
        before = run('const base = { type: "supervisor/api", method: "GET" };\n')
        after = run('const base = { type: "supervisor/api", ...defaults };\n')
        self.assertEqual(before, [])
        [raw] = raws(after)
        self.assertIn("base command `base`", raw["reason"])

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


class ShorthandMethodTest(unittest.TestCase):
    def test_shorthand_method_is_unknown(self):
        before = run('supervisorApiCall(hass, "/store");\n')
        after = run('const method = "post"; supervisorApiCall(hass, "/store", { method });\n')
        self.assertEqual(resolved(before), {("GET", "/store")})
        self.assertEqual(resolved(after), set())
        [raw] = raws(after)
        self.assertEqual((raw["method"], raw["path"]), ("UNKNOWN", '"/store"'))

    def test_shorthand_method_in_request_object_is_unknown(self):
        found = run('callWS({ type: "supervisor/api", endpoint: "/store", method });\n')
        self.assertEqual(resolved(found), set())
        self.assertEqual(raws(found)[0]["method"], "UNKNOWN")


class TableLookupTest(unittest.TestCase):
    def test_lookup_must_be_the_whole_expression(self):
        before = run(COLLECTION % ("", "supervisorCollection[key]"))
        after = run(COLLECTION % ("", 'supervisorCollection[key] + "/unrouted"'))
        self.assertEqual(raws(before), [])
        self.assertEqual(resolved(after), set())
        [raw] = raws(after)
        self.assertEqual(raw["path"], 'supervisorCollection[key] + "/unrouted"')


class UnresolvedHttpPathTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
