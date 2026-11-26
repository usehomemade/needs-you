---
id: TASK-9
title: Replace ElevenLabs with local speech models (TTS and STT)
status: Done
assignee: []
created_date: '2026-11-23T18:32:09Z'
labels:
  - hm-1321
dependencies: []
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1321
Related: TASK-39 (HM-1366)

The owner, 23 Nov (by voice, after the barge-in live test): get rid of ElevenLabs. Find good local models that are cheap on compute (Hugging Face or elsewhere) for both text-to-speech and speech-to-text, install them, and use them so there is nothing to pay and replies come faster. He thinks he liked some recent models on his X account. Research the latest releases online and try them.

Today, ElevenLabs does the voice (TTS) and the transcript of his answers and Hey Claude commands. Wake-word and "Stop, Claude" detection already run on the Mac (Apple SpeechAnalyzer).

## History

### 2026-11-23 19:13 UTC (agent)

Done, installed and checked live with the owner. Commit 2e30fea on usehomemade/needs-you main.

**What changed:** speech to text is now Parakeet TDT 0.6B v2 and text to speech is Kokoro af_heart, both through FluidAudio 0.18.3. The owner's name gets a custom lexicon entry. Nothing goes to the cloud. The owner said "remove ElevenLabs", so it is gone: the code, the Keychain item and the install key step. If local speech fails, macOS's own voice speaks.

**Before (ElevenLabs) vs after (local):**
- Word error on the owner's 4 real clips (33 words): 6.1% before, 9.1% after. Apple SpeechAnalyzer also scores 9.1%. The main local miss: "<name> here" → "Two share".
- End-of-turn transcription: about 800 ms before, about 70 ms after.
- Short line spoken: 185–500 ms before, 85–90 ms after. Long line: about 410 ms before and after.
- Stop detection: Parakeet re-reads the last 2 s every 250 ms next to SpeechAnalyzer fast mode. Both fire within about 0.1 s of the end of the phrase. Live, "Stop" cut the voice off.
- Synthetic accented or noisy set: 21% word error before, 37% after. This is the known weak spot.
- Resources: about 33 MB and 4% CPU when idle, about 275 MB plus the Neural Engine while talking. Models unload after 10 idle minutes. Disk: 630 MB, downloaded at install.
- The owner on the voice: "Sounds good actually."

**Still open:** ELEVENLABS_API_KEY in the team's secret store can be deleted.

### 2026-11-23 19:33 UTC (agent)

The owner approved deleting the old ElevenLabs key. ELEVENLABS_API_KEY was removed from the team's secret store (23 Nov). Nothing in the needs-you repo references it. Revoking the key in the ElevenLabs dashboard is up to the owner.
<!-- SECTION:DESCRIPTION:END -->
