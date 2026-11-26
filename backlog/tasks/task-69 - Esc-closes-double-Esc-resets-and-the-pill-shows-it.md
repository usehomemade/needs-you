---
id: TASK-69
title: Esc closes, double Esc resets, and the pill shows it
status: In Review
assignee: []
created_date: '2026-11-26T16:39:49Z'
labels:
  - hm-1429
dependencies: []
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1429

Owner, 26 Nov 2026: Esc closes and double Esc resets. The listening pill should show this hint (next to "Say done when you're finished").

## History

### 2026-11-26 16:56 UTC (agent)

Done in commit e12a5eb (local main, not pushed yet). Installed locally; 186 tests pass.

### 2026-11-26 18:19 UTC (agent)

Status check (two independent checks): The feature is built and committed, but only on local main of the needs-you repo. Nothing is pushed or released. The commit is 88d571c (the e12a5eb in the earlier comment no longer exists). Left to do: push 88d571c and the 2 commits before it to origin/main without the uncommitted local edits, let the release run, then check that the pill shows "esc close  esc x2 reset" and that Esc and double Esc behave as described.

### 2026-11-26 18:41 UTC (agent)

Released in v1.6.0 (run 45876703935) and installed.
<!-- SECTION:DESCRIPTION:END -->
