---
id: TASK-4
title: Hear the owner from across a noisy room
status: Backlog
assignee: []
created_date: '2026-11-23T17:26:43Z'
updated_date: '2026-11-26T20:07:56Z'
labels:
  - hm-1314
dependencies: []
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1314
Related: TASK-15 (HM-1328), TASK-3 (HM-1313), TASK-19 (HM-1332), TASK-6 (HM-1316), TASK-5 (HM-1315)

The owner 23 Nov, after the Hey Claude live test: "if I'm away from my keyboard, across the room, and the room is kind of noisy, then you don't pick up my voice. Is there anything we can do apart from buying an expensive microphone?"

Options, cheapest first:

1. Turn on Apple's voice processing on the mic input (`AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`: noise suppression, echo cancellation, automatic gain). Software only, free. Try this first and measure with noisy far-field recordings.
2. Lower the speech-start threshold relative to the room noise, plus a quick "say Hey Claude 3 times" calibration in Settings.
3. Use the iPhone (Continuity mic) or AirPods as the input when he is away from the desk. The Microphone setting already picks a device; add "follow AirPods when connected".
4. Hardware fallback: a USB conference speakerphone with a beamforming mic array (about €50–100), not an expensive studio mic.

## History

### 2026-11-23 17:51 UTC (agent)

Progress, 23 Nov:
- The speech gate now listens through Apple's on-device voice isolation; the recognizer still gets the plain mic. Measured offline, wake detection at 0 dB SNR went from 0/6 to 4/6 and at -3 dB from 0/6 to 4/6, with 0 false openings per minute of room noise. CPU is about 1 % for isolation and about 4 % for the whole app while listening.
- First install broke `ask` (error -10875): the isolation unit cannot sit in the live mic graph on this Mac. Fixed. It now renders offline, off the audio thread, and falls back to plain input if anything fails. A crash on teardown, where the engine was released on its own audio queue, is fixed too.
- Next: an end-to-end far-field run through the installed app, then a live test with the owner from across the room.

### 2026-11-23 18:32 UTC (agent)

Status 23 Nov: moved to Todo. Nobody is on it right now, and the far-field part is not verified yet.

- The -10875 failure on `ask` is fixed in 0bdc054 and installed. The ask mic now retries on a fresh engine: isolation meter first, then plain input, then plain input on the default mic, with short delays so the device can leave voice processing. After the fix, 3 live asks right after voice-processing playback all listened fine. There is no -10875 in audio.log since 17:37 UTC.
- Still open: an end-to-end run from across a noisy room with the owner. Options 2 and 3 from the description (calibration, follow AirPods) are not started.

### 2026-11-23 19:13 UTC (agent)

Far-field noisy-room test, live on 23 Nov with local speech (commit 2e30fea). The owner spoke from the couch with background noise.
- The first "Hey Claude" was missed. The speech gate opened too late and cut off the start.
- The second, "Hey Cloud, can you hear me?", was heard, and every engine transcribed it correctly.

1 of 2 caught. Keeping this open: the late gate onset needs fixing, either a longer pre-roll or a lower gate threshold. Then repeat the test.

### 2026-11-23 20:15 UTC (agent)

Interim, commit 8472f28 (pushed and installed): listener changes for far-field wake.

**Synthetic far-field clips** (15 clips, 5 voices × 3 noise scenes: pink noise, TV talk, music): before 1/15 woke, after 6/15. The rest are clips where neither engine can hear "Hey Claude" even on the whole file.

**The owner's name in transcripts** (24 Kokoro clips): 15/24 before, 23/24 after.

**Live, the owner on the couch with a video game playing:**
- 3 of 4 "Hey Claude" woke the listener.
- The miss came while a game voice was talking over him; his repeat a second later was caught.
- Tries 3 to 5 happened without the game and near the desk, so they don't count as far-field (the owner said so).
- Two bugs found and fixed during the session: a woke command came back empty (overlapping Parakeet calls), and a command never ended while game voices kept talking ("done" now ends it).

**Mistake during the test:** the 10-minute test-pane lock expired, and "Test four." went into the owner's real chat "Recipe notes". Nothing else was sent there, and the owner was told by voice. From now on the pane is re-armed before every try.

**Next:** HM-1328 phase 1 (Silero VAD gate) is meant to fix the miss under overlapping voices. After it lands, repeat the far-field test with the game on. This issue stays In Progress until then.

### 2026-11-23 20:48 UTC (agent)

Retest after HM-1328 phase 1, the owner on the couch: 5 of 5 "Hey Claude" were caught, but the owner said he paused the game each time. So a wake word said while game voices talk over him still fails. Pauses in the game are fine.

He asked whether bigger models, maybe on his Linux machine with a GPU, could fix this. Options, waiting for his decision:
1. **Own-voice filter:** keep only audio that matches his voice, using speaker embeddings, which FluidAudio already has. Stays on the Mac.
2. **Trained wake word** (HM-1328 phase 2): an openWakeWord "hey claude" model trained with his voice and game audio as negatives. Stays on the Mac.
3. **GPU box:** stream audio to his Linux GPU machine for bigger separation and recognition models. Audio would leave the Mac, which the current design rules out.

Moved to Todo with Needs owner until he picks one.

### 2026-11-23 21:29 UTC (agent)

The owner decided (23 Nov): own-voice filter. Enroll his voice, keep Hey Claude, act only on his voice. The Linux GPU machine is allowed for compute; the mic stays the Mac's. Handed to the Needs You agent.

### 2026-11-23 21:40 UTC (agent)

Own-voice filter built and installed (needs-you dc724c3). It stays In Progress until the live retest with the owner.

What it does, once his voice is learned (Settings → Hey Claude → Learn My Voice, or `needs-you voice-test --title learn`):
- A "Hey Claude" counts only if a 3 s window of the last 5 s matches his voiceprint. This uses CAM++ from FluidAudio and runs on the Mac, taking about 15 ms per window.
- His turn ends about 1 s after the last 3 s stop sounding like him, even while game voices keep talking.
- Stretches without his voice are muted before Parakeet transcribes.

Measured on his saved clips, with 5 reading clips as enrollment. Wake threshold is 0.45; anything under 0.38 counts as "not him":
- His clips, including mixes with game audio at 0 dB and −6 dB: every clip has a matching window. Window medians are 0.43–0.71. The worst case is a clip with game plus music, which peaked at 0.46.
- Game dialogue alone: 0 of 12 windows match, max 0.42.
- TTS voices and a TV clip: 0 matches, max 0.37.
- With 1.5 s windows the two groups overlapped, so 3 s windows were chosen.
- Wake file tests: his "Hey Claude" with game audio woke. TTS "Hey Claude", with and without game audio, woke before enrollment and was ignored after.

Test lock now fails closed. Once a pane has been armed, nothing is sent anywhere after the lock expires, the pane disappears, or the app restarts. The lock is kept in defaults until `--arm-pane none`. Claude chat panes cannot be armed.
- Verified: a missing pane gives "Not sent", and arming a Claude pane is refused.

The owner's enrollment through his own mic, plus a live retest with the game on, are next.

### 2026-11-23 21:59 UTC (agent)

Live retest with the owner, a game running the whole time and never paused (needs-you 13f2d11).

- Enrollment by voice: the owner read 6 lines into his own mic. Each line is now checked against its transcript and repeated if missed. The first run had trained on missed lines.
- Speaker match on every wake: 0.56, 0.76, 0.64, 0.64, 0.68 (threshold 0.45). The game never passed. A 60 s game-only stretch sent nothing.
- 5 tries:
  - Try 1 sent "Test one. Can you hear me?" ✓
  - Try 2 the first time: nothing was heard. On repeat, sent "Hey, Club, this one tastes too."
  - Try 3 sent "Test three." ✓ The turn ended on "not his voice" while the game kept talking.
  - Try 4 the first time: the wake word was heard as "Hey God". Fixed: once a voiceprint exists, more mishearings count (god, club, claim, a cloud…), because his voice is also required. On repeat, sent "A cloud, this one test for the game is still running."
  - Try 5 sent "Very cloud, this one has wife."
- The owner's verdict: "doesn't work very well". The speaker filter works. What fails is speech-to-text of his words over the game: Parakeet on the Mac mishears both the wake word and the message.

Test lock: disarmed after the test, and the throwaway tab is closed. All test sends went only to the sink pane.

Next decision (stays In Progress): run the command audio through a bigger ASR model on a separate Linux GPU machine (e.g. Whisper large-v3 or Canary on the GPU), and/or use a closer mic. The coordinator decides with the owner.

### 2026-11-23 21:59 UTC (agent)

The owner (voice, 23 Nov): Hey Claude still misses too often. Run bigger models on the Mac, not on the separate Linux GPU machine (so it can stay off). Mac: M5 Pro, 18 cores, 64 GB, 92% free; Needs You uses ~0.5-1 GB, 3-5% of one core. Budget: a few GB. Trained wake model approved.

### 2026-11-23 22:29 UTC (agent)

The bigger speech-to-text model now runs on the Mac (needs-you 1d087d7, installed). The Linux GPU machine path is dropped.

Measured on his 19 real "Hey Claude" clips and 15 clips without the wake word, mixed with game dialogue that has his own voice cut out. The game starts at a random offset.

Wake caught, as clean / game at the same level / game 6 dB louder:
- Parakeet v2 (old): 19/19, 10/19, 11/19
- Parakeet v3: 18/19, 11/19, 8/19
- Apple SpeechAnalyzer: 15/19, 7/19, 7/19 (earlier mix)
- **Whisper large-v3-turbo + prompt (new): 19/19, 18/19, 15/19**
- None of them woke on any of the 31 clips without the wake word, including 60 s of game only.

Words over the game, as WER against each model's own clean transcript: Parakeet 66% → Whisper 46% with the game at the same level.

Latency is about 0.5 s per wake check (Whisper, on the Neural Engine). Parakeet took about 50 ms.

CPU and RAM, before → after:
- Idle listening: about 5% of a core, footprint 1.09 GB → about 1–6% of a core, footprint about 0.3 GB. Whisper sits on the Neural Engine, outside the process footprint.
- While transcribing non-stop: 22–29% of one core.

Also checked:
- Masking the audio to only his voice did not improve WER with Whisper (46% vs 45%).
- More mishearings now count once his voice is verified: "Hey Claudes", "Hey Claire", "Playcloud", "Dayclub".
- Full-pipeline file test before the game track was cleaned: 13/19 woke. That run was skewed because the old game track contained his own "done".

Target-speaker extraction: I wanted to test PS4, a BSRNN + ECAPA model fine-tuned for ASR on real meeting audio, Apache-2.0. The auto-mode permission check denied running its downloaded Python inference script, so I stopped there. It needs the owner's OK.

Next: a live retest with the owner, with the game running.

### 2026-11-23 22:37 UTC (agent)

Paused for the night at the owner's request; continues with him tomorrow (live retest / two-mic recordings). First version installed (needs-you 23c77c6 for dual mic, 1d087d7 Whisper turbo).

### 2026-11-23 22:38 UTC (agent)

Overnight prep for tomorrow's full test with the owner (silent: no voice prompts, no live mic). Agent builds Training, the model switcher, the merge pipeline and a morning test plan.

### 2026-11-23 23:13 UTC (agent)

Ready for the live retest. It is step 4 of the morning plan in HM-1332.

**Default speech-to-text:** Whisper large-v3-turbo with the prompt, for both the command and the wake check. You can now switch both in Settings → Models.

**Overnight check:** a synthetic session built from his clips with the game mixed in at his level.

| Model | Wake caught | False wakes |
|---|---|---|
| Whisper turbo | 19/19 | 0/13 |
| Parakeet v2 | 13/19 | 0/13 |

**Own-voice filter:** Training → Learn From Recordings can now re-learn it from up to 30 minutes of his voice over a background. It then tunes the threshold so at most 2% of background windows pass.

**PS4 voice extraction:** not run and not loaded. Our own model definition is in `tools/ps4/`. The toggle stays disabled until the owner approves.

**Still open:** the live retest with the owner.

### 2026-11-24 06:17 UTC (agent)

Waiting on the owner: Do the live far-field retest from the couch with the game on (step 4 of the HM-1332 morning plan), and say whether the PS4 voice extraction model may be run. The far-field fixes are built and installed, but only the offline Whisper turbo checks passed, and the last live test on Parakeet failed.

### 2026-11-24 15:49 UTC (agent)

PS4 voice extraction is built and installed (needs-you 920241c). The switch is **off** by default. It needs the owner's live A/B, which is step 6 of `docs/morning-test-plan.md`.

**Download:** only the weights, into an empty `~/tmp/ps4-weights/`. https://huggingface.co/TaurenMountain/PS4/resolve/main/checkpoint_epoch037.pt, 282,746,518 bytes, SHA-256 3d5621c8…4196 (matches the Hub LFS oid). Opened with `torch.load(weights_only=True)`. No upstream code was run.

**Strict load:** our `ps4_model.py` loaded the weights with `strict=True` and no changes: 754 keys, none missing, none extra, no shape mismatches. A TTS control confirms the speaker conditioning works: the enrolled voice is kept and a voice that isn't enrolled is cut by 42 dB.

**Quality** (SI-SDR gain, 6 s clips with the game or music at 0 / -6 dB):
- TTS voices: +7 to +13 dB.
- His saved Mac-mic clips: +0.1 dB at 0 dB SNR, +4.7 dB at -6 dB. Without an 80 Hz high-pass it got 15-25 dB worse, because the clips carry a large DC offset. The app applies the high-pass.
- PS4's speaker encoder finds his clips inconsistent (median cosine 0.45 between his own clips, 0.9 within one TTS voice). Far-field Mac mic audio is the weak spot.

**Core ML** (STFT/iSTFT inside the graph as DFT convs; output matches PyTorch at 55 dB):
- CPU+GPU: 30 ms per 1 s, 92 ms per 4 s, 128 ms per 6 s, at 40-55% of one core. The Neural Engine path takes 240 ms per 1 s, because the LSTMs fall back.
- In the app: 6 s takes 140-290 ms, 54 s takes 1.9 s. RAM is +0.5 to 0.8 GB while loaded, and it unloads after 10 idle minutes.

**App:** Settings → Models → Voice extraction (PS4, experimental). When on, it runs before every transcription except the Parakeet "done" checks. It keeps the original audio when the output comes back more than 30 dB quieter. `ps4-enroll.wav` is seeded from his earlier enrollment reads, and Training → Learn From Recordings rewrites it.

Next: the owner runs the live A/B (game on, PS4 on vs off), plus Evaluate with the switch on and off.

### 2026-11-24 17:04 UTC (agent)

Evaluate on the owner's 165 training clips, Whisper turbo, PS4 on vs off (24 Nov):

| Background | Wake on | Wake off | WER on | WER off |
|---|---|---|---|---|
| Quiet | 40/42 | 38/42 | 20% | 18% |
| Music | 16/33 | 17/33 | 69% | 79% |
| Game | 8/29 | 10/29 | 91% | 99% |

Median time per clip: 740 ms with PS4 on, 500 ms off. 0 false wakes either way.

The PS4 on/off difference is within noise. It doesn't rescue his voice under music or game audio on the Mac mic, and it adds about 250 ms. Recommendation: leave it off. The bottleneck is the far-field Mac mic with a loud background, so a closer mic (iPhone) is the next lever.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Nobody is on this, so it moves to Backlog. What shipped (all in v1.0.0 and later, installed 1.6.0): voice isolation on the gate, Silero VAD, the own-voice filter, Whisper large-v3-turbo for the wake check (setting wakeModel "wlarge+p"). PS4 stays off (ps4Enabled 0) after the 24 Nov Evaluate showed no gain. The iPhone mic is switched off (TASK-18). Still open: a wake phrase said over loud game audio from across the room. The live wake debug log on 26 Nov also shows several "wake word ignored: not his voice" lines at 0.23 to 0.33 under the 0.35 bar, which may be the owner on the webcam mic.
<!-- SECTION:NOTES:END -->
