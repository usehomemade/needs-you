---
id: TASK-22
title: Big live subtitles for both sides, plus a Siri-like speaking effect
status: To Do
assignee: []
created_date: '2026-11-24T17:18:12Z'
labels:
  - hm-1346
  - needs-owner
dependencies: []
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1346

The owner, 24 Nov: while he talks, show a live transcription as big, obvious subtitles on screen, not a small top-right corner thing. Subtitle what Claude says back the same way. Whenever either side is talking, show a Siri-like effect on screen so it is obvious that it is speech time.

## History

### 2026-11-24 17:20 UTC (agent)

Design mockup for the owner's OK, based on HIG (Siri, accessibility, materials via sosumi) and Mobbin captions/voice-assistant screens: [private preview link removed]. The build agent keeps the plumbing going and waits for sign-off before installing.

### 2026-11-24 17:36 UTC (agent)

Subtitles and edge glow are built: the approved look, with the glow now drawn by a smooth Metal shader. The code is on branch `worktree-agent-a50f633740e8c02e2` (4 commits on top of main, fast-forward). It is not installed yet. Merge and install come next, from the main checkout.

What it does:
- **Subtitles:** big text at the bottom centre of the screen with the mouse, about 46 pt on a 27" screen, two lines at most, newest words kept, on a blurred dark backing.
  - Your words are white. The newest word stays dimmer until it is recognised. The text updates about every 0.8 s while you talk, then switches to the final transcript.
  - Claude's words are peach and move on sentence by sentence as the voice plays.
- **Glow:** a soft glow along all screen edges, brightest at the bottom. It is white-blue while you talk and orange while Claude talks.
  - It is a GPU shader running at the display refresh rate, with no hard edge and no seam. Its brightness follows the voice level and changes smoothly.
  - It fades in on "Hey Claude" and out about 1 s after speech ends. With Reduce Motion on it stays still and only fades.
- It never takes clicks or focus. Settings → Voice → "Subtitles on Screen" turns it off (on by default).
- To see it without audio: `needs-you voice-test --title overlay-demo`.

CPU (release build, 6K screen at 120 Hz):
- While someone talks: the app uses 4–6 %, and WindowServer uses about 6 % more than its baseline.
- While nobody talks: 0.0 %. The window is hidden and the display link is paused.

You talking:
[screenshot removed]

Claude talking:
[screenshot removed]

### 2026-11-24 18:06 UTC (agent)

Installed (needs-you 2ff5eb3). Recording of the installed glow and subtitles: [private preview link removed]

### 2026-11-24 18:17 UTC (agent)

Moved to Todo + Needs owner: installed, waiting on the owner's live test when he's home.

### 2026-11-25 00:24 UTC (agent)

Waiting on the owner: say "Hey Claude" to the installed Needs You app (or run `needs-you voice-test --title overlay-demo`), check the big subtitles and the edge glow for both sides, then confirm or list what to change. The subtitles and glow are built, merged to needs-you main (2ff5eb3) and installed, and only your live test is open.
<!-- SECTION:DESCRIPTION:END -->
