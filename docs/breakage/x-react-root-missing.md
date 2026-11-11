# X: The Ad Blocker for X waits for an element X no longer renders

| | |
|---|---|
| Site | `x.com` |
| Class | caused by an extension |
| Status | worked around since the first commit (`86b594f`) |
| Regression test | none |

## Symptom

Unknown in detail: the extension did nothing on X.

## Reproduction

Unknown.

## Cause

The extension looks up `#react-root`, which X no longer renders.

## Fix

`ExtensionHost.compatScripts(for:)` replaces `document.getElementById` in the extension's own isolated world only: a lookup of `react-root` that finds nothing returns X's app root instead. Pages never see the change. Remove it once upstream stops using `#react-root`; version 1.4.4 already matches X's `<li>` timeline items under `<main>`, so check whether it is still needed.
