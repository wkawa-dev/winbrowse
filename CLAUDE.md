# WinBrowse

## Git workflow

Do not create branches. Work, commit and push directly on `main`.

## Mobile development builds

When doing mobile development work — Xcode/iOS, Android, Gradle, Java/Kotlin, simulators, code signing, or anything else that needs a mobile toolchain — run `whoami` first.

If it returns `air`, check whether the build Mac is reachable over private network:

```sh
private network ping -c 1 build-mac.example-tailnet.example.net
```

If it answers, do the Xcode, Java, Android, and other mobile build/test work on the Studio over SSH instead of on the Air. This keeps the Air fast and saves disk space:

```sh
ssh -i ~/ssh-keys/build_key ci-user@build-mac.example-tailnet.example.net
```

Sync the working tree there (or clone it), run the build/tests there, and bring back only the artifacts you need. If `xcodebuild` reports that the active developer directory is Command Line Tools, prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Clean up after yourself before finishing: stop simulators/emulators and Gradle daemons, kill background build/log processes you started, and delete temporary checkouts, build outputs, and DerivedData you created on the Studio. Leave it as you found it.

If the Studio is unreachable, say so before falling back to local builds. If `whoami` does not return `air`, this section does not apply.
