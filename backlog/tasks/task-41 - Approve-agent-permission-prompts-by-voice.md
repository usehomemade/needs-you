---
id: TASK-41
title: Approve agent permission prompts by voice
status: To Do
assignee: []
created_date: '2026-11-25T12:31:49Z'
updated_date: '2026-11-26T20:16:35Z'
labels:
  - hm-1369
  - needs-owner
dependencies: []
ordinal: 41000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1369
Related: TASK-42 (HM-1370), TASK-34 (HM-1358)

From the TASK-34 (HM-1358) study (idea 1, from handsfree-code `guard.ts:9`). The owner, 25 Nov: "approve perms prompt by voice, YES".

When Claude Code asks for permission (a PermissionRequest/PreToolUse hook), Needs You asks out loud ("bakery wants to run git push. Allow?"), and his yes or no returns allow or deny. A risky-command list decides what's worth asking; DND and no answer fall back to the normal on-screen prompt. Check the existing ~/.claude/hooks/voice-ask.py first.

## History

### 2026-11-25 12:56 UTC (agent)

Merged to main (58e2e61) and installed. It is **off** until you turn it on. I did not touch your settings.json.

**To enable:** Needs You → Settings (⌘,) → Agents → turn on "Approve Permission Prompts by Voice" → read the entry in the sheet → Add Hook. New Claude Code chats pick it up. Turning it off removes the entry.

How it works:
- A `PermissionRequest` hook (`'<app>/Contents/Helpers/needs-you' permission-hook # needs-you:permission-voice`, matcher `Bash|mcp__.*`, timeout 60 s) goes into `~/.claude/settings.json`. The file is copied to `settings.json.needs-you-backup` before every change. The rest of the file keeps its byte-for-byte order and formatting (tested).
- `PermissionGuard` asks only about risky calls: git push/force/delete, hard reset, git clean, `rm -r`, deploys, publishing, DB writes, installs, `curl | sh`, sudo, ssh/scp, secrets, and risky MCP tools. Example line: "website wants to force-push to main. Allow?" (spoken through the HM-1370 cleaner). Every other call returns nothing, so the normal prompt shows.
- Answers: yes/okay/go ahead means allow. No/don't/stop/cancel means deny, and Claude is told you said no. "Always" means allow plus Claude Code's suggested allow rule. Unclear, long or mixed answers fall back to the screen.
- Falls back to the on-screen prompt on: Do Not Disturb, another conversation running (after a 4 s wait), no answer in 12 s, app not running, or the 50 s budget running out. It never allows on its own. If the hook goes away (you answered on screen), the voice stops.
- Log: `permission-hook.log` records project, kind and outcome, never the command.

Tests: 13 unit tests (43 risky commands, 30 safe ones, answer mapping, hook JSON, installer round-trip). `scripts/test-permission-hook.sh` is a silent end-to-end run through the real CLI and socket (muted, no mic, entries removed from history). All 8 cases pass, including allow, deny, always, unclear, no answer, app not running and budget timeout.

Needs owner: enable it in Settings → Agents and try one real prompt (for example, let a chat `git push`).

### 2026-11-25 18:18 UTC (agent)

Waiting on the owner: In a new Claude Code chat, trigger a risky permission prompt (for example, let it ask to `git push`), answer it by voice, and confirm it allowed or denied correctly. The code is on needs-you main and the hook is installed in settings.json, but no real permission prompt has gone through it yet.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Still To Do, waiting on the owner. The permission hook is installed in the agent settings and its code ships in v1.6.0 (PermissionPromptTests, PermissionHookInstallerTests pass). The only hook log entries are the 25 Nov test run; no real permission prompt has gone through it yet. Owner check: let a chat ask to run a risky command (for example git push) and answer it by voice.
<!-- SECTION:NOTES:END -->
