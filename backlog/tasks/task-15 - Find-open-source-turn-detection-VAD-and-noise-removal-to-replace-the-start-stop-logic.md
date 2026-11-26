---
id: TASK-15
title: >-
  Find open-source turn detection, VAD and noise removal to replace the
  start/stop logic
status: Done
assignee: []
created_date: '2026-11-23T20:11:52Z'
updated_date: '2026-11-26T20:07:58Z'
labels:
  - hm-1328
dependencies: []
ordinal: 15000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1328
Related: TASK-11 (HM-1324), TASK-4 (HM-1314)

The owner (23 Nov, asked before too): find open-source projects or algorithms that replace our own detect-voice/start/stop logic, plus noise removal and voice activity detection. Compare, pick, prove on his recordings. Related: HM-1314, HM-1323, HM-1324.

## History

### 2026-11-23 20:13 UTC (agent)

Research for HM-1328: replace hand-written start/stop logic. No code changed.

What exists today: Audio.swift Recorder = RMS dB gate (noise floor +14 dB, 0.22 s loud run opens, 1 s preroll, 0.9 s pause check, 3 s silence stops). WakeListener = energy gate + SpeechAnalyzer + Parakeet re-read every 1.5 s. Apple AUSoundIsolation already used for levels. BargeIn already uses voice processing. FluidAudio 0.18.3 is already a dependency (Apache 2.0), so Silero VAD is one call away.

## Recommended stack
1. VAD: Silero v5 via FluidAudio `VadManager` (streaming `processStreamingChunk`, speech start/end events, minSpeechDuration/minSilenceDuration). ~3-5 h. Replaces the RMS gate: fixes late gate open and far-field misses (probability-based, not level-based). Silero MIT, ~2 MB, <1 ms/chunk. Risk: Silero is slow on speech-to-silence edges (hundreds of ms), so keep a short hangover.
2. Turn detector: Pipecat Smart Turn v3.2 (BSD-2, ~8M params, 23 languages incl. Turkish, audio-only, 8 s window). CoreML port: https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML (~3.5 ms on ANE; Swift usage in speech-swift https://soniqo.audio/guides/turn). Run it when Silero sees ~0.3-0.5 s silence; if "complete" > 0.5, stop; if "incomplete", wait up to a hard cap (e.g. 2 s) instead of the flat 3 s. ~6-10 h. Fixes "listens too long" and cuts off "uh, um" mid-thought. Risk: README says nothing about fillers or accented English; must A/B on the owner's own recordings first (2 h test harness, recordings already exist via the test-file path in Recorder).
3. Noise/echo: keep Apple AUSoundIsolation + VPIO (already built); feed raw audio to Parakeet and Smart Turn (denoisers often hurt ASR). Optional later: FluidAudio LocalVQE (beta, echo+noise+dereverb), or GTCRN (MIT, 48 K params, needs CoreML conversion, 10-16 h). 0 h now.
4. Wake word: cheapest first: gate Parakeet re-read by Silero instead of energy (2-3 h). Then, if far-field still misses: openWakeWord custom "hey claude" (code Apache 2.0; trained from synthetic TTS in a Colab, <1 h for basic model; ONNX Runtime from Swift, 12-20 h). Risk: pretrained models are CC BY-NC-SA (own trained model is fine for private use; verify backbone licence); last release Feb 2024; Turkish accent needs real-voice negatives and positives in the training mix.

## Per category (max 5)
VAD
- Silero v5/v6: MIT, 2 MB, ONNX/CoreML (FluidAudio). Best fit.
- TEN VAD: faster speech-to-silence detection than Silero (self-reported), 731 KB macOS framework (C, arm64), RTF 0.016 on M1. Licence is Apache 2.0 "with additional conditions": read LICENSE first. 6-8 h. https://github.com/TEN-framework/ten-vad
- FireRedVAD: claims 97.6% F1 beating Silero/TEN (own benchmark, test set not public), streaming, NCNN runtime, no Swift. Licence unclear (HF Apache, PyPI MIT). 12+ h, watch only. https://github.com/FireRedTeam/FireRedVAD
- WebRTC VAD: old GMM, weak on noise and accents. Skip.

Turn detection
- Smart Turn v3.2: above. https://github.com/pipecat-ai/smart-turn
- Parakeet EOU in FluidAudio: streaming end-of-utterance, English only, no extra dependency. 4-6 h. Good second choice, test head-to-head.
- LiveKit turn detector v1-mini: audio, 14 languages incl. Turkish, but ~320 MB, "LiveKit Model License", Python/Node only. Not viable in Swift. https://docs.livekit.io/agents/build/turns/turn-detector/
- TEN turn detection: Qwen2.5-7B text model, EN/ZH, restricted Apache. Too big. https://github.com/TEN-framework/ten-turn-detection

Noise/echo
- Apple AUSoundIsolation / VPIO: in use. Voice isolation mic mode is user-chosen in Control Center, not settable by the app.
- GTCRN: MIT, beats RNNoise and DFN on VCTK-DEMAND per its README. https://github.com/Xiaobin-Rong/gtcrn
- DeepFilterNet3: MIT/Apache, Rust, no ONNX in README. 12-20 h. https://github.com/Rikorose/DeepFilterNet
- RNNoise: BSD-3, C, 48 kHz only, oldest quality. 4 h. https://github.com/xiph/rnnoise

Wake word
- openWakeWord https://github.com/dscripka/openWakeWord (above)
- Porcupine https://github.com/Picovoice/porcupine: Apache SDK but every call needs a Picovoice AccessKey; custom keyword via their console. Free-tier terms NOT verified. ~6 h.
- microWakeWord https://github.com/kahrendt/microWakeWord: microcontroller target, "most likely not usable" starter notebook. Skip.

Pipelines worth copying: FluidAudio (already in use), speech-swift (Smart Turn + Silero + `vad-stream --smart-turn` demo of exactly this pattern), Pipecat (Silero then Smart Turn, same design).

## Expected gains
- Late gate: large (Silero probability vs 0.22 s RMS run + threshold)
- Far-field wake 1 of 2: moderate from Silero gating; large only with a trained wake model
- Listens too long: large (Smart Turn instead of fixed 3 s)
- Fillers/accent: unknown until A/B; Parakeet already tolerates accent, Smart Turn untested

## Total
Phase 1 (Silero + Smart Turn + test harness): ~12-17 h. Phase 2 (wake model): 12-20 h.

## Not verified
Smart Turn on fillers/accent, Porcupine free-tier terms, TEN VAD licence text, release dates (pages did not show them).

### 2026-11-23 20:48 UTC (agent)

Phase 1 shipped (commits 15bf444 and 19a437c, installed).

**Silero v5** (through FluidAudio) replaces the loudness gates in Audio.swift and WakeListener.swift. The old gate is kept as a fallback.

**End of turn:** Smart Turn v3.2, CoreML port, BSD-2 licence (checked: LICENSE file plus model card), 17 MB, downloaded at install. It is asked after a pause; the owner chose 2 s before it judges and 4 s at most, both in Settings. Apple voice processing and sound isolation are unchanged.

**A/B on the owner's 6 reading clips**, turn end measured from his last word:
- Old fixed 3 s pause: +3.0 s on every clip.
- Silero alone, 1 s hangover: about +1.0 s, but it cut one clip at his mid-sentence pause.
- Smart Turn checked after 0.4 s: +0.5 s, but also cut that clip after "Merge the next."
- Smart Turn checked after 0.75 s: +0.8 s median, nothing cut. It said "not done" at his 1 s mid-sentence pause.
- Parakeet EOU (FluidAudio, 160 ms chunks): heard nothing in 4 of 6 clips and most of his other recordings. Dropped.

**Live:** 0.75 s cut the owner off when he paused on purpose, so he chose 2 s / 4 s. After that, a 28 s answer with pauses came through whole.

**Memory and CPU:** Silero adds about 2 MB and under 1 ms per 256 ms chunk; Smart Turn adds 17 MB and about 5 ms per check. Idle CPU stays about 4 %.

**Far-field clips** (synthetic, 15): 6 of 15 woke, the same as before Silero. The remaining clips can't be heard by any engine.

**Not solved:** a "Hey Claude" said while game voices play over him. In the live retest the owner paused the game for each try, so the 5 of 5 does not count. Phase 2 needs his decision (see HM-1314).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Phase 1 (Silero, Smart Turn) ships in v1.0.0 and later. Phase 2, a trained wake model, was never built: the Whisper turbo wake check took its place (TASK-4). Open far-field work is in TASK-4.
<!-- SECTION:NOTES:END -->
