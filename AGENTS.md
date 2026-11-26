# Needs You: usage notes for agents

The app installs and updates its agent instructions itself (HM-1355): `~/.claude/needs-you.md`, imported from `~/.claude/CLAUDE.md` with `@needs-you.md`. The text is `AgentInstructions.defaultText(name:)` in `Sources/NeedsYouShared/AgentInstructions.swift`, with the user's name from Settings → General ("the user" when none is set).

Working on this repo:
- Commit subjects decide the next release version (see README → Releases): `feat:` for features, `fix:` for fixes, `feat!:` for breaking changes, `[skip release]` to skip one.
- Never run `needs-you wake-test` against real chats; tests use an armed throwaway herdr pane only.
- Installing a build is pre-approved (the owner, 26 Nov 2026): run `SKIP_MODELS=1 scripts/install.sh` from the repo or worktree whenever you need to test a change in the real app. It replaces ~/Applications/Needs You.app and restarts it; no need to ask first.
