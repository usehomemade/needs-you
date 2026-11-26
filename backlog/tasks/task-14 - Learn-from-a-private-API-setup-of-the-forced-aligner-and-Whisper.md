---
id: TASK-14
title: Learn from a private API setup of the forced aligner and Whisper
status: Done
assignee: []
created_date: '2026-11-23T20:11:50Z'
updated_date: '2026-11-26T20:07:58Z'
labels:
  - hm-1327
dependencies: []
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1327
Related: TASK-13 (HM-1326)

The owner (23 Nov): ssh into another machine, read a private speech API project, and see how it runs the forced aligner and CrisperWhisper in an optimized way. Read-only. Feeds HM-1326.

## History

### 2026-11-23 20:16 UTC (agent)

Findings from a private API project (read only, no secrets).

CrisperWhisper2.0 (apps/inference/src/inference/model.py, settings.py, ct2_batch.py):
- Runs through the vendored `crisperwhisper` SDK. Backend picked by device: CTranslate2 (custom fork) on CUDA, FP16; Transformers on CPU/MPS, FP32. CT2 has no MPS support. Mac/small/turbo only ever ran Transformers on MPS FP32 (Large took 15-22 s for 10-25 s audio, so slow and not tuned).
- One call returns verbatim and intended readings (two prompts, one encoder pass on CT2), word timestamps from cross-attention alignment, per-word confidence from token logprobs.
- Language: explicit or detected from first 30 s via model.detect_language.
- Windows are 30 s; longer audio uses SDK longform continuation. Batching (max 4, same 30 s window, length spread <=10 s) exists only on CT2/CUDA.
- Warmup at load: 1 s silence plus 35 s noise through both paths (first call otherwise ~11 s on an L4), plus a batched pair.
- Repair: relaxed n-gram repeat thresholds so real stutters are not mangled; rejects timestamps beyond the audio length.
- No VAD, no hotwords or prompts, no beam or temperature knobs in their code (SDK defaults; greedy-like first-token path). Audio decode: soxr resample to 16 kHz mono float32.
- Measured (CUDA L4, Large): warm processing p50 1.27 s for 18 s audio with CT2 vs 8.4 s Transformers. Realtime mode (removed Sept 2026): drafts every ~0.9 s after 2 s of audio, final 1.6 s p50 after commit.

Forced aligner (apps/aligner/src/aligner/engine.py, README.md):
- Package the forced-aligner package 0.2.5: WavLM-large features (fp16, batch 8 on 30 s windows) -> 40-dim LDA -> triphone GMM-HMM, 39 phones plus 15 vocal-event units; OOV words via espeak-ng.
- Takes audio plus the verbatim transcript; outputs word and phone times and confidence. Pipeline: prepare on CPU, emissions on one GPU thread, beam Viterbi on CPU (numba, nogil, memory budget). 19.9 ms mean boundary error on Buckeye. Heavy: WavLM-large is the cost.

Ideas for Needs You (Apple Silicon):
1. Do not copy their Mac path (PyTorch MPS FP32, seconds per clip). Use CrisperWhisper2.0_small converted to Core ML / MLX or whisper.cpp-style Metal, int8/fp16.
2. Keep their serving tricks: warmup at launch on silence and noise, resident model, one worker thread, 16 kHz mono float32 via a fast resampler.
3. Short utterances fit one 30 s window: skip longform, set explicit language to skip detection, cap new tokens.
4. Add own VAD (Silero or Parakeet's) to end utterances; they have none.
5. Skip the aligner on device (WavLM-large too heavy); use cross-attention word timestamps or Parakeet's token times, and borrow their zero-length-word and past-duration sanity checks plus stutter-safe repeat thresholds.

### 2026-11-23 20:16 UTC (agent)

Research done (read-only on that machine). Findings are in the comment above and were handed to the Needs You agent for HM-1326. Conclusion: run CrisperWhisper2.0_small on Core ML, MLX or whisper.cpp, not that project's slow MPS path; skip the WavLM aligner on device.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Research, nothing to ship. Findings fed TASK-13 and TASK-15.
<!-- SECTION:NOTES:END -->
