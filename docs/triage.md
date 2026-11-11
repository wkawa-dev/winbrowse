# Triage: when a site breaks in WinBrowse

This runbook takes a broken site from a report to a tested fix. A person or a coding agent can follow it. Every command prints JSON with `--json`.

## 0. Set up

1. Build and launch a Debug build in the simulator: `scripts/sim.sh` on the build Mac, or `scripts/mac.sh scripts/e2e.sh` for the whole loop. The Debug build opens a control port on `localhost:8899` and writes its token to `/tmp/winbrowse-debug-token`.
2. Check the connection: `tools/webcompat/wb.py state`.
3. If the user sent a breakage report (menu › report broken site), read it first. It lists the site's protections, the filter lists and their compile report, the extensions and the page errors.

## 1. Reproduce

1. `wb.py open <url>`, then look at the page in the simulator.
2. Write a probe: a script that returns `true` only when the page works, for example `return !!document.querySelector('video') && !document.querySelector('.error')`. Check it: `wb.py eval "<probe>"` must print `false` now.
3. `wb.py errors` lists script errors, rejected promises, failed loads (including requests the filters blocked) and CSP violations.

## 2. Find what causes it

`wb.py bisect <url> --probe "<probe>"`

It first checks that the page breaks with every protection on and works with every protection off. It then finds the smallest set of protections that still breaks the page. If that set includes network blocking, cosmetic filters or scriptlets, it repeats the search over the enabled filter lists. It restores the site's settings afterwards and writes a draft case file to `docs/breakage/<site>-draft.md`.

## 3. Classify

| Bisect says | Class | Next step |
|---|---|---|
| broken with every protection off | site bug, WebKit bug or extension | Turn extensions off one by one with `/ext?id=<id>&on=0`. Check the page in Safari on the same iOS version: if it breaks there too, it is a site or WebKit bug. |
| `network` and a filter list | a network filter | Find the blocked request in `wb.py errors` (kind `resource`). Report the filter upstream to the list, or add a site entry with `"off": ["network"]` if the fix cannot wait. |
| `cosmetic` | a hidden element | Find the selector with `wb.py eval --world ubo`. Report it upstream. |
| `scriptlets` | a scriptlet | Scriptlets run in the page world; read the uBlock Origin Lite scriptlet for the matching filter list. |
| `backgroundMedia` or `passkeys` | an app shim | Reduce the page to a fixture under `Tests/Fixtures/pages/` and fix the module in `App/Resources/page-*.js`. `AppScriptTests` runs the modules in real WebKit. |

## 4. Reduce

Make the smallest page that shows the problem and save it under `Tests/Fixtures/pages/`. Its `<title>` says what it checks. Third-party code that you do not control should not be in the fixture; copy only the few lines that matter.

## 5. Fix

Prefer, in order: a fix in our own code, an upstream filter-list fix, then a site entry in `App/Resources/site-config.json` with a `reason` and a `case`. A site entry turns protections off only for that site and its subdomains. `SitePolicyTests` checks that the file is valid and that every case file exists.

## 6. Record and guard

1. Finish the case file from `docs/breakage/TEMPLATE.md`. Write "unknown" for anything you did not establish.
2. Add a case to `Tests/Fixtures/cases/` that `wb.py repro` can run, using `{fixtures}` for the local fixture server.
3. `scripts/mac.sh scripts/check.sh` and `scripts/mac.sh scripts/e2e.sh` must pass.
