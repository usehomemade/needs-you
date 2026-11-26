---
id: TASK-39
title: >-
  Public release on GitHub (signed + notarized CI build on release tag), in-app
  auto-update, Homebrew cask
status: Done
assignee: []
created_date: '2026-11-25T11:42:37Z'
labels:
  - hm-1366
dependencies: []
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1366
Related: TASK-40 (HM-1368), TASK-35 (HM-1360), TASK-42 (HM-1370), TASK-9 (HM-1321), TASK-44 (HM-1373)

The owner (voice, 25 Nov ~12:40): "release this":

* Pushing to main with a release tag (the tag created automatically) triggers a GitHub Action. It builds the app, signs it with his Developer ID, notarizes it and uploads a new GitHub release.
* The app auto-updates: teammates or random customers who download it see an "Update" button in the app.
* A Homebrew install would also be great.

**Plan:**

* release-please (or similar) on main for versions and tags.
* A macOS runner builds, signs (Developer ID Application), notarizes with the ASC API key (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8` in the team's secret store) and staples.
* The DMG and zip are uploaded to the GitHub release.
* Sparkle 2 with EdDSA-signed appcast for in-app updates and an "Update" button.
* A Homebrew tap with a cask, bumped by CI.

**Open:**

* Which GitHub account or org hosts it (the owner's personal account or usehomemade), and public or private.
* Developer ID certificate: is it in Keychain, and should it be exported to CI secrets?
* Releasing publicly needs a final OK.

## History

### 2026-11-25 11:44 UTC (agent)

Started (agent, worktree `.worktrees/hm-1366`, branch hm-1366): shared bundle script, release workflow (build, Developer ID sign, notarize, DMG + zip), Sparkle 2 updates, Homebrew cask template, secret scan of the git history. Nothing goes public; the public/private choice comes back to the owner.

### 2026-11-25 12:04 UTC (agent)

Merged to main and pushed (72a4f31). What works now:

- `scripts/bundle.sh` is the one bundle step for `install.sh` and CI (version into Info.plist, Sparkle.framework, signing inside out, vtool SDK stamp, actool icon).
- `.github/workflows/release.yml` (passes actionlint): version from commit subjects (`feat!:` major, `feat:` minor, else patch), build on macos-26, Developer ID signing, notarize and staple, DMG and zip, Sparkle appcast, tag and GitHub release, cask bump. Automatic releases stay **off** until the repo variable `RELEASES_ENABLED=true`. Manual runs are dry runs.
- Sparkle 2: daily checks, "Check for Updates…" in the app menu and the menu bar menu, plus an "Update to X" button in the main window toolbar, the menu bar menu and Settings → General. Local `install.sh` builds never update themselves.
- Tested locally on a throwaway copy (bundle id `dev.homemade.needs-you.updatetest`, local appcast): 0.9.0 found 0.9.1, then downloaded, verified the EdDSA signature and installed it. A tampered signature was refused ("improperly signed") and the app stayed on 0.9.0.
- A release build downloads the speech models in the background on first launch (before this, Smart Turn only came from `install.sh`).
- Secrets: `SPARKLE_ED_PRIVATE_KEY`/`SPARKLE_ED_PUBLIC_KEY` are in the team's secret store. `SPARKLE_ED_PRIVATE_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` are set as CI secrets.
- Secret scan: gitleaks found 0 leaks across all 42 commits.

Needs owner (1 of 2), the Developer ID certificate, about 2 minutes. The ASC API refuses to create one ("This operation can only be performed by the Account Holder"). Nothing uses the old keychain identity.
1. Open https://developer.apple.com/account/resources/certificates/add
2. Pick **Developer ID Application** (G2 Sub-CA), then Continue.
3. Upload `~/Downloads/NeedsYouCI.certSigningRequest` (CN "Needs You CI"; its key is in the team's secret store as `MACOS_CERT_KEY_PEM`), then Continue. You don't need to download anything.
4. The agent then runs `scripts/release/ci-cert.sh`. It finds the cert through the API, builds the p12 and stores `MACOS_CERT_P12`/`MACOS_CERT_PASSWORD` in the secret store and in CI.

Needs owner (2 of 2), going public: details in the next comment.

### 2026-11-25 12:04 UTC (agent)

Going public: repo still **private**. The scan found no secrets, but it did find personal data, so per the instruction I stopped here.

Scan: gitleaks over all refs found 0 leaks. I also grepped every blob in history for paths, emails, address, phone, IBAN, tax ids, tokens and hostnames. No audio files, recordings or real transcripts were ever committed. Training and test lines are scripted sentences.

Personal or internal data in the code:
1. Your first name, about 170 times in today's code: user-facing strings ("Ask <name> before…", "<name> here"), the name-spelling fixes for Parakeet, and identifiers like `<name>sTurn`. AGENTS.md and the bundled agent instructions say "ask <name> out loud". A history rewrite would not remove this.
2. **History only** (commits 000bfe5 and 2e30fea, removed in HM-1321): `scripts/install.sh` had the internal secrets host name, an internal Keychain item name and the ELEVENLABS key fetch. No values, but it shows internal infrastructure.
3. Your Apple Development certificate SHA-1 in install.sh/bundle.sh. It is public by design (in every signed binary), so low risk.
4. `docs/morning-test-plan.md`: "<name> Microphone" (your iPhone name), plus references to another app and homemade in the README.

Options:
- (a) Make it public as is. The only thing a cleanup would hide is item 2, and that needs a history rewrite (`git filter-repo --replace-text` on those strings, then a force-push to main; the other agents' worktrees would need a rebase). About 15 minutes with the rewrite, 1 minute without.
- (b) Clean first: make the user's name a setting (no hardcoded "The owner" strings), make the agent instructions generic, drop the morning test plan, and rewrite history for item 2. About 2 to 3 hours. Better for "random customers" anyway.

Either way, after it goes public: set repo variable `RELEASES_ENABLED=true`, and optionally create `usehomemade/homebrew-tap` with `HOMEBREW_TAP=usehomemade/homebrew-tap` and a `HOMEBREW_TAP_TOKEN` secret.

### 2026-11-25 12:18 UTC (agent)

CI dry run is green: https://github.com/usehomemade/needs-you/actions/runs/45611838871. It built 1.0.0 (build 45) on macos-26 with Xcode 26.6, made the DMG, the zip, the EdDSA-signed appcast and the cask, and did not tag. Without the cert the signature was ad-hoc, so nothing was notarized yet.

Fixes along the way: `Subtitles.swift` had an expression that Swift 6.3 on CI could not type-check (fixed), and the org's artifact storage quota is full, so the artifact upload no longer fails the job. main is pushed (0a3ba56). Worktree removed.

Waiting on the owner: (1) upload the CSR (steps above), (2) the public choice (a) or (b). Then: run `ci-cert.sh`, do a dry run with notarization, go public, set `RELEASES_ENABLED=true`, create the tap.

### 2026-11-25 12:38 UTC (agent)

The Developer ID cert is done. `ci-cert.sh` found the owner's new "Needs You CI" Developer ID Application cert (expires 25 Dec 2027) and built the p12. `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_CERT_KEY_PEM`, the CSR and copies of the ASC keys are in the team's secret store, and the p12 and password are also CI secrets.

Signed and notarized dry run is green: https://github.com/usehomemade/needs-you/actions/runs/45614687251
- Authority: Developer ID Application (34LRG4TQRP)
- notarization: Accepted for both the app and the DMG
- `spctl`: "accepted, source=Notarized Developer ID"
- stapler validate: OK

Now working on option (b), the name as a setting, in worktree `hm-1366-name`.

### 2026-11-25 12:46 UTC (agent)

Option (b) is done and on main (74a30af, pushed).
- **Your Name** setting: a first-run window plus Settings → General (Your Name, Also Heard As, Say It Like). Spoken greetings ("Good night, <name>"), agent states, voice previews and the agent instructions ("ask <name> out loud", or "the user" when empty) all use it.
- Name spelling fixes, Kokoro phonemes, per-language spellings for the native voices (HM-1368) and recogniser hints now come from prefs. identifiers named after the owner are now `user*`, and old history.json still loads.
- Removed: docs/morning-test-plan.md, personal mentions in README and AGENTS.md, real chat titles and handles in tests, the CI cert script (it now lives at `~/.local/share/needs-you-release/`).
- Merged with hm-1360, hm-1370 and the hm-1368 PR. Every speech path also runs SpeechText. 53 tests pass. `git grep` for the name, handle, internal hosts and the old app finds nothing.
- The owner's install keeps its behaviour: his prefs now hold `userName` set to the owner's name, the old spelling regex, a phonetic spelling of the name, the per-language spellings and transcript fixes (two share, Homemade and a few tool names). His running app is not reinstalled yet.

**Blocked: history rewrite, so the repo is not public yet.**
1. Two active worktrees have uncommitted work on the old history: `hm-1364-mcp` (10 files) and `hm-1369-1370` (1 file). A rewrite would orphan them, and merging them later would bring the old commits back.
2. PR #1 (hm-1368, merged on GitHub) keeps `refs/pull/1/head`, which points at the old history. GitHub doesn't let us delete PR refs. After a force-push, those old commits would still be reachable in a public repo (internal secrets host and Keychain item name).

The rewrite is ready and tested in a scratch clone with `git filter-repo`: it drops docs/morning-test-plan.md, replaces the host, Keychain item, handle, old-app name and real chat titles, and leaves the current tree byte-identical.

Options:
- (A) Skip the rewrite and go public now. The exposed strings are a private-network-only hostname and a Keychain item name, no values.
- (B) Rewrite and recreate the repo. Wait for those two agents to commit and merge, delete and recreate `usehomemade/needs-you`, push the rewritten history, then set the secrets and variables again (about 20 minutes). PR #1 and old Actions runs are lost.
- (C) Rewrite, force-push, and ask GitHub Support to remove the PR ref.

### 2026-11-25 12:48 UTC (agent)

The owner, 25 Nov ~13:50: option A, go public now without a history rewrite. Release agent resumed.

### 2026-11-25 12:50 UTC (agent)

The owner, 25 Nov: switched to the rewrite. Squash all history into one initial commit, recreate the GitHub repo, then publish. The old history is kept only as a local mirror backup.

### 2026-11-25 12:50 UTC (agent)

On hold, as asked: the repo is still private, and there is no release and no tag.
- Making the repo public was refused by the agent's permission check ("Sensitive Information Leakage"). The owner has to do that step himself or allow it.
- `usehomemade/homebrew-tap` already exists and is public (the homemade CLI formula). The needs-you cask goes in `Casks/needs-you.rb`. `HOMEBREW_TAP=usehomemade/homebrew-tap` is set.
- `HOMEBREW_TAP_TOKEN` is missing. GitHub has no API for creating fine-grained tokens, and deploy keys are disabled in the org. The owner creates it at https://github.com/settings/personal-access-tokens/new: owner usehomemade, repository homebrew-tap only, Contents read and write. Until it exists, CI skips the cask bump. I can push the first cask by hand.
- I briefly set `RELEASES_ENABLED` to true and pushed, then canceled that run before it tagged and set it back to false. A v1.0.0 tag on the old history would have undone a rewrite.

Where the secrets host appears: never in the current files. In history it is in 4 commits: 000bfe5 and 2e30fea (install.sh, 23 Nov), and 51abf4f to faab6a7 (`scripts/release/ci-cert.sh`, added and removed today), together with an internal Keychain item name. `refs/pull/1/head` (PR #1) reaches the 23 Nov commits. origin/hm-1368 is already gone.

### 2026-11-25 12:58 UTC (agent)

History reset, as the owner chose (B, one initial commit):
- Old repo: renamed to `usehomemade/needs-you-old-history`, still **private**. Our token lacks the `delete_repo` scope, so the owner can delete it later. A local mirror is at `~/Projects/needs-you-old-history.git`, including the local-only branches.
- OLD main = 2c114ec5929946e74f6794cf8afd9cb2211f2163.
- New `usehomemade/needs-you` (private for now): one parentless commit, **64a46e7** "Needs You: initial public release". Its tree is old main plus a one-line fix (an expression in SpeechText that Swift 6.3 on CI could not type-check). gitleaks is clean, and grep finds no internal host, Keychain item, handle, artifacts domain, another app or name.
- To move other branches: `git rebase --onto 64a46e7 2c114ec <branch>`.
- The 6 secrets come from the team's secret store, and the variables are set (`RELEASES_ENABLED=false` for now). Dry run: https://github.com/usehomemade/needs-you/actions/runs/45618920380

### 2026-11-25 13:13 UTC (agent)

**Live and public.** Needs You 1.0.0: https://github.com/usehomemade/needs-you/releases/tag/v1.0.0

Proof:
- Repo is public with exactly 1 commit. Anonymous `api.github.com/repos/usehomemade/needs-you/commits` returns `1 ['64a46e7']`.
- Release run: https://github.com/usehomemade/needs-you/actions/runs/45619873115 (green). Signed as Developer ID Application (34LRG4TQRP), notarization Accepted for the app and the DMG, both stapled.
- DMG downloaded anonymously and marked quarantined: `spctl -a -t open` says "accepted, source=Notarized Developer ID". The app copied from it: `spctl -a -vv` says accepted, Notarized Developer ID, hardened runtime.
- Appcast: https://github.com/usehomemade/needs-you/releases/latest/download/appcast.xml returns HTTP 200 (1.0.0, build 1, EdDSA-signed zip). The released app's `--update-check` reads it: `{"status":"current","detail":"You're up to date!"}`.
- Homebrew: the cask is in `usehomemade/homebrew-tap` (`Casks/needs-you.rb`, commit 24ded1a). `brew install --cask --appdir=<temp> usehomemade/tap/needs-you` printed "needs-you was successfully installed!". The installed app passes Gatekeeper. Then `brew uninstall` ran, and the owner's app and CLI were untouched.
- The owner's app was reinstalled from main after `needs-you status` showed it idle (queued 0, Ready). `~/.claude/needs-you.md` now reads "ask <name> out loud".
- `RELEASES_ENABLED=true`, `HOMEBREW_TAP=usehomemade/homebrew-tap`. Every push to main is now a release.

Download: https://github.com/usehomemade/needs-you/releases/latest/download/NeedsYou-1.0.0.dmg
Brew: `brew install --cask usehomemade/tap/needs-you`

Follow-up in HM-1373: the tap token for automatic cask bumps, and deleting the private `needs-you-old-history` repo.
<!-- SECTION:DESCRIPTION:END -->
