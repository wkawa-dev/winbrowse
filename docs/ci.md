# CI: building WinBrowse on the build Mac

WinBrowse builds on the self-hosted ci-server instance on the build Mac, reached over private network. It uses the
same instance, runner and pipeline shape as WinMusic (see that repo's `docs/ci.md` for the host layout, runner
setup, private network quirks and troubleshooting table). There is no GitHub CI.

| | |
|---|---|
| ci-server | http://build-mac-1.example-tailnet.example.net:3300 |
| Repository | `ci-user/winbrowse` — `https://ci.example/ci-user/winbrowse.git` |
| Workflow | `.forgejo/workflows/ios.yml` |
| Runner label | `ios` (host mode, Xcode 27.2 + xcodegen on the Studio) |

> The Studio has two private network nodes. `build-mac-1` is the live one; `build-mac` is a stale,
> offline node. Always use the `-1` name.

## Pipeline

| Trigger | `build` | `publish` |
|---|---|---|
| push to `main` | unsigned IPA, uploaded as artifact `winbrowse-ipa` (30 days) | skipped |
| tag `v*` | same | deploys to the Cloudflare Worker (SideStore source) |
| manual dispatch | runs | only if *publish* is ticked |

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

Needs the repo Actions secret `CLOUDFLARE_API_TOKEN` (Settings → Actions → Secrets). The same token as WinMusic's
works (Workers Scripts Write); the Worker here is `winbrowse` on account `00000000000000000000000000000000`.
Without it `build` still passes and only `publish` fails, with an explicit message.

Local fallback on the Air: `scripts/publish.sh` (refreshes extensions, builds, deploys).

## Repository access

SSH goes through the `ci-server` alias in `~/ssh-keys/config` (port 2222, key `~/ssh-keys/build_key`).
Registration is disabled and the repo is private; the web UI needs the `ci-user` login.
