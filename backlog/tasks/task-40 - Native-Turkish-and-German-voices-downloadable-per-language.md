---
id: TASK-40
title: Native Turkish and German voices (downloadable per language)
status: In Review
assignee: []
created_date: '2026-11-25T11:49:16Z'
labels:
  - hm-1368
dependencies: []
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1368
Related: TASK-39 (HM-1366)

Needs You speaks every language with Kokoro's English voices, so Turkish and German sound like English reading foreign words (the owner, 25 Nov, by voice).

Goal:

* Speak Turkish and German (and the other "Languages I Speak") with a real native voice.
* Kokoro stays the English voice.
* Add a second local TTS model with tr/de voices (Piper is the first candidate; pick by quality on the Mac, all local, no cloud).
* Voices are not bundled: Settings → Voice lists languages; each voice downloads on first use (like the speech models), with size shown and a delete button.
* Pick the voice per sentence from the text's language (NaturalLanguage detection), so a mixed reply switches voice.
* macOS voices (Yelda, Anna) only as a fallback when a download is missing or fails.
* Speech recognition already handles Turkish (HM-1351); no change there.

## History

### 2026-11-25 11:49 UTC (agent)

Build agent started (opus) in worktree .worktrees/hm-1368.

### 2026-11-25 12:18 UTC (agent)

Status check (two independent checks): Work started but nothing is merged to main. The worktree .worktrees/hm-1368 has uncommitted changes (LocalSpeech.swift modified; new NativeVoices.swift, VoiceRouting.swift, WAV.swift, VoiceRoutingTests.swift) and no commits. Left to do: finish the tr/de voice engine and per-sentence routing, build the Settings → Voice download, size and delete UI, add the macOS voice fallback, then commit, verify Turkish and German on the Mac, merge to main and ship a release.

### 2026-11-25 12:26 UTC (agent)

PR is up, moved to In Review: https://github.com/usehomemade/needs-you/pull/1

Voice samples to listen to (artifact): [private preview link removed]. It has the same Turkish and German lines from every engine I compared, plus the mixed reply.

Picked Supertonic-3 instead of Piper. It is already in FluidAudio (CoreML, Neural Engine). One 162 MB model covers tr, de, fr, it and ru, it has 10 speakers (default Female 2), and it needs no new runtime or GPL espeak.

Measured on the M5 Pro, warm: 0.05 s for a short line, 0.09-0.11 s for two sentences, 0.29 s for an en+tr+de+en reply. First call in a new process takes 0.2 s. Right after the download, CoreML compiles once, which takes about 5 s.

Compared against:
- Piper via sherpa-onnx: 0.03-0.06 s / 0.1-0.18 s. Costs 63 MB per voice plus a 30 MB runtime. sherpa-onnx 2.x dropped espeak, so it would mean pinning 1.12.
- OmniVoice: 1.5 GB, 0.8 s, and a random speaker each time.
- Chatterbox: 2.5 GB, 2.7 s, needs a reference clip.
- macOS Yelda/Anna: 0.6-1.3 s.

Whisper read back every Supertonic line correctly except the loanword "Staging".

Routing: on the 203 agent messages in history.json, 202 stay English. The one tr+de test message splits correctly.

Proof is in the PR (engines per part). The fallback to Yelda/Anna is proven with `--title fallback` and first use.

### 2026-11-25 12:28 UTC (agent)

The owner approved the voices by voice (25 Nov). PR #1 squash-merged to main at 1f06483. Supertonic-3 for tr/de/fr/it/ru, downloaded per language; Kokoro stays English; macOS voices as fallback. Worktree removed.

### 2026-11-25 12:28 UTC (agent)

Back to In Review: merged to main (1f06483) but not yet in a released, installed build. Done once the release with it is installed and Turkish/German speak on the owner's Mac.
<!-- SECTION:DESCRIPTION:END -->
