#!/usr/bin/env python3
import argparse
import datetime
import functools
import http.server
import json
import math
import os
import pathlib
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROTECTIONS = ["network", "cosmetic", "scriptlets", "backgroundMedia", "passkeys"]
FILTERING = {"network", "cosmetic", "scriptlets"}
FIXTURE_PORTS = (8901, 8902)


class AppError(Exception):
    pass


class App:
    def __init__(self, port=8899, token_file="/tmp/winbrowse-debug-token", timeout=30):
        self.base = f"http://localhost:{port}"
        self.token_file = token_file
        self.timeout = timeout

    def call(self, path, body=None, **query):
        try:
            token = pathlib.Path(self.token_file).read_text().strip()
        except OSError as e:
            raise AppError(f"no debug token at {self.token_file}: start a Debug build of the app first") from e
        url = self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        request = urllib.request.Request(url, data=body.encode() if body is not None else None, headers={"X-Debug-Token": token})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read().decode()
        except urllib.error.HTTPError as e:
            raise AppError(f"{path} answered {e.code}") from e
        except urllib.error.URLError as e:
            raise AppError(f"the app's debug port at {self.base} is not reachable: {e.reason}") from e

    def json(self, path, body=None, **query):
        text = self.call(path, body, **query)
        try:
            return json.loads(text)
        except json.JSONDecodeError as e:
            raise AppError(f"{path} did not answer JSON: {text[:200]}") from e

    def open(self, url, settle=1.0, timeout=20):
        self.call("/open", url=url)
        time.sleep(0.3)
        if self.call("/wait", js="document.readyState === 'complete'", timeout=str(timeout)) != "ok":
            raise AppError(f"{url} did not finish loading within {timeout} s")
        time.sleep(settle)

    def eval(self, script, world="page"):
        text = self.call("/eval", script, world=world)
        if text.startswith("error:"):
            raise AppError(text)
        return None if text == "undefined" else json.loads(text)

    def protections(self, site, enabled=None):
        if enabled is None:
            return self.json("/protections", site=site)
        return self.json("/protections", site=site, set=",".join(enabled))

    def rulesets(self, enabled=None):
        if enabled is None:
            return self.json("/rulesets")
        return self.json("/rulesets", set=",".join(enabled))


def ddmin(items, fails):
    items = list(items)
    cache = {}

    def test(subset):
        key = tuple(subset)
        if key not in cache:
            cache[key] = fails(subset)
        return cache[key]

    n = 2
    while len(items) >= 2:
        size = math.ceil(len(items) / n)
        subsets = [items[i:i + size] for i in range(0, len(items), size)]
        reduced = False
        for s in subsets:
            if test(s):
                items, n, reduced = s, 2, True
                break
        if not reduced:
            for s in subsets:
                complement = [x for x in items if x not in s]
                if complement and test(complement):
                    items, n, reduced = complement, max(n - 1, 2), True
                    break
        if not reduced:
            if n >= len(items):
                break
            n = min(len(items), n * 2)
    return items


class Bisector:
    def __init__(self, app, url, probe, log=lambda message: None):
        self.app = app
        self.url = url
        self.site = urllib.parse.urlsplit(url).hostname
        self.probe = probe
        self.log = log
        self.trials = 0

    def works(self, protections, rulesets=None):
        self.trials += 1
        if rulesets is not None:
            self.app.rulesets(rulesets)
        self.app.protections(self.site, protections)
        self.app.open(self.url)
        ok = bool(self.app.eval(self.probe))
        self.log(f"trial {self.trials}: protections={','.join(protections) or 'none'}"
                 + (f" rulesets={','.join(rulesets)}" if rulesets is not None else "") + f" -> {'works' if ok else 'broken'}")
        return ok

    def run(self):
        original_protections = self.app.protections(self.site)
        original_rulesets = self.app.rulesets()["enabled"]
        try:
            return self._run(original_rulesets)
        finally:
            self.app.rulesets(original_rulesets)
            self.app.protections(self.site, original_protections)

    def _run(self, rulesets):
        result = {"url": self.url, "site": self.site, "probe": self.probe}
        if self.works(PROTECTIONS):
            return {**result, "verdict": "works with every protection on", "cause": None}
        if not self.works([]):
            return {**result, "verdict": "broken with every protection off: a site bug, a WebKit bug or an extension", "cause": "not a protection"}
        culprits = ddmin(PROTECTIONS, lambda subset: not self.works(subset))
        result.update(verdict="caused by a protection", protections=culprits)
        if FILTERING & set(culprits) and len(rulesets) > 1:
            result["rulesets"] = ddmin(rulesets, lambda subset: not self.works(culprits, subset))
        result["trials"] = self.trials
        return result


def draft_case(result, directory=ROOT / "docs" / "breakage"):
    template = (directory / "TEMPLATE.md").read_text()
    lines = [f"wb bisect on {datetime.date.today().isoformat()}, probe `{result['probe']}`: {result['verdict']}."]
    if result.get("protections"):
        lines.append(f"Smallest set of protections that breaks the page: {', '.join(result['protections'])}.")
    if result.get("rulesets"):
        lines.append(f"Smallest set of filter lists that breaks it: {', '.join(result['rulesets'])}.")
    text = template.replace("<Site>", result["site"]).replace("`<domain>`", f"`{result['site']}`")
    text = text.replace("## Cause\n", "## Cause\n\n" + " ".join(lines) + "\n")
    path = directory / f"{result['site'].replace('.', '-')}-draft.md"
    path.write_text(text)
    return path


def run_case(app, case, fixtures, log=lambda message: None):
    url = case["url"].replace("{fixtures}", fixtures)
    site = urllib.parse.urlsplit(url).hostname
    if "protections" in case:
        app.protections(site, case["protections"])
    for step in case.get("before", []):
        path, _, query = step.partition("?")
        app.call(path, **dict(urllib.parse.parse_qsl(query)))
    app.open(url)
    for step in case.get("steps", []):
        if "wait" in step:
            if app.call("/wait", js=step["wait"], timeout=str(step.get("timeout", 10))) != "ok":
                return {"name": case["name"], "passed": False, "failed": f"timed out waiting for {step['wait']}"}
        elif "eval" in step:
            app.eval(step["eval"])
        elif "tap" in step:
            app.eval(f"document.querySelector({json.dumps(step['tap'])}).click()")
        elif "sleep" in step:
            time.sleep(step["sleep"])
        log(f"step {step}")
    passed = app.call("/wait", js=case["expect"], timeout=str(case.get("timeout", 10))) == "ok"
    outcome = {"name": case["name"], "passed": passed}
    if not passed:
        outcome["failed"] = f"expected {case['expect']}"
        outcome["errors"] = app.json("/errors")
    return outcome


def serve(directory, ports):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    servers = [http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) for port in ports]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    return servers


def main(argv=None):
    parser = argparse.ArgumentParser(prog="wb", description="Drive a Debug build of WinBrowse through its control port to reproduce and triage site breakage.")
    parser.add_argument("--port", type=int, default=int(os.environ.get("WB_PORT", 8899)))
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("state", help="tabs, filter status and the active tab's protections")
    p = sub.add_parser("open", help="load a URL and wait until it finished loading")
    p.add_argument("url")
    p = sub.add_parser("eval", help="run script in the active tab; the script must return a value")
    p.add_argument("script")
    p.add_argument("--world", default="page")
    p = sub.add_parser("protections", help="read or set a site's protections")
    p.add_argument("site")
    p.add_argument("--set", help="comma-separated protections to leave on; empty for none")
    sub.add_parser("errors", help="page errors recorded in the active tab")
    sub.add_parser("report", help="the breakage report for the active tab")
    p = sub.add_parser("bisect", help="find the smallest set of protections and filter lists that breaks a page")
    p.add_argument("url")
    p.add_argument("--probe", required=True, help="script that returns true when the page works, e.g. \"return !!document.querySelector('video')\"")
    p.add_argument("--no-draft", action="store_true", help="do not write a draft case file")
    p = sub.add_parser("repro", help="run case files from Tests/Fixtures/cases")
    p.add_argument("cases", nargs="+")
    p.add_argument("--fixtures", default=f"http://localhost:{FIXTURE_PORTS[0]}")
    sub.add_parser("serve", help=f"serve Tests/Fixtures/pages on ports {FIXTURE_PORTS[0]} and {FIXTURE_PORTS[1]}")
    args = parser.parse_args(argv)

    app = App(port=args.port)
    log = (lambda message: print(message, file=sys.stderr)) if not args.json else (lambda message: None)
    try:
        if args.command == "state":
            out = app.json("/state")
        elif args.command == "open":
            app.open(args.url)
            out = {"opened": args.url}
        elif args.command == "eval":
            out = app.eval(args.script, args.world)
        elif args.command == "protections":
            out = app.protections(args.site, None if args.set is None else [x for x in args.set.split(",") if x])
        elif args.command == "errors":
            out = app.json("/errors")
        elif args.command == "report":
            out = app.json("/report")
        elif args.command == "bisect":
            out = Bisector(app, args.url, args.probe, log).run()
            if not args.no_draft and out.get("cause") is not None:
                out["draft"] = str(draft_case(out))
        elif args.command == "repro":
            out = [run_case(app, json.loads(pathlib.Path(c).read_text()), args.fixtures, log) for c in args.cases]
        else:
            for s in serve(ROOT / "Tests" / "Fixtures" / "pages", FIXTURE_PORTS):
                log(f"serving fixtures on http://localhost:{s.server_address[1]}/")
            threading.Event().wait()
            return 0
    except AppError as e:
        print(json.dumps({"error": str(e)}) if args.json else f"wb: {e}", file=sys.stderr)
        return 2
    print(json.dumps(out, indent=2))
    if args.command == "repro":
        return 0 if all(o["passed"] for o in out) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
