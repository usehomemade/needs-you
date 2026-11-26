---
id: TASK-17
title: Cancel TV/game audio using the TV audio output as echo reference
status: Backlog
assignee: []
created_date: '2026-11-23T22:20:52Z'
updated_date: '2026-11-26T20:07:58Z'
labels:
  - hm-1330
dependencies: []
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1330

The owner (23 Nov) asked: use the TV mic, and capture Apple TV / game console audio for acoustic echo cancellation. Findings: the TV mic is not usable (LG's mics are push-to-talk in the Magic Remote or voice-assistant only, no API to stream them). The reference-signal part is doable: TV optical (or HDMI eARC extractor) out -> USB S/PDIF adapter -> Mac as a second input, then WebRTC AEC3 (or SpeexDSP) subtracts that signal from the Mac mic before VAD and speech-to-text. Needs: the cable run to the Mac, a cheap adapter, TV audio set to pass PCM. Waiting on the owner: where the Mac sits vs the TV, and OK to buy the adapter.

## History

### 2026-11-23 22:23 UTC (agent)

The owner: TV and Mac are in the same room, so the cable run works. Hardware: a USB S/PDIF *receiver* (capture, not a transmitter), stereo PCM, USB Audio Class (shows under Input in Audio MIDI Setup). Candidates: Cubilux USB SPDIF receiver (stereo only), Hifime UR23 (UAC1, 32-96 kHz). The TV's optical out must be set to PCM, not Dolby/bitstream. Software (AEC3 with a second input as the reference) can be built and tested now with Mac-played game audio as the reference; the agent queues it after HM-1314. Waiting on the owner: check the TV has an optical out, then buy the receiver.

### 2026-11-23 22:24 UTC (agent)

The owner (23 Nov): no new hardware for now, software only. Parked in Backlog; the echo-reference setting can come back if he gets a receiver later.

### 2026-11-24 00:17 UTC (agent)

Waiting on the owner: decide whether to buy a USB S/PDIF receiver (for example a Hifime UR23) and check that the TV has an optical out, or tell us to close the ticket. Nothing is built yet, because the TV echo reference needs the receiver and you parked this as software only.

### 2026-11-24 00:20 UTC (agent)

Back to Backlog: the owner said on 23 Nov he doesn't want to buy hardware now (software only). Parked, not waiting on him.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still parked: no echo-reference code on origin/main, and no S/PDIF receiver. Reopen only if the owner buys one.
<!-- SECTION:NOTES:END -->
