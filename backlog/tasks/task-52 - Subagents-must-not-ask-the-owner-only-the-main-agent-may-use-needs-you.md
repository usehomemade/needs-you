---
id: TASK-52
title: Subagents must not ask the owner (only the main agent may use needs-you)
status: Done
assignee: []
created_date: '2026-11-26T10:42:22Z'
updated_date: '2026-11-26T20:16:37Z'
labels:
  - hm-1395
dependencies: []
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1395
Related: TASK-45 (HM-1374), TASK-47 (HM-1383)

The owner, 26 Nov: "subagents should NOT use needs-you. only the main agent should be able to ask me stuff. can we enforce this using code universally for any coding agent harness? or is it a prompt thing?"

Answer: both. Claude Code can be enforced in code: its PreToolUse hook payload carries agent_id/agent_type for subagent tool calls, so a hook on mcp__needs-you_\_\* and on Bash "needs-you ask|say" can deny them. Other harnesses (Codex, Cursor) give no subagent signal: prompt rule in needs-you.md. Waiting for the owner's go.

## History

### 2026-11-26 10:50 UTC (agent)

The owner: "if we can't enforce in code by default, just use a rule in needs-you.md." Done both (branch hm-1383-router, installed locally):
* Claude Code, in code: a PreToolUse hook (matcher mcp__needs-you__.*|Bash) denies needs-you ask/say/done from a subagent (agent_id in the hook input) with "put the question in your report; the main agent asks it". status stays allowed. Hooks installed by older versions get PreToolUse on next launch (refreshClaudeHooks). 4 unit tests. Not yet seen deny a real subagent.
* Everyone else: rule in needs-you.md and the MCP server's instructions.

### 2026-11-26 10:53 UTC (agent)

Correction (the owner: "I told you not to do it in code for Claude Code either"): the PreToolUse hook is removed again, and taken out of ~/.claude/settings.json on launch. Only the rule remains: needs-you.md and the MCP server instructions.

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. The rule is in AgentInstructions.swift on origin/main and in the installed instructions file; AgentInstructionsTests passes.
<!-- SECTION:NOTES:END -->
