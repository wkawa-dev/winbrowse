<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/icon.png" width="120" height="120" alt="WinBrowse logo" />

# WinBrowse

A WebKit browser for iOS and iPadOS in the style of Windows 10 Mobile. It runs Chrome extensions, blocks ads with uBlock Origin Lite's filter lists, and keeps media playing in the background.

[![iOS 17+](https://img.shields.io/badge/iOS-17.0%2B-blue.svg?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

</div>

<div align="center">

| Browsing | Menu | Tabs | uBlock Origin Lite |
| :---: | :---: | :---: | :---: |
| <img src="assets/screenshots/02-browser-webpage.png" width="180" alt="Browsing a page" /> | <img src="assets/screenshots/03-metro-menu.png" width="180" alt="Menu overlay" /> | <img src="assets/screenshots/04-tab-switcher.png" width="180" alt="Tab switcher" /> | <img src="assets/screenshots/05-ublock-origin.png" width="180" alt="uBlock Origin Lite screen" /> |

</div>

## What it includes

- **Extensions:** Chrome MV3 extensions run on a `chrome.*` shim (`App/Resources/winext-shim.js`). Four are bundled: SponsorBlock, X-Posed, The Ad Blocker for X and uBlock Origin Lite.
- **Ad and tracker blocking:** uBlock Origin Lite's rules become WebKit content-blocking rules. The uBlock screen shows which filters WebKit cannot express.
- **Per-site protections:** network blocking, cosmetic filters, scriptlets, background play and passkeys can each be switched off for one site.
- **Background play:** pages that play sound stay playing when the app leaves the foreground.
- **Passkeys:** the app is its own WebAuthn authenticator. Keys stay on the device and each use needs Face ID or the passcode.
- **Broken-site reports:** the menu item "report broken site" sends a report with personal data removed, or shares it as a file. Nothing is sent unless you tap Send.

How the parts fit together is in [docs/architecture.md](docs/architecture.md).

## Install

- **SideStore or AltStore:** add the source URL that the maintainer gives you, then install WinBrowse from the app list.
- **TrollStore or another sideloader:** download the unsigned `.ipa` from a CI run's artifacts (see [docs/ci.md](docs/ci.md)).

## Build

You need a Mac with Xcode 27.2 and these tools:

```bash
brew install xcodegen swiftformat node
```

Generate the Xcode project and open it. `WinBrowse.xcodeproj` and `App/Info.plist` are generated from `project.yml` and are not tracked.

```bash
git clone <repository URL> winbrowse
cd winbrowse
xcodegen generate
open WinBrowse.xcodeproj
```

Other commands:

| Command | What it does |
|---|---|
| `scripts/check.sh --lint-only` | Lint, comment check, vendored-file hashes, tool tests, type check. Needs no simulator. |
| `scripts/check.sh` | The same, then the unit and WebKit tests in an iPhone simulator. |
| `scripts/e2e.sh` | End-to-end cases against a running app. |
| `scripts/mac.sh <command>` | Runs a command on the build Mac in a temporary copy of the tree, then cleans up. |
| `scripts/build-ipa.sh` | Builds an unsigned Release IPA in `dist/`. |
| `scripts/update-extensions.sh` | Refreshes the bundled extensions and rule lists. |

Testing is described in [docs/testing.md](docs/testing.md).

## Continuous integration

The CI server runs `.forgejo/workflows/ios.yml` on a Mac runner. Each push to `main` runs the checks and builds an unsigned IPA. A `v*` tag also publishes the IPA to the SideStore source. The pipeline, versioning and secrets are in [docs/ci.md](docs/ci.md).

## Fixing a broken site

[docs/triage.md](docs/triage.md) is the runbook. It covers how to reproduce a report, find the protection or filter list that causes it, and add a regression test. What pages can observe about WinBrowse is listed in [docs/footprint.md](docs/footprint.md).

## Project layout

```text
App/             the app: Browser, Blocker, Extensions, Media, Support, UI, Resources
App/Extensions-bundle/  vendored extensions (changed only by scripts)
Tests/           unit and WebKit tests, fixtures, golden files and end-to-end cases
tools/webcompat/ wb.py: reproduce and bisect site breakage
deploy/          Cloudflare Worker: SideStore source, report intake and its D1 migration
scripts/         checks, builds, publishing and maintenance
docs/            architecture, testing, CI, triage, footprint, breakage cases
project.yml      XcodeGen project specification
```

## Third-party software

WinBrowse bundles software that keeps its own licences:

- **uBlock Origin Lite**, copyright Raymond Hill, GPL-3.0.
- **SponsorBlock**, copyright Ajay Ramachandran, LGPL-3.0.
- **X-Posed**, as published on the Chrome Web Store. It includes Lucide icons (ISC) and Natural Earth data (public domain). The notices are in `App/Extensions-bundle/xposed/`.
- **The Ad Blocker for X**, copyright Alexey Ryzhkov, as published on the Chrome Web Store, with a local patch applied by `scripts/patch-xadblock.py`.
- **Public Suffix List**, Mozilla Foundation, MPL-2.0. It is downloaded at build time from a pinned commit by `scripts/fetch-public-suffix-list.sh`.

## License

WinBrowse is licensed under the [MIT License](LICENSE).
