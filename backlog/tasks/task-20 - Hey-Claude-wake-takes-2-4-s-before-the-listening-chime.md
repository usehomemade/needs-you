---
id: TASK-20
title: '"Hey Claude" wake takes 2-4 s before the listening chime'
status: To Do
assignee: []
created_date: '2026-11-24T17:18:08Z'
labels:
  - hm-1344
  - needs-owner
dependencies: []
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1344

The owner, 24 Nov: the "started listening" chime plays 2-4 s after he says "Hey Claude".

Debug log (`debugWake`) shows about 2 s from speech onset to the first partial "Hey Cl" from the Apple analyzer, then the voice check, then the chime. Goal: chime under 1 s after he finishes "Hey Claude".

## History

### 2026-11-24 17:57 UTC (agent)

The fix is on main (c16c89f) and installed. The owner still needs to test it live.

**Cause:** the voice check was not the slow part. It takes 10-20 ms. The delay came from Apple's analyzer: in normal mode it gave "Hey Claude" 1.6-2.5 s after the phrase ended. On the live log it often came only after the 1.4 s pause had already closed the segment (`mode=pending`).

**Changes**
- The analyzer runs with `.fastResults` (setting `wakeFastResults`, on by default).
- Once the voice is learned, a "Hey Cl…" partial wakes it. The voice check still has to pass, and if it fails the next text checks again.
- After any "Hey" partial, Whisper re-reads the audio back to back for 2 s. This catches "Hey Mom" / "Hey bro" mishearings over music or a game sooner.
- New hook: `needs-you voice-test <wav>... --title wake-latency[:fast|:slow][:cmd]`. It plays clips in real time, makes no sound and sends nothing.
- The debug log now has milliseconds.

**Measured on the 35 eval wake clips (Brio):** time from the end of the phrase to the chime trigger, median

| | before | after |
|---|---|---|
| quiet | 1.69 s (max 2.54) | 0.59 s (max 1.30) |
| music + game | 2.05 s (max 3.75) | music 0.50 s, game 1.27 s (max 1.95) |
| catch | 29/35 | 29/35 |
| false wakes | – | 0/61 clips without the wake word |

### 2026-11-24 18:17 UTC (agent)

Installed (needs-you 2ff5eb3). Moved to Todo + Needs owner: waiting on the owner's live test when he's home.
<!-- SECTION:DESCRIPTION:END -->
