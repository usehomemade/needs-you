---
id: TASK-31
title: Install and auto-update its own CLAUDE.md section (user-editable)
status: To Do
assignee: []
created_date: '2026-11-24T21:40:10Z'
labels:
  - hm-1355
  - needs-owner
dependencies: []
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1355
Related: TASK-28 (HM-1352)

The owner, 24 Nov: the app should install its own part of CLAUDE.md automatically and update it whenever that part changes. The .md file(s) must stay editable by him.

Trigger: his global CLAUDE.md still described the old "asks twice, then artifact" behaviour after TASK-28 (HM-1352) changed it.

## History

### 2026-11-24 22:00 UTC (agent)

Shipped on main (3d9e900), installed and running.

- On launch the app wrote ~/.claude/needs-you.md and appended `@needs-you.md` to ~/.claude/CLAUDE.md between `<!-- needs-you:begin -->` / `<!-- needs-you:end -->` (backup of the old file: ~/.claude/CLAUDE.md.needs-you-backup). Claude Code docs confirm `@path` imports resolve relative to the importing file and load without a prompt in user-level CLAUDE.md.
- Text ships in Sources/NeedsYouShared/AgentInstructions.swift (asks once, voicemail status, DND, Escape, turn shortcut, voice messages). Unedited file updates itself; an edited file is kept, the new default goes to needs-you.default.md and Settings → Agents shows Show Diff / Keep Mine / Use New Default. Edit… and a toggle to turn it off are there too. 7 unit tests.
- Screenshots: [private preview link removed]

Needs owner: your CLAUDE.md still has the old hand-written "## Needs You: ask <name> out loud" section (old ask-twice text), so agents currently read both. Open Settings → Agents → Review and Remove… and click Remove Section. Nothing outside the marked block was touched.

### 2026-11-25 00:23 UTC (agent)

Waiting on the owner: Open Needs You Settings, go to Agents, click Review and Remove, then click Remove Section to delete the old hand-written section from ~/.claude/CLAUDE.md. The app now installs its own instructions file and runs, but the old section still gives agents the outdated "ask twice, then artifact" text.
<!-- SECTION:DESCRIPTION:END -->
