---
id: TASK-19
title: >-
  Voice training section (up to 30 min with music/game/video) and switchable
  speech models
status: Backlog
assignee: []
created_date: '2026-11-23T22:37:41Z'
updated_date: '2026-11-26T20:07:59Z'
labels:
  - hm-1332
dependencies: []
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1332
Related: TASK-18 (HM-1331), TASK-4 (HM-1314), TASK-21 (HM-1345)

The owner (voice, 23 Nov 23:36): wants a Training section that records up to 30 min of his voice while music, a game or a YouTube video plays, several speech models he can switch between in the app, and the options laid out so we choose together. Built overnight; ready for his test.

## Morning test plan

About 45 minutes in total, and every step takes under 5 minutes. Do them in order. The same plan is in the repo at `docs/morning-test-plan.md`.

Before you start, unlock the iPhone and keep it near you. Its mic only joins when it shows up as a Continuity mic ("<name> Microphone").

**1. Training: record (about 15 min)**

1. Open the menu bar icon, then **Training…**.
   Watch for: the window opens with an empty Sessions list.
2. Choose **Quiet** and press **Record**. Read each line out loud and press **Next** (or the space bar). Stop and save after about 3 minutes.
   Watch for: both meters move, the Mac one and "<name> Microphone". If only the Mac meter shows, the iPhone was not picked up.
3. Start the game. Choose **Game**, record about 5 minutes from the couch, and try **Pause** and **Resume** once.
   Watch for: the time stops while paused.
4. Play a video or music. Choose **Video** or **Music** and record about 5 minutes.
   Watch for: three sessions in the list, each marked "Mac + iPhone". The trash icon deletes one.

**2. Use the recordings (about 10 min)**

1. Press **Learn From Recordings**.
   Watch for: "Learned your voice from N windows … threshold … Eval set: N clips". **Undo** puts the old voice back.
2. Under **Evaluate**, tick Whisper turbo, Parakeet v2 and Parakeet v3, then press **Evaluate**.
   Watch for: a table with Mac, iPhone and Merged rows for each model.
3. Optional: also tick Whisper large-v3, distil-large-v3 and Canary. All of them are already downloaded.

**3. Choose models (about 2 min)**

1. In **Settings → Models**, set **Speech to text** and **Wake check** to the winners. Switching works without restarting the app.

**4. Live: Hey Claude over the game (**TASK-4 (HM-1314)**, about 5 min)**

1. Put a throwaway chat in front first. Then, with the game on, say "Hey Claude, this one: test one" five times.
   Watch for: the wake sound each time. Note any misses.
2. Have someone else or a video say "Hey Claude".
   Watch for: no wake.

**5. Live: two mics (**TASK-18 (HM-1331)**, about 5 min)**

1. In **Settings → Models**, set **Two mics** to **Merge (experimental)**, method AuxIVA.
2. With the game on, give five short commands.
   Watch for: the commands still come through.
3. Switch back to **Best mic per utterance** if anything got worse.

**6. Decide (1 min)**

1. PS4: yes or no to trying it. It stays off until you say yes.

### Agent notes
* **Code:** the needs-you repo, commits 358d1ba, 3693251, d3dd880 and eeb2594.
* **Training files:**
  * `Training.swift` (recorder, prompts, store)
  * `TrainingLab.swift` (learn, eval)
  * `TrainingView.swift` (UI and Settings → Models)
* **Models:** `SpeechModels.swift`.
* **Results:**
  * `~/Library/Application Support/Needs You/training/eval/results.json`
  * Per clip: `details-<model>.json`
  * Mic decisions: `mic-choice.log`
* **Test hooks:** `needs-you voice-test --title train-process | train-restore | train-eval:<models>`.
* **PS4:** our own definition is in `tools/ps4/`. It has not been run or loaded, and the toggle is disabled.

## History

### 2026-11-23 22:38 UTC (agent)

Overnight prep for tomorrow's full test with the owner (silent: no voice prompts, no live mic). Agent builds Training, the model switcher, the merge pipeline and a morning test plan.

### 2026-11-23 23:13 UTC (agent)

Built overnight and ready for the owner's test. The test plan is in the description. Nothing was recorded from the room.

**Training window (menu bar → Training…)**
- Records the Mac mic plus the iPhone Continuity mic, up to 30 minutes.
- Guided lines: wake phrases, commands, the owner's name, free talk and quiet stretches.
- Level meters, pause/resume, a session list with delete.
- **Learn From Recordings:** re-learns the voiceprint, tunes the own-voice threshold and builds the eval set. **Undo** puts the previous voiceprint back.
- **Evaluate:** one result per mic (Mac, iPhone, merged), plus per-clip details.

**Settings → Models**
- Pickers for speech to text and for the wake check: Whisper turbo, Whisper large-v3, distil-large-v3, Canary 1B v2, Parakeet v3, Parakeet v2, Cohere.
- Speaker check: CAM++ or off.
- Each picker shows size, RAM and speed. Switching needs no restart.
- The disabled PS4 toggle sits here too.

**Proof:** a synthetic session (9.4 min) built from his existing clips plus the game track. The iPhone track is 0.4 s late with 60 ppm drift. Learn found 324 voice windows, set the threshold to 0.48 (100% of his lines pass, background windows max 0.39) and built a 128-clip eval set. Evaluate gave:

| Model | Mac wake | Mac WER | iPhone wake | Speed | CPU | RAM |
|---|---|---|---|---|---|---|
| Whisper turbo | 19/19 | 29% | 15/19 | 514 ms | 24% | 240 MB |
| Whisper large-v3 | 18/19 | 33% | 13/19 | 735 ms | 18% | 927 MB |
| distil-large-v3 | 16/19 | 50% | 8/19 | 670 ms | 14% | 288 MB |
| Canary 1B v2 | 12/19 | 56% | 6/19 | 826 ms | 74% | 512 MB |
| Parakeet v2 | 13/19 | 58% | 9/19 | 50 ms | 49% | 254 MB |
| Parakeet v3 | 14/19 | 68% | 10/19 | 49 ms | 114% | 233 MB |

- **Merged takes, Whisper turbo:** AuxIVA 18/19 wake with 27% WER, noise reference 18/19 with 32% WER.
- **False wakes:** 0/13 for every model.
- **WER caveat:** WER is measured against Whisper's transcript of the clean clip, so it favours Whisper.

**Cleanup:** I put his voiceprint back (byte-identical to the backup) and left the threshold at the default. I deleted the synthetic session and the eval set. I also cleared a stale test lock (pane w2:p22, armed since 22:40) that would have blocked every send.

### 2026-11-24 06:17 UTC (agent)

Waiting on the owner: run the 45-minute morning test plan in the ticket description (also in ~/Projects/needs-you/docs/morning-test-plan.md), pick the models in Settings, then say yes or no to PS4. The Training section, model switcher and test plan are built and pushed to needs-you main, but no real Training session has been recorded yet.

### 2026-11-24 16:24 UTC (agent)

The owner, 24 Nov: the Training instructions were unclear ("stay quiet for 10 seconds" read like a line to say out loud). Fixed in needs-you 237de05, installed. Now:
- Read lines are shown in quotes, with "Read this out loud, then press Next (space bar)."
- Silent steps show "Don't speak." with a countdown to the next line.
- Free-talk steps show the question with "Answer out loud in your own words", plus a countdown.

### 2026-11-24 17:01 UTC (agent)

Training results, 24 Nov: 3 sessions (Quiet, Music, Game), 165 clips, learned voiceprint threshold 0.55. Evaluate ran with PS4 on.

| Background | Whisper turbo wake caught | Turbo WER |
|---|---|---|
| Quiet | 40/42 | 20% |
| Music | 16/33 | 69% |
| Game | 8/29 | 91% |

0 false wakes for every model. Whisper large-v3 full is about the same as turbo (41/42, 17/33, 8/29) and slower, so turbo stays. Parakeet is much worse with background (Game 1/29).

Next: rerun Evaluate for turbo with PS4 off to see whether PS4 helps or hurts. PS4-on results are saved in training/eval/ps4-on/.

### 2026-11-24 17:13 UTC (agent)

Live issue after Training, 24 Nov 18:10: "Hey Claude" stopped triggering. The lid was closed, so the MacBook mic was silent and Needs You listened on the Brio 100 webcam mic. The voice check scored him at 0.42-0.47 with the Training voiceprint (bar 0.55 set by Training) and 0.24 with the old voiceprint. Interim fix: Training voiceprint plus voiceThreshold 0.35. Wake works now, but one command was cut off as "only other voices" (score dipped below 0.28).

Bugs to fix:
1. Training picks a bar that rejects 18% of his own lines. It should keep at least about 95% of his lines.
2. The voiceprint is mic-specific. Training should record on the mic Needs You actually uses, or store one voiceprint per mic.

Backup of the Training voiceprint: voiceprint-training-20261124.json. debugWake is on.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Training and the model switcher ship in v1.0.0 and later and were used on 24 Nov (3 sessions, 165 clips, Evaluate run). The morning plan is no longer pending, so no owner action is waiting. Of the two bugs: Training now records on the mic Needs You uses (Training.swift uses Prefs.micUID). Still open: the threshold rule ("at most 2 % of background windows") can reject too many of his own lines, and there is one voiceprint for all mics. The threshold is set by hand to 0.35. Nobody is on it, so Backlog.
<!-- SECTION:NOTES:END -->
