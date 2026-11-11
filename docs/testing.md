# Testing

## What runs where

| Check | Command | Where |
|---|---|---|
| Lint, formatting, no code comments, vendored-file hashes, triage tool tests, report intake tests, type check of the app and tests | `scripts/check.sh --lint-only` | any Mac with the Command Line Tools, SwiftFormat and Node |
| Everything above, then the Debug build and the `WinBrowseTests` target on an iPhone simulator | `scripts/mac.sh scripts/check.sh` | the build Mac; CI job `check` |
| End-to-end cases against a running app | `scripts/mac.sh scripts/e2e.sh` | the build Mac; CI job `e2e` |

`scripts/mac.sh` copies the working tree to a temporary folder on the build Mac, runs the command there, and removes the folder and any simulator it booted. Set `WINBROWSE_SIM` to choose a simulator.

The type check compiles the app for a Mac Catalyst target, which needs no Xcode. If the default macOS SDK needs the SwiftUI macro plugin that only Xcode ships, point `WINBROWSE_TYPECHECK_SDK` at an older SDK in `/Library/Developer/CommandLineTools/SDKs/`.

## The tests

| Suite | What it guards |
|---|---|
| `MatchPatternTests` | Chrome match patterns, host permissions, and the JavaScript guard built from them |
| `RuleConverterTests`, `RuleListCompilerTests` | the declarativeNetRequest converter (golden file), URL filter semantics, WebKit accepting every rule kind we emit, and bisecting refused rules |
| `PasskeyCodecTests`, `PublicSuffixListTests` | WebAuthn byte formats, checked with an independent CBOR decoder and the Security framework; relying-party rules and the official PSL test vectors |
| `AppScriptTests` | the page modules in real WebKit: no trace for feature probes, visibility only after sound, passkey round trip, abort and timeout, the X timeline filter, page error capture |
| `AppFootprintTests` | a real tab configuration against the reviewed allowlist in `Tests/Fixtures/footprint-allowlist.json` (simulator only) |
| `SitePolicyTests`, `TabTests` | per-site protections, migration, the bundled site configuration, and the blocked-page loop (simulator only) |
| `ExtensionMessageTests`, `FetchPolicyTests` | the message protocol against the shim, caller limits, extension file access, cookies and redirects for extension fetch |
| `BreakageReportTests` | redaction of URLs and page errors; the upload request (HTTPS only, no cookies, size limit) |
| `deploy/test/` (Node) | the report intake: validation, status codes, and that the stored row has only the known fields, run against in-memory SQLite with the production migration |
| `tools/webcompat/test_wb.py` | delta debugging, bisect against a simulated broken site, the control-port client |

Tests that need only Foundation, WebKit and JavaScriptCore also run on macOS; the ones that need the app bundle run in the simulator.

## Golden files

`Tests/Fixtures/dnr/cases.webkit.json` and `Tests/Fixtures/footprint-allowlist.json` record expected output. When a change is intended, rerun with `WINBROWSE_RECORD=1` (in the simulator: `TEST_RUNNER_WINBROWSE_RECORD=1 scripts/check.sh`), then review the diff line by line before committing it.

## Fixtures and cases

`Tests/Fixtures/pages/` holds minimal pages, each with a `<title>` that says what it checks. `Tests/Fixtures/cases/` holds `wb repro` cases; `{fixtures}` in a case URL is the local fixture server that `wb serve` starts on ports 8901 and 8902.
