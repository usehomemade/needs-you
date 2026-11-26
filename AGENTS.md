# Needs You: usage notes for agents

The app installs and updates its agent instructions itself (HM-1355): `~/.claude/needs-you.md`, imported from `~/.claude/CLAUDE.md` with `@needs-you.md`. The text is `AgentInstructions.defaultText(name:)` in `Sources/NeedsYouShared/AgentInstructions.swift`, with the user's name from Settings → General ("the user" when none is set).

Working on this repo:
- Commit subjects decide the next release version (see README → Releases): `feat:` for features, `fix:` for fixes, `feat!:` for breaking changes, `[skip release]` to skip one.
- Never run `needs-you wake-test` against real chats; tests use an armed throwaway herdr pane only.
- Installing a build is pre-approved (the owner, 26 Nov 2026): run `SKIP_MODELS=1 scripts/install.sh` from the repo or worktree whenever you need to test a change in the real app. It replaces ~/Applications/Needs You.app and restarts it; no need to ask first.
- This repo is public: tests, comments, docs and commit messages use made-up chat titles, folders and names, never the owner's real ones.
- Signing: local builds (`scripts/install.sh`) and release builds (GitHub Actions) both sign with the Needs You Developer ID certificate, SHA-1 `F5F5EF29141AD0A613C1B7AAEB2DE13D432068A2` (team 34LRG4TQRP). Never sign with an Apple Development certificate: macOS ties Accessibility, Microphone and Speech Recognition grants to the certificate, so a different one resets them. The certificate and its password are the `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` secrets (GitHub Actions secrets and the team's secret store); import the p12 into the login keychain with `-T /usr/bin/codesign` on a new Mac.
