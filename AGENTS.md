# Needs You: usage notes for agents

The app installs and updates its agent instructions itself (HM-1355): `~/.claude/needs-you.md`, imported from `~/.claude/CLAUDE.md` with `@needs-you.md`. The text is `AgentInstructions.defaultText(name:)` in `Sources/NeedsYouShared/AgentInstructions.swift`, with the user's name from Settings → General ("the user" when none is set).

## Issue tracking: Backlog.md (hard rule)

This project tracks all work in Backlog.md, in the `backlog/` folder of this repo. Never use Linear for Needs You.

- Every new bug, feature or task becomes a Backlog task right away.
- A task's status always matches reality:
  - Backlog: not planned, nobody on it.
  - To Do: planned next, or waiting on the owner (label `needs-owner`).
  - In Progress: someone is working on it right now.
  - In Review: released or in a PR, waiting for proof.
  - Done: released and verified, with the proof (version, commit, check) in the task.
- Commit messages reference the task id, for example `fix: island stays stuck (TASK-12)`.
- Tasks are public. The public-repo rule below applies to them too: no real names, chat titles, folders, hosts or secrets.
- Old tasks keep their old id as a label (`hm-1427`) and as an "Old id:" line, so older commit messages still lead to them.

Commands:
- `backlog task list --plain` lists tasks (`-s "In Progress"` filters by status).
- `backlog task view TASK-12 --plain` shows one task.
- `backlog task create "Title" -d "What and why" -s "To Do" -l bug` creates one.
- `backlog task edit TASK-12 -s "In Review" --append-notes "Released in v1.7.0"` updates one.
- `backlog board` shows the board.

Working on this repo:
- Commit subjects decide the next release version (see README → Releases): `feat:` for features, `fix:` for fixes, `feat!:` for breaking changes, `[skip release]` to skip one.
- Never run `needs-you wake-test` against real chats; tests use an armed throwaway herdr pane only.
- Installing a build is pre-approved (the owner, 26 Nov 2026): run `SKIP_MODELS=1 scripts/install.sh` from the repo or worktree whenever you need to test a change in the real app. It replaces ~/Applications/Needs You.app and restarts it; no need to ask first.
- This repo is public: tests, comments, docs and commit messages use made-up chat titles, folders and names, never the owner's real ones.
- Signing: local builds (`scripts/install.sh`) and release builds (GitHub Actions) both sign with the Needs You Developer ID certificate, SHA-1 `F5F5EF29141AD0A613C1B7AAEB2DE13D432068A2` (team 34LRG4TQRP). Never sign with an Apple Development certificate: macOS ties Accessibility, Microphone and Speech Recognition grants to the certificate, so a different one resets them. The certificate and its password are the `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` secrets (GitHub Actions secrets and the team's secret store); import the p12 into the login keychain with `-T /usr/bin/codesign` on a new Mac.
