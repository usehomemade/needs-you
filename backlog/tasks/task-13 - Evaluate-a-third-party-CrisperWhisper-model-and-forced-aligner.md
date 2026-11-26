---
id: TASK-13
title: Evaluate a third-party CrisperWhisper model and forced aligner
status: Done
assignee: []
created_date: '2026-11-23T20:09:21Z'
updated_date: '2026-11-26T20:07:58Z'
labels:
  - hm-1326
dependencies: []
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1326
Related: TASK-14 (HM-1327)

The owner (23 Nov): check a third-party CrisperWhisper model and a third-party forced aligner as speech models; compare with Parakeet v2 on his recordings (WER, latency, memory, the owner's name).

## History

### 2026-11-23 20:09 UTC (agent)

Handed to the Needs You agent (same one working HM-1314).

### 2026-11-23 20:48 UTC (agent)

Evaluated: we stay on Parakeet v2. CrisperWhisper2.0_small is slower, heavier and less accurate on the owner's voice.

**Setup:** the crisperwhisper 2.1.0 SDK, Transformers backend on MPS fp16, language=en, warmed up on silence and noise, max_new_tokens 128. The test set is 6 clips the owner read today plus 24 Kokoro clips with the owner's name. A faster runtime (MLX, Core ML) would not change the outcome, because accuracy is the problem.

**Latency (warm):** CrisperWhisper 140 to 360 ms per mode, so two calls for verbatim plus intended. With hotwords, 160 to 925 ms. Parakeet: 50 to 90 ms.

**Memory:** CrisperWhisper's Python process peaked at 1.4 GB RSS. Parakeet adds about 275 MB in the app and unloads when idle.

**Accuracy on his clips:**
- CrisperWhisper made extra mistakes Parakeet did not: "deploy" became "plug", "Merge the next" became "Merge the eggs", "We should" became "They should".
- "The owner": CrisperWhisper misspelled the name in his clip. With hotwords (the owner's name, Homemade, herdr and two tool names) it got the name and both tool names right, but it also hallucinated on another clip: "Murged <name> Homemade herdr Homemade herdr".
- On the Kokoro clips CrisperWhisper got the name 6 of 24 times without hotwords and 24 of 24 with them. Parakeet plus our spelling fixes gets 23 of 24.

**"Intended" text:** no better than our filler cleanup. It cut one sentence into "I have a hard time. Remember what you said."

**Forced aligner:** skipped. It needs WavLM-large and only adds word timings, which we don't use (HM-1327).

**Licence:** the model weights and their outputs are under its authors non-commercial research licence.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Research, nothing to ship. The app stays on Parakeet plus Whisper turbo. No CrisperWhisper code on origin/main.
<!-- SECTION:NOTES:END -->
