# CI: building WinBrowse

WinBrowse builds on a self-hosted CI server, reached over a private network. The iOS job runs on a Mac runner in host mode, with Xcode and xcodegen installed on that Mac. Host names, addresses and login details are kept in the maintainer's private notes, not in this repository.

| | |
|---|---|
| Workflow | `.forgejo/workflows/ios.yml` |
| Runner label | `ios` (host mode, Xcode 27.2, xcodegen, SwiftFormat and Node on the Mac runner) |

There is no GitHub CI. The Mac runner also handles manual builds over SSH.

## Pipeline

| Trigger | `check` | `build` | `publish` |
|---|---|---|---|
| push to `main` | lint and tests | unsigned IPA, uploaded as artifact `winbrowse-ipa` (30 days) | skipped |
| tag `v*` | same | same | deploys to the Cloudflare Worker (SideStore source) |
| manual dispatch | runs | runs | only if *publish* is ticked |

`check` runs `scripts/check.sh`: the linters, the Node tests of the report intake in `deploy/test/`, then the Debug build and the test target on an iPhone simulator. `build` starts only when `check` passes. Run the same check by hand from any Mac with `scripts/mac.sh scripts/check.sh`, which copies the working tree to the build Mac, runs it there and cleans up. Set `WINBROWSE_SIM` to a simulator UDID to choose the simulator.

Extensions are **not** refreshed in CI; the committed `App/Extensions-bundle` is what ships. Refresh locally with
`scripts/update-extensions.sh` and commit (it re-applies `scripts/patch-xadblock.py`).

## Versioning

SideStore only offers an update when the marketing version increases.

| Build origin | Version | Build number |
|---|---|---|
| push to `main` | `1.0.<run number>` | run number |
| tag `vX.Y.Z` | `X.Y.Z` | run number |
| local `scripts/build-ipa.sh` | `MARKETING_VERSION` in `project.yml` | timestamp |

The last build published by hand was `1.0.0`, so CI starts at `1.0.1`. If a tag lower than the published
version is pushed, SideStore will not offer it as an update.

## Releasing

```bash
git tag v1.0.1 && git push origin v1.0.1
```

The `publish` job needs these repository secrets on the CI server (Settings → Actions → Secrets):

- `CLOUDFLARE_API_TOKEN`: an API token with Workers Scripts read and write on the Cloudflare account.
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account ID.
- `SITE_URL`: the public address of the SideStore source, without a trailing slash. The build job also uses it to set the broken-site report endpoint (`SITE_URL` + `/api/reports`) in the IPA; without it the IPA has no Send option.

Without `CLOUDFLARE_API_TOKEN` or `CLOUDFLARE_ACCOUNT_ID`, `build` still passes and `publish` fails with a message that names the missing secret. Without `SITE_URL`, `build` also passes, but the IPA has no report endpoint.

Local fallback, run on a Mac: `scripts/publish.sh` (refreshes extensions, builds, deploys). Put `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` and `SITE_URL` in `~/.config/winbrowse/env`, one `NAME=value` per line. The script reads that file when it exists.

## Repository access

The repository is private on the CI server. Clone it over SSH with a key that your account has been given. The host and login are in the maintainer's private notes.
