# What pages can see of WinBrowse

Sites look for signs that they run in an embedded web view or next to a content blocker, and some of them change their behaviour when they find one. This document lists every difference between a WinBrowse tab and a plain WebKit page that a site can observe, why each one exists, and what a site could do with it.

## How it is measured

`Tests/Fixtures/footprint.js` runs in the page and collects:

- the own property names and symbols of `window`, `Function.prototype` and `Document.prototype`;
- for about 30 functions and accessors that browsers, blockers and polyfills commonly patch: the property descriptor, `name`, `length`, the text from `Function.prototype.toString`, own keys, whether it can construct, and whether a getter still throws when called on a plain object;
- which message handlers exist under `window.webkit.messageHandlers`;
- the contents of `<head>` and every `data-` attribute in the document.

Two tests compare that report with the same report from a web view that has no scripts:

| Test | What is installed | Expected difference |
|---|---|---|
| `AppScriptTests.appScriptsLeaveNoTraceThatFeatureProbesCanSee` | The app's own page and isolated scripts (media, passkeys, X timeline filter) | None, apart from the passkey methods listed below when WebKit lacks them |
| `AppFootprintTests` (simulator only) | A real tab configuration: app scripts, uBlock Origin Lite scripts and the bundled extensions, on a neutral origin, on x.com and on m.youtube.com | Exactly the entries in `Tests/Fixtures/footprint-allowlist.json` |

When `AppFootprintTests` fails, it prints each new difference. Decide whether the difference is acceptable, add it to this document, then rerun with `WINBROWSE_RECORD=1` to update the allowlist.

## The app's own scripts

| Difference | Why | What a site could do with it |
|---|---|---|
| `PublicKeyCredential.isConditionalMediationAvailable`, `getClientCapabilities`, `parseCreationOptionsFromJSON` and `parseRequestOptionsFromJSON` exist even where this WebKit version lacks them | The passkey authenticator needs them so that sites offer passkey sign-in | Compare them with the WebKit version in the user agent. They report themselves as native functions. |
| `navigator.credentials.create` and `get` answer with WinBrowse's own credentials | A sideloaded browser cannot reach iCloud Keychain from a web view | The credential objects are plain objects whose prototype is `PublicKeyCredential.prototype`. Calling a prototype getter on one of them throws. |
| After a page plays unmuted sound, `document.hidden`, `visibilityState` and `hasFocus()` report a visible, focused page and `visibilitychange` is stopped | Media keeps playing in the background and on the lock screen | Notice that visibility never changes after playback starts. Pages that never play sound see the real values. |

The replaced functions keep their descriptor flags, `name`, `length` and native source text, including through `Function.prototype.toString` itself, and getters still throw on the wrong receiver. No message handler exists in the page world: the page modules reach native code through a DOM event whose name is random for each app launch, and only the app's isolated world (`winbrowse`) answers it.

## uBlock Origin Lite and the extensions

These run third-party code, so their footprint is listed in `Tests/Fixtures/footprint-allowlist.json` after the first simulator run with `WINBROWSE_RECORD=1`. Known sources:

- uBlock Origin Lite scriptlets run in the page world on every page. Each enabled filter list decides which ones apply to a site.
- Cosmetic filters and extension CSS are added as plain `<style>` elements with no identifying `id` or attribute. A test showed that a style sheet adopted from an isolated world (`document.adoptedStyleSheets`) is just as visible to the page, and the page can remove it, so it gives no advantage.
- SponsorBlock's `document.js` runs in the page world on YouTube, and X-Posed's `page-script.js` wraps `XMLHttpRequest` and `fetch` in the page world on X.
- `window.webkit.messageHandlers.winext` exists in the page world so that extension pages opened in a tab can reach the extension runtime.
