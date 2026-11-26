---
id: TASK-59
title: Notch pill stuck after a reply is cut off; pill sometimes a few px off
status: In Review
assignee: []
created_date: '2026-11-26T13:27:12Z'
updated_date: '2026-11-26T20:16:38Z'
labels:
  - hm-1410
dependencies: []
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1410

Owner, 26 Nov 2026: after a voice command was sent to a chat, the notch pill stayed stuck showing the chat's name with an empty status ring, and nothing was spoken any more. Separately, the pill is sometimes a couple of pixels off its position.

Log: a 153-character line was synthesized and played at 13:26:10. Its own stop detector "heard" "Hey Claude!" one second in (most likely its own voice or an echo), then "So," and "Thank." At 13:26:31 wake listening restarted, but the pill never cleared.

## History

### 2026-11-26 13:37 UTC (agent)

Fixed (uncommitted), installed locally. 140 tests, 0 failures.
- Stuck pill and missing beam: AppKit's panel show/hide animation froze partway (the window measured 628×148 instead of 640×150), leaving a stale snapshot on screen; later states (speaking, listening, beam) were drawn but never shown. Fix: animationBehavior = .none on the pill and subtitle panels. Also, setting the same state twice cancelled the fold-back timer; it now keeps it.
- Detector: the cut-off 153-character line was the chat's reply. It actually played to the end. New SpokenEcho guard ignores stop words that come, in order, from the line being spoken.
- Offset: IslandLayout places the panel on whole device pixels, recomputed on every show, state change and screen change. Verified 98/98 samples at 640×150 @ 1184,0.
Not verified: a live voice command end to end; a notch MacBook screen.

### 2026-11-26 14:00 UTC (agent)

Released in v1.3.0 (commit 1e0f80e, run 45833091952) and installed. In Review until checked in real use.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Still In Review. In v1.3.0 and later, installed v1.6.0. audio.log since then shows every speaking and sending state folding back ("pill: done -> idle (done timed out)", last at 20:10 UTC). IslandLayoutTests, SpokenEchoTests pass. Not checked on a notch MacBook screen. Owner check: on a notch screen, see that the pill sits flush with the notch.
<!-- SECTION:NOTES:END -->
