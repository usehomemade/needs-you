---
id: TASK-21
title: Listening closes right after waking ("only other voices")
status: Done
assignee: []
created_date: '2026-11-24T17:18:10Z'
updated_date: '2026-11-26T20:07:59Z'
labels:
  - hm-1345
dependencies: []
ordinal: 21000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1345
Related: TASK-19 (HM-1332)

The owner, 24 Nov: after it wakes up, it sometimes closes itself again.

Debug log: "command ended: only other voices for the last seconds" about 2 s after the wake, with his voice scoring 0.36-0.46 on the Brio webcam mic (lid closed). The own-voice check ends his turn while he is still talking. Related: TASK-19 (HM-1332) (Training picks a bar that is too strict, voiceprint is mic-specific).

## History

### 2026-11-24 17:57 UTC (agent)

The fix is on main (c16c89f) and installed. The owner still needs to test it live.

**Cause, confirmed:** near-silent windows counted as "other voices". On the live log the wake was recognized only after he had paused (quiet=1.1 s). One second later the 3 s window was mostly silence (iso level -140 dB). CAM++ scores silence at 0.06-0.07, and plain room noise at 0.17, both under otherBelow 0.28. One such check ended the turn 1 s later.

**Changes**
- A speaker check counts only when its 3 s window holds at least 1 s of Silero speech and its loud frames are above -55 dBFS. Otherwise it is skipped and logged as "speaker check skipped: too little speech".
- "Only other voices" now needs two speech-bearing checks in a row that are not his voice.
- It never fires in the first 3 s after the wake.
- Also fixed in this change: a skipped check left the checker locked, which would have stopped all later checks.

**Offline check:** I mixed a wake clip with 1.3 s of silence and then his speech. The checks are now skipped during the pause and the turn does not end as "other voices". The real voice checks still run every second after that.

**Open:** the old rule "nothing said within 2.5 s after the wake ends the command" is unchanged. Because the chime now comes about 1 s sooner, that 2.5 s starts earlier. If he gets cut off after a long pause following the chime, that rule is the one to tune next.

### 2026-11-24 18:17 UTC (agent)

Installed (needs-you 2ff5eb3). Moved to Todo + Needs owner: waiting on the owner's live test when he's home.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: The fix is in v1.0.0 and later. The live wake debug log has "command ended: only other voices" only on 24 Nov 17:13 to 17:15 UTC, before the fix. None since, over 50+ live commands on 25 and 26 Nov (only in silent bench runs). Skipped checks log as "speaker check skipped: too little speech".
<!-- SECTION:NOTES:END -->
