---
id: TASK-26
title: >-
  Replace the top-right listening indicator with a notch "island" (artifact
  first)
status: Done
assignee: []
created_date: '2026-11-24T19:32:35Z'
updated_date: '2026-11-26T20:08:00Z'
labels:
  - hm-1350
dependencies: []
ordinal: 26000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1350
Related: TASK-33 (HM-1357), TASK-27 (HM-1351), TASK-37 (HM-1363)

The owner (voice, 24 Nov 20:33): the top-right listening indicator is "really really ugly". He wants the status to live in the notch area at the top of the screen, like an island: pitch black with nice animations. Research references first and show an artifact before building.

## History

### 2026-11-24 19:38 UTC (agent)

Design artifact: [private preview link removed] (v3)

It shows the notch island in every state (idle, wake heard, listening, thinking, Claude speaking, done, error), animated with springs, plus an external-monitor pill and a Reduce Motion variant. Buttons step through the states and autoplay loops them. Notes under it cover sizes, timings and sources (Mobbin: Granola, Cursor, Instagram, Tolan, Character AI, DeepSeek, Manus; HIG Live Activities, Motion, Accessibility; Boring Notch source for notch measuring). The app is unchanged. Waiting on the owner's comments on the design.

### 2026-11-24 19:41 UTC (agent)

The owner (voice, 24 Nov): loves the design, keep the morphing animations as they are. Wants a setting to switch between the MacBook notch and external monitor styles. Build started.

### 2026-11-24 20:24 UTC (agent)

The island is built, merged to main (dbb9b70) and installed. Needs You was quit and reopened at 21:23.

**What's in it**
- One pure black shape at the top centre of the screen with the mouse. It's a borderless panel that never takes focus and lets clicks through. Its size and corners spring between states and its content cross-fades, with the timings from the artifact: grow 380/26, shrink 500/45, content in after 90 ms over 180 ms with a 4 px blur clearing, out over 120 ms. Notch style has the curved flare where it meets the top edge.
- States are wired to the real app:
  - wake heard (ears with the ripple)
  - listening (timer, "Say done when you're finished" or the voice-learning line, 26 bars from the live mic level)
  - thinking (while transcribing, and up to 15 s while the agent works)
  - Claude speaking (orange, chat name from the agent's folder, the current sentence, bars from the voice level)
  - done (the check draws in, then it folds back)
  - error ("Can't hear you" or "Not sent", plus one line on the fix, with the shake)
- It replaces the top-right live panel, the Hey Claude "Listening…" panel and the "Not sent" flash. The "To <chat>" countdown with Cancel stays, because it needs clicks.
- Reduce Motion: a plain 220 ms ease-out with no overshoot. The ripple, shake, dots and shimmer stop, and the bars step about 6 times a second.
- Settings → Voice → Island style: Automatic (default), MacBook notch, External monitor. The notch is measured from the screen's auxiliaryTopLeft/RightArea and safeAreaInsets.top. The pill sits 6 pt under the menu bar.
- Test hook: `"Needs You.app/Contents/MacOS/NeedsYou" --island-demo [--island-style notch|external] [--idle-after s]` runs through every state with fake levels and no audio. The style flag isn't saved.

**CPU (release build)**
- Island idle: 0.0 %, about 19 MB. The panel is ordered out, so no views are running.
- Expanded (listening or speaking bars): about 9–13 % of one core. Thinking: about 9 %. Ears, done and error: 1–6 %.
- The installed app idles at about 10 % with Hey Claude listening. That cost comes from the wake listener, not the island.

**Frames from the demo** (only an external monitor is connected, so "MacBook notch" was forced on it. On a real notch screen, idle merges into the hardware notch instead of fading out.)

MacBook notch style, top to bottom: wake, listening ×2, thinking, Claude speaking, done, error, idle:
[screenshot removed]

External monitor pill:
[screenshot removed]

Next for the owner: say "Hey Claude" and watch the island grow at the top of this screen. On the MacBook screen, try it once in Automatic.

### 2026-11-25 00:24 UTC (agent)

Done (two independent checks agreed): the status island is built and merged in the needs-you repo. Commit 9650c93 "Status island at the top of the screen replaces the corner panels (HM-1350)" is on main via merge dbb9b70, and origin/main (237de05) contains it. Sources/NeedsYou/Island.swift measures the notch, the --island-demo hook and the Island style setting are in, and the installed app (built Nov 24 22:58) is running it. Later work (HM-1351 to HM-1357) builds on top of it.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Island.swift ships in v1.0.0 and later (IslandLayoutTests). audio.log on 26 Nov logs live pill states (idle, wake, listening, thinking, speaking). Pill bugs found later are their own tasks.
<!-- SECTION:NOTES:END -->
