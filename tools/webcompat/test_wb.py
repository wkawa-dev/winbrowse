import http.server
import json
import pathlib
import sys
import tempfile
import threading
import unittest
import urllib.parse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wb


class DeltaDebuggingTests(unittest.TestCase):
    def test_finds_a_single_culprit(self):
        self.assertEqual(wb.ddmin(wb.PROTECTIONS, lambda s: "cosmetic" in s), ["cosmetic"])

    def test_finds_an_interaction_of_two(self):
        found = wb.ddmin(list("abcdefgh"), lambda s: "b" in s and "g" in s)
        self.assertEqual(sorted(found), ["b", "g"])

    def test_tests_each_subset_once(self):
        calls = []
        wb.ddmin(list("abcd"), lambda s: calls.append(tuple(s)) or "d" in s)
        self.assertEqual(len(calls), len(set(calls)))


class FakeSite:
    def __init__(self, breaks, on=None):
        self.breaks = breaks
        self.on = list(on or wb.PROTECTIONS)
        self.enabled = ["easylist", "easyprivacy", "annoyances", "regional"]

    def protections(self, host, enabled=None):
        if enabled is not None:
            self.on = list(enabled)
        return list(self.on)

    def rulesets(self, enabled=None):
        if enabled is not None:
            self.enabled = list(enabled)
        return {"enabled": list(self.enabled)}

    def open(self, url):
        pass

    def eval(self, script):
        return not self.breaks(set(self.on), set(self.enabled))


class BisectTests(unittest.TestCase):
    def test_names_the_protection_and_filter_list(self):
        s = FakeSite(lambda p, r: "cosmetic" in p and "annoyances" in r)
        result = wb.Bisector(s, "https://shop.example/", "return true").run()
        self.assertEqual(result["protections"], ["cosmetic"])
        self.assertEqual(result["rulesets"], ["annoyances"])

    def test_restores_the_original_settings(self):
        s = FakeSite(lambda p, r: "network" in p, on=["network", "passkeys"])
        wb.Bisector(s, "https://shop.example/", "return true").run()
        self.assertEqual(s.on, ["network", "passkeys"])
        self.assertEqual(s.enabled, ["easylist", "easyprivacy", "annoyances", "regional"])

    def test_reports_breakage_that_no_protection_causes(self):
        s = FakeSite(lambda p, r: True)
        result = wb.Bisector(s, "https://shop.example/", "return true").run()
        self.assertEqual(result["cause"], "not a protection")

    def test_reports_a_page_that_works(self):
        s = FakeSite(lambda p, r: False)
        result = wb.Bisector(s, "https://shop.example/", "return true").run()
        self.assertIsNone(result["cause"])

    def test_writes_a_draft_case_file(self):
        with tempfile.TemporaryDirectory() as d:
            directory = pathlib.Path(d)
            (directory / "TEMPLATE.md").write_text((wb.ROOT / "docs" / "breakage" / "TEMPLATE.md").read_text())
            path = wb.draft_case({"site": "shop.example", "probe": "return true", "verdict": "caused by a protection",
                                  "protections": ["cosmetic"], "rulesets": ["annoyances"]}, directory)
            text = path.read_text()
            self.assertIn("# shop.example:", text)
            self.assertIn("cosmetic", text)
            self.assertIn("annoyances", text)


class ControlPort(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        self.answer()

    def do_POST(self):
        self.answer()

    def answer(self):
        if self.headers.get("X-Debug-Token") != "secret":
            self.send_response(403)
            self.end_headers()
            return
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        ControlPort.seen.append((url.path, query))
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        replies = {"/wait": "ok", "/open": "ok", "/errors": "[]", "/eval": json.dumps(body == "return window.ok"),
                   "/protections": json.dumps(query.get("set", "network").split(","))}
        data = replies.get(url.path, "unknown").encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class ClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ControlPort)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.token = tempfile.NamedTemporaryFile("w", delete=False)
        cls.token.write("secret\n")
        cls.token.close()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        pathlib.Path(cls.token.name).unlink()

    def app(self, token=None):
        return wb.App(port=self.server.server_address[1], token_file=token or self.token.name)

    def test_sends_the_token_and_decodes_answers(self):
        app = self.app()
        self.assertEqual(app.protections("a.example", ["cosmetic", "passkeys"]), ["cosmetic", "passkeys"])
        self.assertTrue(app.eval("return window.ok"))

    def test_explains_a_missing_token(self):
        with self.assertRaises(wb.AppError) as e:
            self.app("/nonexistent/token").call("/state")
        self.assertIn("Debug build", str(e.exception))

    def test_runs_a_case_against_the_fixture_server(self):
        ControlPort.seen.clear()
        case = {"name": "demo", "url": "{fixtures}/page.html", "before": ["/passkeys"], "steps": [{"tap": "#go"}], "expect": "window.ok"}
        outcome = wb.run_case(self.app(), case, "http://localhost:8901")
        self.assertTrue(outcome["passed"])
        opened = [q["url"] for p, q in ControlPort.seen if p == "/open"]
        self.assertEqual(opened, ["http://localhost:8901/page.html"])


class QueryEncodingTests(unittest.TestCase):
    def test_spaces_are_percent_encoded_because_the_app_keeps_plus_signs(self):
        self.assertEqual(wb.query_string({"js": "a === 'b'"}), "js=a%20%3D%3D%3D%20%27b%27")


if __name__ == "__main__":
    unittest.main()
