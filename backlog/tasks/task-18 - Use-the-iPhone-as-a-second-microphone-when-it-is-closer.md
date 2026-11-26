---
id: TASK-18
title: Use the iPhone as a second microphone when it is closer
status: Backlog
assignee: []
created_date: '2026-11-23T22:24:56Z'
updated_date: '2026-11-26T20:07:59Z'
labels:
  - hm-1331
dependencies: []
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1331
Related: TASK-19 (HM-1332)

The owner (23 Nov): no new hardware; optimize in software. Idea: when he talks, also use his iPhone's mic, since it is sometimes closer than the Mac. Options to evaluate: (1) Continuity mic (iPhone selected as a Mac input; check whether it works while the phone is in use or in a pocket), (2) a small iOS companion app (same repo, TestFlight/dev install) with a background audio session that runs VAD and the own-voice check on the phone and streams speech to the Mac over the local network or a VPN; the Mac picks the cleaner signal per utterance (SNR plus speaker score). Measure battery cost per hour.

## History

### 2026-11-23 22:26 UTC (agent)

The owner decided: Continuity (no iOS app). Listen on Mac and iPhone mics at once, use whichever gives the better result per utterance, every time. On/off switch for the iPhone mic (menu bar + Settings), silent fallback to the Mac mic when the phone drops.

### 2026-11-23 22:27 UTC (agent)

The owner add-on: also try merging both mics (aligned by cross-correlation plus drift tracking) via SNR-weighted combining, 2-channel blind source separation (AuxIVA), or far mic as noise reference. Keep only if it beats best-mic selection on WER.

### 2026-11-23 22:37 UTC (agent)

First version is built and installed (needs-you 23c77c6). Stays In Progress.

- **Two mics at once.** The Mac mic and the iPhone Continuity mic each have their own listener: AVAudioEngine, Silero, wake check (SpeechAnalyzer + Whisper), and own-voice check. The iPhone mic is found by its transport type (Continuity Capture). On his Mac it appears as "<name> Microphone".
- **Per-utterance pick.** When one mic wakes, the other is made to record the same command, even if it missed the wake word. Each take gets a score: his voice score from CAM++ plus 0.01 × SNR in dB, so 10 dB of SNR counts the same as 0.1 of voice score. The app waits up to 2.5 s for the second take, then sends the better one. The winner and both scores go to `~/Library/Application Support/Needs You/mic-choice.log` and to audio.log.
- **Switch.** "Use iPhone Mic" is in the menu bar, and "Also Use the iPhone Mic" is in Settings. Settings shows "Listening (<name> Microphone)" or "Not nearby: using the Mac mic". Off stops the iPhone listener right away.
- **Fallback.** A device-list listener stops the iPhone listener without a sound when the device disappears, and starts it again when it comes back while the switch is On. Observed once: the iPhone dropped off as a mic tonight and the Mac mic carried on.
- **Test hook.** `needs-you voice-test <prefix> --title record:<seconds>` records both mics raw at the same time, plus the start offset. This is for the merge experiments (alignment, then per-band combining, AuxIVA, and the far mic as noise reference).

Not measured yet:
- CPU and RAM with both mics. A first look gave 10–17% of one core and about 0.2 GB footprint, against 6–17% with the Mac mic alone. That isn't clean because there was background speech in the room. It needs a controlled run.
- iPhone battery and heat.
- Merge experiments. They need two-mic recordings of the owner.

The owner (voice, 23:36): "Tomorrow, not today." He wants:
- a training section in the app where he can record up to 30 minutes of his voice with music, the game, or a video playing;
- several models he can switch between;
- the options laid out, so they can pick the best one together tomorrow.

### 2026-11-23 22:37 UTC (agent)

Paused for the night at the owner's request; continues with him tomorrow (live retest / two-mic recordings). First version installed (needs-you 23c77c6 for dual mic, 1d087d7 Whisper turbo).

### 2026-11-23 22:38 UTC (agent)

Overnight prep for tomorrow's full test with the owner (silent: no voice prompts, no live mic). Agent builds Training, the model switcher, the merge pipeline and a morning test plan.

### 2026-11-23 23:06 UTC (agent)

The merge pipeline is ready for real two-mic recordings (commits 358d1ba and 3693251).

**What's built**
- **Alignment:** a coarse GCC-PHAT pass, then a refine pass that uses 2 s stretches every 0.5 s with a RANSAC line fit. It finds the offset and the clock drift. The two fixes that made separation work were sub-sample accuracy and the RANSAC fit, which handles his voice and the game sitting at different distances.
- **Methods:**
  - AuxIVA (default, 1024-sample frames)
  - Far mic as a noise reference: NLMS that adapts only where the far mic dominates
  - Per-band SNR weighting
- All methods drop the bins below 94 Hz. The game's bass there broke the blind separation.
- **Settings → Models → Two mics:** Best mic per utterance, or Merge (experimental) with a method picker. A merge is used only when the takes line up and it beats the best take's own-voice score by at least 0.03. Every decision goes to `mic-choice.log`.
- **Training → Learn From Recordings:** builds merged takes, labelled "merge-iva" and "merge-nlms", for every line, so Evaluate scores Mac, iPhone and merged side by side.

**Proof: `./scripts/test-merge.sh`, all checks pass**
The test uses synthetic sources with a 37 ms offset and 100 ppm drift.

| Check | Plain gains | Room with echo |
|---|---|---|
| Offset error | 0.0 samples | n/a |
| Drift found | 100 ppm (true 100) | 100 ppm (true 100) |
| Alignment confidence | 1.00 (unrelated signals: 0.00) | n/a |
| Mac mic SIR | -0.9 dB | 1.1 dB |
| AuxIVA SIR | 12.6 dB | 8.3 dB |
| Noise reference SIR | 10.0 dB | 2.8 dB |
| SNR weighting SIR | worse than the Mac mic | n/a |

**Same test on his real voice clip plus the real game track** (`needs-you voice-test ... --title merge-selftest`):

| Setup | Mac | AuxIVA | Noise reference |
|---|---|---|---|
| Plain gains | 11.9 dB | 27.1 dB | 18.2 dB |
| Echoey room | 12.0 dB | 13.4 dB | 12.8 dB |

**Takeaway:** with plain gains the merge clearly helps. In a room with echo the gain is small, 1 to 1.5 dB. Real numbers need his two-mic recordings, which is step 2 of the morning plan.

**Still open:** merge numbers on real recordings, tomorrow with the owner.

### 2026-11-24 06:17 UTC (agent)

Waiting on the owner: do step 5 of the needs-you morning test plan with the agent (about 5 minutes). Unlock the iPhone, keep it near you, and record the two-mic sessions so the per-mic and merge results can be measured. Current state: dual-mic listening with the iPhone Continuity mic is built, pushed and installed (needs-you 23c77c6), but the merge pipeline only has synthetic test results and no live two-mic test has run yet.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Built and shipped (TwoMic.swift, in v1.0.0 and later), but the owner has the iPhone mic switched off (iphoneMic 0). audio.log shows it last on 24 Nov. mic-choice.log has 88 picks, all Mac. The two-mic recordings and the merge test never happened. Nobody is on it, so Backlog. Reopen with TASK-4 if far-field comes back.
<!-- SECTION:NOTES:END -->
