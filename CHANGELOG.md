# Changelog

## Unreleased

### Site compatibility

- Per-site switches for network blocking, cosmetic filters, scriptlets, background play and passkeys, replacing the single uBlock Origin power button. Sites trusted in earlier versions keep uBlock Origin off.
- The app's own page scripts can no longer be detected by sites: replaced functions look native, and no WinBrowse message handler is visible to pages.
- Pages are told they stay visible only after they play sound, instead of every page all the time, so chat and mail sites see real visibility again.
- Cosmetic filters and extension styles no longer carry identifying markers.
- Web pages can load only the extension files their manifest exposes to them.
- The Safari version in the user agent follows the installed iOS version.

### Fixes

- "Proceed" on the page-blocked screen no longer rebuilds the tab again and again.
- One filter rule that WebKit refuses no longer removes every exception rule; exceptions for `denyallow` filters no longer cancel unrelated blocks.
- The number of active network rules is no longer overstated.
- Passkeys: relying-party IDs are checked against the Public Suffix List, `timeout` is honoured, cancelling a pending autofill request works, and tabs that are not on screen cannot raise passkey prompts.
- Extension fetches no longer carry cookies across a redirect to another host.
- The keychain copy of cookies and settings stays on the device instead of travelling into backups.

### Diagnostics

- "Report broken site" in the menu shares a JSON report with personal data removed.
- The uBlock screen shows which filters WebKit cannot express and which rules it refused.
- `tools/webcompat/wb.py` bisects which protection and filter list break a page; see `docs/triage.md`.

### Smaller app

- About 2 MB of unused uBlock Origin Lite files are no longer bundled.
