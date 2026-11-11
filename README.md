<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon.png" width="120" height="120" alt="WinBrowse Logo" />

# WinBrowse

**A Windows 10 Mobile styled WebKit browser for iOS & iPadOS with desktop-class extension support, uBlock Origin Lite, SponsorBlock, and background media playback.**

[![iOS 17+](https://img.shields.io/badge/iOS-17.0%2B-blue.svg?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift 6 toolchain, Swift 5 mode](https://img.shields.io/badge/Swift-6%20toolchain-orange.svg?style=flat-square&logo=swift)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![SideStore Compatible](https://img.shields.io/badge/SideStore-Compatible-brightgreen.svg?style=flat-square)](https://sidestore.io/)
[![No JIT Required](https://img.shields.io/badge/JIT-Not%20Required-blueviolet.svg?style=flat-square)](#)

</div>

---

## Overview

**WinBrowse** brings back the beloved Metro / Modern UI of Windows 10 Mobile and Windows Phone (Edge) to modern iOS and iPadOS devices. Behind the fluid typography and tilt animations is a custom **Chrome WebExtension runtime** executing on Apple's WebKit engine alongside native content blocking compiled from uBlock Origin Lite's filter lists.

Unlike browsers that require JIT or modified WebKit frameworks, WinBrowse runs cleanly within standard iOS capabilities—making it installable via **SideStore**, **AltStore**, **TrollStore** (where supported on iOS 17), or Xcode.

---

## Screenshots

<div align="center">

| Web Browsing & Metro App Bar | Metro Menu Overlay | Tab Switcher Cards |
| :---: | :---: | :---: |
| <img src="assets/screenshots/02-browser-webpage.png" width="250" alt="Web Browsing with Metro controls" /> | <img src="assets/screenshots/03-metro-menu.png" width="250" alt="Windows Phone Menu Overlay" /> | <img src="assets/screenshots/04-tab-switcher.png" width="250" alt="Metro Tab Switcher Cards" /> |

| uBlock Origin Lite Panel | Extension Manager | SponsorBlock MV3 Popup |
| :---: | :---: | :---: |
| <img src="assets/screenshots/05-ublock-origin.png" width="250" alt="uBlock Origin Lite Filter Lists" /> | <img src="assets/screenshots/06-extensions-manager.png" width="250" alt="Extensions Manager" /> | <img src="assets/screenshots/07-sponsorblock-popup.png" width="250" alt="SponsorBlock Extension Popup" /> |

| Settings & Metro Accent Colors |
| :---: |
| <img src="assets/screenshots/08-settings.png" width="250" alt="Settings & Metro Accent Colors" /> |

</div>

---

## Built-In Extensions & Features

| Feature / Extension | Implementation Details |
| :--- | :--- |
| **SponsorBlock 6.x** | The **real Chrome Web Store extension build** (MV3) running on WinBrowse's `chrome.*` shim. Content scripts inject into YouTube, the background worker tracks segments, and the popup/options sheets provide interactive segment management. Automatically skips sponsors, intros, outros, self-promos, previews, and interaction reminders. |
| **uBlock Origin Lite** | Official uBO WebKit engine (uBO Lite for Safari). Its compiled filter lists become WebKit content-rule lists; the uBlock screen reports how many rules are active and which filters WebKit cannot express. Injects cosmetic element-hiding filters, procedural filters, and scriptlets for YouTube and streaming ad circumvention. Includes per-site switches for network blocking, cosmetic filters and scriptlets, and filter list customization (EasyList, EasyPrivacy, AdGuard Mobile, Annoyances, Block LAN). |
| **X-Posed 4.x** | The authentic X-Posed extension: displays geolocation country flags, account creation dates, and client information next to X (Twitter) handles. Background scripts communicate through a native cookie-forwarding fetch proxy. |
| **The Ad Blocker for X** | Strips promoted ads, "Who to follow" recommendations, and sponsored threads from X's timeline: the extension hides them in the page, and a WinBrowse page module removes them from X's timeline responses. |
| **Background Playback** | Keeps YouTube and web media playing when backgrounded or locked. Pages that play sound are told they stay visible (only those pages, and undetectably), configures `AVAudioSession` to `.playback`, automatically resumes paused WebKit playback, and integrates with Control Center / lock screen media controls. |
| **Passkeys** | WinBrowse is its own WebAuthn authenticator (ES256). Keys are created on the device, kept in the iOS keychain, and unlocked with Face ID or the passcode for each use. Keys are not synced or backed up. Sites see a platform authenticator. Manage saved passkeys in Settings → passkeys. |
| **Windows Phone Metro UI** | Clean, blank new-tab page, 3D tilt press animations, the peeling "…" menu, collapsible bottom app bar, and the 20 Windows Phone accent colours. |
| **Site compatibility tools** | Per-site protections with a bundled, documented site configuration; "report broken site" shares a redacted report; Debug builds expose a control port that `tools/webcompat/wb.py` uses to bisect which protection or filter list breaks a page. |

---

## Extension Runtime

WinBrowse provides an isolated, standards-aligned extension environment bridging WebKit with the WebExtension API:

- **Isolated Execution (`WKContentWorld`)**: Each extension's content scripts run inside their own isolated `WKContentWorld`. Scripts configured with `"world": "MAIN"` execute directly in the page world.
- **`chrome.*` API Bridge**: Implemented in `App/Resources/winext-shim.js` and `App/Extensions/ExtensionHost.swift`:
  - `chrome.runtime`: messaging (`sendMessage`, `onMessage`), connect ports (`connect`, `onConnect`), `getURL`, `getManifest`, `id`.
  - `chrome.tabs`: `query`, `get`, `create`, `update`, `remove`, `sendMessage`, `onActivated`, `onUpdated`, `onRemoved`.
  - `chrome.storage`: `local`, `sync`, `session` storage areas with asynchronous persistence and `onChanged` event dispatching.
  - `chrome.i18n`: localized string lookups from extension `_locales/`.
  - `chrome.scripting`: programmatic script injection into target tabs.
  - `chrome.alarms`: scheduled timer events for background workers.
  - `chrome.permissions` & `chrome.windows`: browser window and permission queries.
- **Service Workers & Custom Scheme**: Background workers run in headless web views over the internal `winext://<id>/` scheme handled natively by `WinextSchemeHandler`.
- **Extension UI Pages**: Popup pages and option tabs are loaded from the app bundle and presented in native modal sheets.

---

## Installation

### SideStore / AltStore (Recommended)
1. In SideStore, navigate to **Sources** &rarr; tap **+** (Add Source).
2. Enter the source URL:
   ```text
   https://<your-source-host>/source.json
   ```
3. WinBrowse will appear in your app list ready to install and receive one-tap updates.
4. Alternatively, download an unsigned `.ipa` from a CI run's artifacts (see [CI](#ci)) and sideload it.

### TrollStore
Download the unsigned IPA from a CI run's artifacts (see [CI](#ci)) and open it directly with TrollStore for permanent, revokeless installation.

---

## Building from Source

### Prerequisites
- A Mac with Xcode (CI uses Xcode 27.2) and an iOS 17 or newer simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and Node: `brew install xcodegen swiftformat node`

### Quick Start
```bash
# Clone the repository (the host is private; ask the maintainer for access)
git clone <repository URL> winbrowse
cd winbrowse

# Generate Xcode project from project.yml
xcodegen generate

# Open in Xcode
open WinBrowse.xcodeproj
```
Select the **WinBrowse** scheme, choose your connected device or simulator, and hit **Run** (⌘R).

### Simulator Automation
To build and launch automatically on a booted iOS Simulator:
```bash
scripts/sim.sh
```

### Checks and tests
```bash
scripts/check.sh --lint-only        # lint, comment check, vendored hashes, tool tests, type check (no Xcode needed)
scripts/check.sh                    # the above, then the unit and WebKit tests in a simulator
scripts/e2e.sh                      # end-to-end cases against the running app
```
See **[docs/testing.md](docs/testing.md)**.

### Building Unsigned Release IPA
To compile a release build and package an unsigned `.ipa` into `dist/`:
```bash
scripts/build-ipa.sh
```

### CI

Builds run on a self-hosted CI server; the iOS job runs on a Mac runner in host mode. Push to `main` for an unsigned IPA artifact; push a
`v*` tag to also publish it to the SideStore source. Details in **[docs/ci.md](docs/ci.md)**.

### Updating Extension Rules & Bundles
To fetch the latest Chrome Web Store CRX packages and compiled uBlock Origin Lite rulesets:
```bash
scripts/update-extensions.sh
```

---

## Site compatibility

- **[docs/architecture.md](docs/architecture.md)**: how pages, content worlds, extensions, filter lists and site policy fit together.
- **[docs/footprint.md](docs/footprint.md)**: every difference between a WinBrowse tab and plain WebKit that a site can observe, and the tests that keep that list honest.
- **[docs/triage.md](docs/triage.md)**: the runbook from a broken-site report to a tested fix, using `tools/webcompat/wb.py` against the Debug control port (`localhost:8899`, loopback only, per-run token; `curl -H "X-Debug-Token: $(cat /tmp/winbrowse-debug-token)" localhost:8899/help` lists its routes).
- **[docs/breakage/](docs/breakage/)**: one case file per site fix, with reproduction, cause and how it was established.

---

## Project Structure

```text
winbrowse/
├── App/
│   ├── Blocker/          # filter list conversion, compilation and uBO cosmetic/scriptlet injection
│   ├── Browser/          # tabs, site policy, web view factory, app page scripts, passkeys, vault, debug port
│   ├── Extensions/       # chrome.* runtime: host, messages, storage, tabs, network, winext:// scheme
│   ├── Extensions-bundle/ # vendored extensions and uBO Lite rulesets (changed only by scripts)
│   ├── Media/            # background playback
│   ├── Resources/        # injected scripts (page-*.js, isolated-*.js, winext-shim.js) and site-config.json
│   ├── Support/          # JSON helpers, Public Suffix List
│   └── UI/               # SwiftUI screens and the Metro design system
├── Tests/                # unit and WebKit tests, fixtures, golden files, end-to-end cases
├── tools/webcompat/      # wb: reproduce, bisect and triage site breakage
├── docs/                 # architecture, footprint, triage, testing, CI, breakage cases, schemas
├── scripts/              # check, typecheck, e2e, mac, sim, build-ipa, publish, update/trim extensions
├── deploy/               # Cloudflare Workers config for the SideStore source
└── project.yml           # XcodeGen project spec (the .xcodeproj is generated)
```

---

## Third-Party Notices & Licenses

WinBrowse bundles third-party software and extensions, each retaining their respective open-source licenses:

- **uBlock Origin Lite**: Copyright (c) Raymond Hill. Licensed under the [GNU General Public License v3.0 (GPL-3.0)](https://github.com/uBlockOrigin/uBOL-home/blob/master/LICENSE.txt).
- **SponsorBlock**: Copyright (c) Ajay Ramachandran. Licensed under the [GNU Lesser General Public License v3.0 (LGPL-3.0)](https://github.com/ajayyy/SponsorBlock/blob/master/LICENSE).
- **X-Posed**: bundled as published on the Chrome Web Store. It includes Lucide icons (ISC License, `App/Extensions-bundle/xposed/third-party/LUCIDE-LICENSE.txt`) and Natural Earth data (public domain, `NATURAL-EARTH-NOTICE.txt`).
- **The Ad Blocker for X**: Copyright (c) Alexey Ryzhkov ([source](https://github.com/aliocharyzhkov/twitter_cleaner)), bundled as published on the Chrome Web Store, with a local patch applied by `scripts/patch-xadblock.py`.
- **Public Suffix List**: Mozilla Foundation, [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/). Downloaded at build time from a pinned commit by `scripts/fetch-public-suffix-list.sh`.

---

## License

WinBrowse is licensed under the [MIT License](LICENSE).
