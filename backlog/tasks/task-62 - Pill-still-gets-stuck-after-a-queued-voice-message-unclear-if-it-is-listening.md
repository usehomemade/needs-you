---
id: TASK-62
title: Pill still gets stuck after a queued voice message; unclear if it is listening
status: Done
assignee: []
created_date: '2026-11-26T14:53:07Z'
updated_date: '2026-11-26T20:16:38Z'
labels:
  - hm-1414
dependencies: []
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1414

Owner, 26 Nov 2026 (by voice), on 1.4.0: after speaking a message that got queued, the top bar got stuck, and he could not tell whether it was still listening. Every queue path must finish the pill state, and the pill must always show clearly whether it is listening.

## History

### 2026-11-26 15:06 UTC (agent)

Fixed in commit d0c0485 on main (not pushed yet). Installed as a local build. 164 tests pass.

### 2026-11-26 15:23 UTC (agent)

Released in v1.5.0 (run 45847016132) and installed.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Done. Fix d0c0485 in v1.5.0, installed v1.6.0. Since then audio.log shows no stuck pill: queued sends (16:20 UTC) and every later state end in "pill: done -> idle", the last at 20:10 UTC. PillRulesTests passes.
<!-- SECTION:NOTES:END -->
