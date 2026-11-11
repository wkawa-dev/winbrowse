# <Site>: <what the user sees>

| | |
|---|---|
| Site | `<domain>` |
| Class | site bug · WebKit bug · caused by a protection (`network`, `cosmetic`, `scriptlets`, `backgroundMedia`, `passkeys`) · caused by an app shim · caused by an extension |
| Status | open · fixed in `<commit>` · worked around in `<commit>` |
| Regression test | `<test name or Tests/Fixtures/cases/<file>.json>` |

## Symptom

What the user sees, on which device and iOS version, and since when.

## Reproduction

The smallest steps or fixture page that shows the problem. Prefer a page under `Tests/Fixtures/pages/` and the `wb repro` case that drives it.

## Cause

What breaks and why, with the file and line in the site's code or ours. Say how this was established (bisect result, debugger, reduced test case). Write "unknown" for anything not established.

## Fix

What changed, why this is the narrowest fix, and how to remove it when it is no longer needed.
