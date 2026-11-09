# CI: building WinBrowse with ci-server on the CI server

WinBrowse builds on the self-hosted ci-server instance on the CI server, reached over
private network. The iOS job runs on a host-mode Mac `ci-server-runner`
(Xcode 27.2 + xcodegen 2.46); see WinMusic's `docs/ci.md` for the runner setup
and troubleshooting. There is no GitHub CI.

| | |
|---|---|
| ci-server | https://ci.example |
| Repository | `ci-user/winbrowse` — `https://ci.example/ci-user/winbrowse.git` |
| Workflow | `.forgejo/workflows/ios.yml` |
| Runner label | `ios` (host mode, Xcode 27.2 + xcodegen on the Mac runner) |

The ci-server host is stable. The Mac runner is the build Mac (`build-mac`), which
also handles manual builds over SSH.

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

Needs the repo Actions secret `CLOUDFLARE_API_TOKEN` (Settings → Actions → Secrets). It holds the user-owned
Cloudflare token `ci-api-token`, scoped to Workers Scripts Read + Write on the example-account account
`00000000000000000000000000000000`; the Worker here is `winbrowse`. Without it `build` still passes and only
`publish` fails, with an explicit message. `v1.0.1` was the first release published this way.

Local fallback (run on the Studio): `scripts/publish.sh` (refreshes extensions, builds, deploys).

## Repository access

SSH goes through the `ci-server` alias in `~/ssh-keys/config` (CI server, port 2222, key
`~/ssh-keys/ci_key`). Registration is disabled and the repo is private;
the web UI needs the `ci-user` login.
