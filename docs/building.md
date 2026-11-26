# Building

## From source

```bash
scripts/install.sh
```

This builds the app, signs it with your Apple Development identity (set `SIGN_IDENTITY`; a stable signature keeps the microphone grant across rebuilds), installs `~/Applications/Needs You.app`, links `~/.local/bin/needs-you` and downloads the speech models once (about 630 MB). Local builds never update themselves.

If `swift build` hangs on "Fetching binary artifact" (FluidAudio's NemoTextProcessing xcframework), download that file with curl, check its sha256 against FluidAudio's `Package.swift`, and copy it into `~/Library/Caches/org.swift.swiftpm/artifacts/`.

SwiftPM writes SDK 14.0 into the binaries, which keeps AppKit in the macOS 14 look. `install.sh` stamps the real SDK version with `vtool` so the app gets the current design.

The app icon is in `Resources/AppIcon/` (regenerate with `render.py`). `install.sh` compiles the `.icon` with actool and falls back to the `.icns`.

## Router Debug (local builds only)

Window, Router Debug (⌥⌘D) lists every target the router sees right now (connected chats, herdr chats that never connected, chat apps) and has a playground: type a command and it shows the matcher, topic, on-device model, routing memory and the result, without sending anything. Release builds (they carry an update feed) have neither the menu item nor the window.

## UI demos

`NeedsYou --ui-demo main|settings|training|menu` opens a window with no socket, mic or audio, so you can screenshot it. `--island-demo` steps the status island through every state.

## Releases

`.github/workflows/release.yml` turns a push to main into a release once the repo variable `RELEASES_ENABLED` is `true`. The version comes from commit subjects since the last `v*` tag (`scripts/release/next-version.sh`): `feat!:` or `BREAKING CHANGE` bumps major, `feat:` bumps minor, anything else bumps patch. `[skip release]` skips it. The build number is the commit count.

The macOS job builds the bundle with `scripts/bundle.sh`, signs it with a Developer ID certificate, notarizes and staples it, then builds a DMG and a zip (`scripts/release/package.sh`). It signs the zip for Sparkle, writes `appcast.xml` and creates the tag and GitHub release. The app reads `releases/latest/download/appcast.xml`. With `HOMEBREW_TAP` and `HOMEBREW_TAP_TOKEN` set, it also updates the Homebrew cask.

The workflow needs these Actions secrets: `SPARKLE_ED_PRIVATE_KEY`, `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`.

A manual run (Actions, Release, Run workflow) is a dry run by default. It builds, signs and notarizes, and keeps the files as a workflow artifact without tagging.

To test updates on a throwaway copy, build two versions with `BUNDLE_ID=dev.homemade.needs-you.updatetest FEED_URL=http://127.0.0.1:8765/appcast.xml ED_PUBLIC_KEY=... scripts/bundle.sh`, serve the newer zip and its appcast, then run `"<old copy>/Contents/MacOS/NeedsYou" --update-check` (add `--install` to install on exit).
