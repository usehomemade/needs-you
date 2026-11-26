---
id: TASK-49
title: >-
  Connect the Claude app and ChatGPT in Settings > Agents (install the MCP
  server on click, or a guide)
status: Done
assignee: []
created_date: '2026-11-26T08:42:33Z'
updated_date: '2026-11-26T20:16:36Z'
labels:
  - hm-1385
dependencies: []
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1385
Related: TASK-45 (HM-1374), TASK-47 (HM-1383)

The owner, 26 Nov ~09:45: add "install on ChatGPT" / "install on Claude app" connectors. Do it automatically on click where possible, otherwise show a short guide.

Once connected, those apps' chats can answer out loud (TASK-47 (HM-1383) leaves the voice line off for apps without Needs You).

## History

### 2026-11-26 08:44 UTC (agent)

Built on branch `hm-1383-router` (same worktree), 109/109 tests pass, not installed yet.

* Settings > Agents > Reach by Voice: new **Claude app** switch. On click it adds only our `mcpServers.needs-you` entry to claude_desktop_config.json (backup kept; turning it off restores the file), then shows "Restart Claude".
* **ChatGPT app** row with a How… popover: Codex tasks in the ChatGPT app use the Codex switch; plain ChatGPT chats can't take a local MCP server (internet connectors only), so they stay type-only.
* Every row now shows the app's own icon.
* Claude app's MCP server never registers as a chat (one server for the whole app).

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. Released in v1.1.0, installed app is v1.6.0. MCPServerEditTests passes.
<!-- SECTION:NOTES:END -->
