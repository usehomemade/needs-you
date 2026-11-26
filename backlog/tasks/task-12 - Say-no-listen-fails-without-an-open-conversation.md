---
id: TASK-12
title: Say --no-listen fails without an open conversation
status: Done
assignee: []
created_date: '2026-11-23T20:09:18Z'
labels:
  - hm-1325
dependencies: []
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1325

needs-you say --no-listen returns 'No open conversation' when there is none, so agents can't speak a one-way voice reply as CLAUDE.md says. Make it speak standalone.

## History

### 2026-11-23 20:09 UTC (agent)

Handed to the Needs You agent (same one working HM-1314).

### 2026-11-23 20:16 UTC (agent)

Fixed in e73d38c, installed. With no open conversation, `needs-you say "<text>" --no-listen` now waits its turn, speaks and ends.

Proof on the installed build:
- `needs-you say "Standalone test." --no-listen --mute` returns `{"status":"spoken",...}`, exit 0.
- Without `--no-listen` it still asks you to open a conversation with `ask` first.
<!-- SECTION:DESCRIPTION:END -->
