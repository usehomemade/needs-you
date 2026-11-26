---
id: TASK-70
title: >-
  Voice commands the on-device model misreads ("out for three hours, send
  everything to voicemail" played voicemails)
status: Done
assignee: []
created_date: '2026-11-26T17:01:58Z'
updated_date: '2026-11-26T20:16:39Z'
labels:
  - hm-1433
dependencies: []
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1433

Owner, 26 Nov 2026: "Hey Mac, I'm gonna be out of home for I think three hours so let everything go to voicemail" was read as "play voicemails" instead of "away" (voicemail mode). Fix how the on-device model reads in-app commands in general (away, back, do not disturb, good night, voicemails, summary, list chats, new chat, send), including durations ("for three hours"), then release.

Log:
2026-11-26 17:00:45 +0000 model: away 0 “” in 3958 ms
2026-11-26 17:00:46 +0000 model: away 0 “” in 4237 ms
2026-11-26 17:00:47 +0000 model: away 0 “” in 4876 ms
2026-11-26 17:00:49 +0000 model: away 2 “needs-you” in 5819 ms
2026-11-26 17:00:50 +0000 model: away 0 “” in 6044 ms
2026-11-26 17:00:52 +0000 model: voicemails 2 “needs-you” in 6824 ms
2026-11-26 17:00:53 +0000 model: voicemails 2 “needs-you” in 5562 ms
2026-11-26 17:00:53 +0000 route: model: voicemails 2; ignored name “needs-you” (not his words); meaning 4 0.32, 2 0.31, 7 0.30; learned 2 0.28; model: voicemails

## History

### 2026-11-26 18:19 UTC (agent)

Status check (two independent checks): The fix is not shipped. It exists only as uncommitted edits in the needs-you repo (ModelRouter, VoiceIntent, DoNotDisturb, VoiceCommands). No commit mentions HM-1433 and the latest tag is v1.5.0. Left to do: finish the edits, add a test that "out for three hours, let everything go to voicemail" routes to away with a 180 minute duration, commit and push, cut a release after v1.5.0, then check the released app reads it as away. Moved to Todo because no running worker owns it.

### 2026-11-26 18:41 UTC (agent)

Released in v1.6.0 (run 45876703935) and installed.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Done. 147bc0e is in v1.6.0, installed. Dry runs today: "out for three hours, send everything to voicemail" -> away 180 min; "do not disturb me until 9 pm" -> away until 9 pm; "play my voicemails" -> play voicemails. Real use: a spoken "I'm back" turned do not disturb off at 19:08 UTC. AwayTimeTests passes. Side finding: the dry run "Hey Mac, I'm back" hung over 10 minutes and had to be killed; the live command works.
<!-- SECTION:NOTES:END -->
