# YouTube: playback stops when the app goes to the background

| | |
|---|---|
| Site | `youtube.com` and any site that plays media |
| Class | site behaviour plus WebKit behaviour: the page pauses on `visibilitychange`, and WebKit pauses media when the app leaves the foreground |
| Status | worked around since the first commit (`86b594f`); narrowed to pages that play sound in `6fc7373` |
| Regression test | `AppScriptTests.visibilityIsPinnedOnlyAfterThePagePlaysSound` |

## Symptom

Audio and video stopped when the screen locked or the user switched apps.

## Reproduction

Play a YouTube video with background play off in Settings, then lock the screen.

## Cause

YouTube pauses playback when `document.visibilityState` becomes `hidden`. WebKit also pauses media elements as the app leaves the foreground.

## Fix

`page-media.js` reports the page as visible and focused, and stops `visibilitychange`, but only after the page has played unmuted sound; before `6fc7373` this applied to every page in every frame. `isolated-media.js` and `BackgroundMedia` record which elements were playing and start them again after WebKit's pause, but not after a pause the user caused from the page or the lock screen.
