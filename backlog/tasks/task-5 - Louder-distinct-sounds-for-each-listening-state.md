---
id: TASK-5
title: Louder, distinct sounds for each listening state
status: Done
assignee: []
created_date: '2026-11-23T17:28:47Z'
updated_date: '2026-11-26T20:07:56Z'
labels:
  - hm-1315
dependencies: []
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1315
Related: TASK-4 (HM-1314), TASK-6 (HM-1316)

The owner 23 Nov (by voice): "make the listening and pause and these kind of sounds or sound effects more prominent so I can easily hear."

One short, clearly different sound per state, audible across a room: listening starts (wake word heard), paused but still listening (subtle), listening ended / got it, sending (start of the 2 s countdown), sent, cancelled, no answer / gave up. Rising tones for start, falling for end. Generated in the app (no licensed assets), with their own volume setting (default loud) and a "Play all sounds" preview in Settings.

## History

### 2026-11-23 18:32 UTC (agent)

Done. Installed (9ac6611, plus a new "stopped" cue in 0bdc054). On 23 Nov the owner heard `needs-you play-sounds` live and said they were loud and distinct enough. Settings has a separate Sound Volume and a Play All Sounds button.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Superseded by the Rosewood sound set (TASK-24). The old sounds remain as "Classic" in Settings, Voice, Sounds. No repeating tick (TASK-11). Rosewood WAVs are in Resources/Sounds/Rosewood since v1.0.0.
<!-- SECTION:NOTES:END -->
