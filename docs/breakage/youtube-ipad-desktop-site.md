# YouTube: playback on iPad needs the mobile site

| | |
|---|---|
| Site | `youtube.com` |
| Class | unknown: site behaviour in WKWebView on iPad, not established further |
| Status | worked around since the first commit (`86b594f`) |
| Regression test | `SitePolicyTests.bundledConfigurationIsValid` checks that the rule is present |

## Symptom

On iPad, WebKit asks for desktop sites by default. The original code records that YouTube's mobile site is the one that plays reliably in WinBrowse. The exact failure on the desktop site was not written down.

## Reproduction

Unknown. To reproduce: remove the `youtube.com` entry from `App/Resources/site-config.json`, open a video on an iPad, and compare playback, SponsorBlock skipping and background play with the mobile site.

## Cause

Unknown.

## Fix

`App/Resources/site-config.json` sets `mobileSiteOnTablets` for `youtube.com`, and `WebViewFactory.contentMode(for:desktop:)` asks for the mobile site there. SponsorBlock and the background-play module are tuned for the mobile site. Remove the entry once the desktop site plays, skips and keeps playing in the background on iPad.
