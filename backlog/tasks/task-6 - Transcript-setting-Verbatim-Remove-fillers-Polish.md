---
id: TASK-6
title: Transcript setting (Verbatim, Remove fillers, Polish)
status: Done
assignee: []
created_date: '2026-11-23T17:29:06Z'
labels:
  - hm-1316
dependencies: []
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1316
Related: TASK-4 (HM-1314), TASK-5 (HM-1315)

The owner 23 Nov: a "Transcript" setting with three modes, for both `needs-you ask/say` transcripts and Hey Claude sends.

* Verbatim: exactly what was heard.
* Remove fillers (default): drop uh/um/ah/ee/ähm, stutters and repeated words ("I- I think" becomes "I think"), and clean up a false start only when he restarts the same phrase. Every other word stays as said; the meaning never changes. Rule-based.
* Polish: rewritten into clear English with the same meaning, by Apple's on-device model. Settings warns that this can change nuance.

The Sending… panel and History always show the cleaned text; History keeps the original behind a disclosure. Test on his real transcripts from today.

## History

### 2026-11-23 18:32 UTC (agent)

Done. Installed (9ac6611) and checked with `needs-you clean-test` on 23 Nov:
- Verbatim leaves the text unchanged.
- Remove fillers (the default) only deletes: "Uh, so, um, I I think we should, uh, deploy it to to staging" becomes "So I think we should deploy it to staging". The live asks returned `transcript_verbatim` alongside it.
- Polish gave the same result as Remove fillers, because Apple Intelligence is not available on this Mac. Settings says so in orange.
<!-- SECTION:DESCRIPTION:END -->
