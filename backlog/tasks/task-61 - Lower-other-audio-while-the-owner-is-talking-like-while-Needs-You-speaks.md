---
id: TASK-61
title: Lower other audio while the owner is talking, like while Needs You speaks
status: Done
assignee: []
created_date: '2026-11-26T14:09:57Z'
updated_date: '2026-11-26T20:16:38Z'
labels:
  - hm-1413
dependencies: []
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1413

Owner, 26 Nov 2026 (by voice): music and other playing audio are lowered while Needs You speaks. They should also be lowered while he talks: from the wake word (or turn shortcut) through his command and his answers to follow-ups, then back to normal when listening ends.

## History

### 2026-11-26 14:52 UTC (agent)

Released in v1.4.0 (commit 5e2de17, run 45841828462) and installed. Not verified by ear yet.

### 2026-11-26 18:18 UTC (agent)

Done (two independent checks agreed): Ducking while you talk shipped in Needs You v1.4.0 (also in v1.5.0) with commit 5e2de17 in the needs-you repo. The installed app contains the duck code and its audio log shows 21 "other audio lowered" events (command and answer) with matching "back" events from real use today. No duck errors since the release. Not confirmed by ear yet; reopen if the volume does not drop.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. Still working on v1.6.0: audio.log shows "duck: other audio lowered (command)" and "other audio back" at 19:08 UTC. DuckStateTests passes.
<!-- SECTION:NOTES:END -->
