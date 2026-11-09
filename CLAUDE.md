# WinBrowse

New to the project? Start with `the removed handoff note.md` (lead-dev brief, infrastructure, open work).

## Git workflow

Do not create branches. Work, commit and push directly on `main`. The `origin` remote is the ci-server instance on the CI server (`https://ci.example/ci-user/winbrowse.git`); CI and releases run there, see `docs/ci.md`.

## Mobile development builds

Run Xcode/iOS, Android, Gradle, Java/Kotlin and simulator work locally on this Mac. iOS builds require a full Xcode install; this Air currently has only Command Line Tools, so install Xcode at `/Applications/Xcode.app` before building.

CI iOS jobs need a host-mode Mac `ci-server-runner` with the `ios` label registered against the ci-server instance on the CI server. The runner is being moved off the machine being sold; register it on the Air or another Mac before decommissioning the old one.
