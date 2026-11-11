# X: promoted posts and follow suggestions in the timeline

| | |
|---|---|
| Site | `x.com`, `twitter.com` |
| Class | caused by an extension: its markup-based hiding misses entries |
| Status | worked around since the first commit (`86b594f`); moved into `App/Resources/page-xfeed.js` in `6fc7373` |
| Regression test | `AppScriptTests.xTimelineResponsesLosePromotedEntries` |

## Symptom

Promoted posts and "who to follow" modules still appeared in the timeline with The Ad Blocker for X on, whenever X changed its markup.

## Reproduction

Unknown: the original report was not recorded. The test serves a timeline response with a promoted entry and checks that it is removed.

## Cause

The extension hides entries by matching rendered markup, so it misses entries whenever X changes that markup.

## Fix

`page-xfeed.js` removes promoted entries (by entry ID prefix or `promotedMetadata`) from X's GraphQL timeline responses before the page reads them, for both `XMLHttpRequest` and `fetch`. It runs only on the top frame of x.com and twitter.com, and only while The Ad Blocker for X is on. The replaced functions look native to the page (`AppScriptTests.appScriptsLeaveNoTraceThatFeatureProbesCanSee`).
