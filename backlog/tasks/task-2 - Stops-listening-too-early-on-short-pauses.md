---
id: TASK-2
title: Stops listening too early on short pauses
status: Done
assignee: []
created_date: '2026-11-23T16:54:41Z'
labels:
  - hm-1312
dependencies: []
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1312

The owner 23 Nov, live: the end-of-speech silence is too short. It cut him off mid-sentence ('I'm kind of afraid to stop between my words'), and a first 'Ähm' was taken as the full answer. Wait much longer for pauses, ignore filler-only answers, and give him a clear way to finish.

## History

### 2026-11-23 16:57 UTC (agent)

Fixed and installed (26f680f, same signing).
- The 30 s wait only runs until he starts talking. After that his turn ends on a 3 s pause (a setting), on "done" / "that's it" / "over" (stripped from the transcript), with Stop, or after 2 min.
- Filler-only turns ("ähm", "uh", "hmm") keep it listening.
- A soft Pop sound plays when it stops listening, and the panel shows "Got it". The panel also says "Say "done" when you're finished".

Proof: generated speech run through the real listening path in real time (new `--vad-file` test hook):
- 2.5 s and 1.5 s mid-answer pauses: the full three-sentence answer came back.
- "Hmm." then 4.5 s quiet then "Yes, go ahead and promote it.": the transcript was only the real answer.
- "Ship it to staging first. That's it.": it ended early (4.8 s total) with "Ship it to staging first."

Not tested: the 2-minute cap.
<!-- SECTION:DESCRIPTION:END -->
