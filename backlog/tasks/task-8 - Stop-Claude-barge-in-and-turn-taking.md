---
id: TASK-8
title: '"Stop, Claude" barge-in and turn-taking'
status: Done
assignee: []
created_date: '2026-11-23T17:35:04Z'
labels:
  - hm-1318
dependencies: []
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1318
Related: TASK-3 (HM-1313)

The owner 23 Nov (by voice):

* While Needs You speaks, "Stop, Claude" (also "Stop Cloud") stops the voice at once, plays a "stopped" sound and goes straight to listening.
* The caller is told: status "interrupted", `spoken_until` (what was said before the stop) and `transcript` (what he said after).
* He can interrupt agents; they never interrupt him. While he is talking or a Hey Claude send is running, nothing speaks. Pending asks and replies wait and play after he finishes.
* Echo safety: the stop-phrase detector runs with voice processing (echo cancellation), so Needs You's own voice never triggers it.
* Bug: one of his Hey Claude messages arrived starting mid-sentence. Cause: the message quoted "Hey, Claude" inside it, and the parser used the last wake word. Fix: use the first wake word and only skip immediate repeats.

## History

### 2026-11-23 18:32 UTC (agent)

Done, installed and verified live with the owner on 23 Nov (commit 0bdc054, pushed to main).

- Live test: he said "Stop, Claude" mid-sentence; speech stopped, the stopped sound played, and the caller got `status: "interrupted"` with `spoken_until`. The recognizer heard "Stop" first, and a lone "Stop" now counts when the spoken text has no "stop" in it, so it stops on the first word.
- Stop match widened after the first live try came through as "Stuff cloud". It now accepts any st- word before Claude/Cloud. The detector uses SpeechAnalyzer's fast mode.
- Echo: with voice processing on, the detector heard none of Needs You's own speech in 4 runs. With it off, it transcribed its own voice, so the echo cancellation is doing the work.
- Fallbacks: voice processing, then plain mic, then plain playback, then AVAudioPlayer. Speech always plays.
- Turn-taking (asks wait while he gives a Hey Claude command, clarify questions go first) is installed but was not tested live on its own.
- Start of messages: the first-wake-word fix shipped in 9ac6611. New in 0bdc054: speech that starts again while a segment is closing now opens a new segment with that audio. Before, a "Hey Claude" said about 1.5 s after a pause was dropped. Proved with a generated file: the full message arrived. Pre-roll is now 1 s for both Hey Claude and ask.
<!-- SECTION:DESCRIPTION:END -->
