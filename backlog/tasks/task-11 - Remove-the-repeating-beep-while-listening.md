---
id: TASK-11
title: Remove the repeating beep while listening
status: Done
assignee: []
created_date: '2026-11-23T20:09:16Z'
updated_date: '2026-11-26T20:07:57Z'
labels:
  - hm-1324
dependencies: []
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1324
Related: TASK-15 (HM-1328)

The owner (voice, 23 Nov): the repeating beep that plays while it listens and he is silent is horrible. Remove it; keep only the start/stop sounds.

## History

### 2026-11-23 20:09 UTC (agent)

Handed to the Needs You agent (same one working HM-1314).

### 2026-11-23 20:16 UTC (agent)

Removed in e73d38c, installed. The beep was the "pause, still listening" tick: it played after every 1.5 s pause, during `ask` answers and Hey Claude commands. The sound is gone from the app; the start, stop, sent and cancelled sounds stay.

Proof: no part of the installed build plays that tick any more. The owner hears the result in the next voice test (HM-1328).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still true: no pause tick in Sounds.swift on origin/main, and none in the Rosewood set.
<!-- SECTION:NOTES:END -->
