# WinBrowse: "proceed" on the blocked-page screen rebuilt the tab again and again

| | |
|---|---|
| Site | any site that uBlock Origin's strict blocking stops |
| Class | WinBrowse bug |
| Status | fixed in `8acfc1f` |
| Regression test | `TabTests.proceedingPastABlockedPageBuildsOneWebViewForTheTargetSite` |

## Symptom

Tapping "proceed" on the "page blocked" screen could create a new web view, cancel the load and create another, without end.

## Reproduction

Open a site that a strict-blocking filter blocks, then tap "proceed".

## Cause

Found by reading the code. `Tab.ensureWebView` chose the filtered or unfiltered configuration from the tab's previous URL and ignored the one-shot bypass. The navigation policy then compared that choice with the target URL, saw a mismatch, cancelled and rebuilt.

## Fix

Every protection decision now goes through `SitePolicy` for the URL the tab is about to load, and "proceed" turns off only network blocking for that site until the tab leaves it.
