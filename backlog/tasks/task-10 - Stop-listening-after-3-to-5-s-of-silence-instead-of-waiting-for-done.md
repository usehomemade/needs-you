---
id: TASK-10
title: Stop listening after 3 to 5 s of silence instead of waiting for done
status: Done
assignee: []
created_date: '2026-11-23T20:09:14Z'
updated_date: '2026-11-26T20:07:57Z'
labels:
  - hm-1323
dependencies: []
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1323

The owner (voice, 23 Nov): the app keeps listening until he says done; if he says nothing for 3 to 5 seconds it should stop listening.

## History

### 2026-11-23 20:09 UTC (agent)

Handed to the Needs You agent (same one working HM-1314).

### 2026-11-23 20:48 UTC (agent)

Done and checked live with the owner (commits 15bf444 and 19a437c, installed).

Listening now ends by itself: Silero VAD tracks his speech and pauses. After a 2 s pause, Smart Turn checks whether he sounds done; 4 s of pause ends the turn either way. Both values are in Settings. Before this, it took a 3 s pause measured by loudness, which never came in a noisy room, so he had to say "done".

- **First live try** used a 0.75 s check and cut him off when he paused on purpose. He picked 2 s and 4 s.
- **Second live try:** a 28 s answer with deliberate pauses came through whole.
- **Offline, his 6 reading clips:** with the 0.75 s check, the turn ended 0.8 s after his last word (old way: 3.0 s) and no "uh" pause was cut off. With 2 s / 4 s it ends about 2 to 2.5 s after his last word.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still works. Silero and Smart Turn in TurnDetection.swift. The owner later set 1.5 s before the check and 3 s at most (judgePause 1.5, endSilence 3). Live wake debug log 26 Nov: turns end on "Smart Turn ... after 1.5 s pause" or "pause reached the limit".
<!-- SECTION:NOTES:END -->
