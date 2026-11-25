# Permissions by voice

Needs You can ask you out loud before Claude Code runs a risky command. It is off by default.

## Turn it on

Settings, Agents, Approve Permission Prompts by Voice, then Add Hook. This adds a `PermissionRequest` hook to `~/.claude/settings.json` (matcher `Bash|mcp__.*`, timeout 60 seconds). The file is copied to `settings.json.needs-you-backup` first, the rest of it is left as it was, and turning the switch off removes only this entry.

## What it asks about

The hook runs just before Claude Code would show its own prompt. It only speaks up for calls that are hard to undo:

- git push (force, delete), hard resets, git clean, `rm -r`
- deploys, publishing packages and images, GitHub releases
- database writes through psql, mysql, sqlite3, Redis or Prisma
- installs (brew, global npm, pip, cargo, `curl | sh`)
- sudo, ssh and scp, secret managers
- MCP tools that delete, deploy, merge or send

## How it answers

It asks once, for example "website wants to force-push to main. Allow?", and waits 12 seconds.

- Yes, okay, go ahead: allow.
- No, don't, stop, cancel: deny. Claude is told you said no.
- Always: allow, and add the allow rule Claude Code suggests for the project.

Anything else prints nothing and Claude Code shows its normal prompt: every other call, do not disturb, another conversation running, no answer, an unclear or long answer, or the app not running. It never allows on its own.

Each asked call adds one line (project, kind, outcome, never the command) to `permission-hook.log`.

## Testing

```bash
NEEDS_YOU_HOOK_DRY=1 needs-you permission-hook < input.json   # prints what it would ask
scripts/test-permission-hook.sh                               # runs both silent tests against the installed app
```

The rules live in `Sources/NeedsYouShared/PermissionGuard.swift`.
