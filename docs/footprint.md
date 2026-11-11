# What pages can see of WinBrowse

Sites look for signs that they run in an embedded web view or next to a content blocker, and some change their behaviour when they find one. This document lists each difference between a WinBrowse tab and a plain WebKit page that a site can observe, where it comes from, and what a site could do with it.

## How it is measured

`Tests/Fixtures/footprint.js` runs in the page and collects:

- the own property names and symbols of `window`, `Function.prototype` and `Document.prototype`;
- for about 30 functions and accessors that browsers, blockers and polyfills often patch: the property descriptor, `name`, `length`, the text from `Function.prototype.toString`, own keys, whether it can construct, and whether a getter still throws when called on a plain object;
- the names of all message handlers under `window.webkit.messageHandlers`;
- the contents of `<head>` and every `data-` attribute.

`AppFootprintTests` (simulator only) compares that report with the same report from a web view that has no scripts. It loads three pages: a neutral origin, `x.com` and `m.youtube.com`. The test passes only when the differences equal the entries in `Tests/Fixtures/footprint-allowlist.json`. `AppScriptTests.appScriptsLeaveNoTraceThatFeatureProbesCanSee` checks the app's own page scripts alone, and expects no difference except the passkey method listed below.

When `AppFootprintTests` reports a new difference, decide whether it is acceptable. If it is, document it here, then record the allowlist again with `TEST_RUNNER_WINBROWSE_RECORD=1 scripts/check.sh` and review the changed lines in the diff.

## Differences the app causes

| Difference | Why | What a site could do with it |
|---|---|---|
| `PublicKeyCredential.isConditionalMediationAvailable` exists | WebKit on iOS 27.2 lacks it. The passkey authenticator adds it so that sites offer passkey sign-in. The method reports itself as native. | A site can compare this with the WebKit version in the user agent. |
| `Document` has the element fullscreen members (`fullscreenEnabled`, `fullscreen`, `webkitFullscreenElement`, `exitFullscreen` and others) | `WebViewFactory` sets `isElementFullscreenEnabled`, so pages can fullscreen their video. A bare web view does not. | A site can read `document.fullscreenEnabled` and see `true`. |
| A `<style>` element in `<head>` with the cosmetic filter selectors (seen on `x.com` and `m.youtube.com`) | Cosmetic filters from uBlock Origin Lite hide elements. A style sheet adopted from the isolated world (`document.adoptedStyleSheets`) was just as visible to the page, so the element is kept. The rules also contain an attribute name that uBlock Origin Lite generates at random: it changes between launches. The footprint probe replaces it with `[random]`. | A site can read the selectors and detect that a content blocker is active. The random attribute name is one more thing it can see, but it changes on every launch. |
| `window.webkit.messageHandlers.winext` exists in tabs that show an extension page | WebKit exposes a page-world handler to every frame of its web view. Extension pages need the handler to reach the extension runtime, so only tabs that show a `winext://` page get it. | A site in such a tab can see the handler's name. The native side accepts messages only from `winext://` frames and answers other frames with "forbidden". After a tab that showed an extension page goes back to a web page, the handler stays until the tab is rebuilt. |
| The app's own page scripts (media, passkeys, X timeline filter) | They replace some functions. The replacements keep the descriptor flags, `name`, `length` and native source text, including through `Function.prototype.toString` itself, and getters still throw on the wrong receiver. Ordinary tabs have no app handler in the page world, and the modules reach native code through a DOM event whose name is random for each launch. | Only the differences above. Visibility reports change only after a page plays sound: then `document.hidden`, `visibilityState` and `hasFocus()` report a visible, focused page, and `visibilitychange` is stopped. |

## Differences from bundled extensions and uBlock Origin Lite

These come from third-party code that WinBrowse runs unmodified (apart from the patch in `scripts/patch-xadblock.py`). WinBrowse cannot mask them without changing the code.

| Site | Source | Difference a site can observe |
|---|---|---|
| `x.com` | X-Posed `page-script.js`, page world | `XMLHttpRequest.prototype.open` and `send`, `window.fetch` and `Element.prototype.attachShadow` are replaced by functions whose source text is visible. Their `name` is empty. The XHR `open` loses its enumerable flag. Window globals `XPosed` and `__X_POSED_INJECTED__` exist. |
| `x.com` | uBlock Origin Lite scriptlet `json-edit-xhr-response` (X filter list) | `XMLHttpRequest.prototype.response` and `responseText` getters are replaced by functions that read `super.response`, and their source text shows it. The getters lose their enumerable flag. |
| `m.youtube.com` | SponsorBlock `js/document.js`, page world | `window.fetch` is replaced with visible source text and an empty `name`. Window globals `versionCB`, `teardownCB`, `playerResponse` and `ytInitialPlayerResponse` exist. |

The page-world `window.fetch` differences on `x.com` come from X-Posed. On `x.com` the XHR getters also differ because uBlock Origin Lite's X scriptlet runs in the page world. `Document.prototype` changes on `x.com` come from the fullscreen setting above.

## Review log

- Recorded on 11 November 2026 on the build Mac (iOS 27.2 simulator). Allowlist entries: 14 on the neutral page, 18 on `m.youtube.com`, 45 on `x.com`.
- Removed in this review: `window.webkit` and the `winext` handler on ordinary tabs. Before the fix, every site could see `winext`.
- Not yet explained: the element fullscreen members are absent from the `m.youtube.com` result. They are present on the neutral page and on `x.com`.
