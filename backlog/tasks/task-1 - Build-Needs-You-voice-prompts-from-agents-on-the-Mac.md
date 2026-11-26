---
id: TASK-1
title: 'Build Needs You: voice prompts from agents on the Mac'
status: Done
assignee: []
created_date: '2026-11-23T16:41:38Z'
updated_date: '2026-11-26T20:07:56Z'
labels:
  - hm-1309
dependencies: []
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1309

The owner 23 Nov: whenever an agent needs him, it speaks through the Mac with ElevenLabs, turns on the mic and listens for his answer (ElevenLabs speech to text). No reply in 30 s: try once more. Still nothing: create an artifact about what was needed. Follow-up questions keep going by voice. Simple Swift GUI app, repo usehomemade/needs-you. ElevenLabs key stored in the team's secret store.

## History

### 2026-11-23 16:50 UTC (agent)

Installed and verified. Repo usehomemade/needs-you (main, 000bfe5), app at ~/Applications/Needs You.app, CLI at ~/.local/bin/needs-you, key from the team's secret store in the app's Keychain item.

Proof:
- TTS + STT with a generated sample: "Hi, <name>. The deploy needs your approval…" came back word for word.
- ask / say / done loop and the queue (second ask waited) work.
- No-answer path: two tries, then [private preview link removed] and a notification, exit 2.
- Live test with the owner: he said "hello. Can you hear me?", which came back as the transcript, exit 0.

### 2026-11-23 16:51 UTC (agent)

Reopened: the owner wants his name said right (the right pronunciation). Adding an ElevenLabs pronunciation dictionary in the app and changing the transcription key term to the owner's name.

### 2026-11-23 16:52 UTC (agent)

Name fix shipped (44f576a, reinstalled with the same signing). The app now creates its own ElevenLabs pronunciation dictionary on first use, with IPA phoneme rules that make the owner's name sound right. TTS moved to eleven_flash_v2, because flash_v2_5 ignores phoneme rules and dropped the name in tests. The transcription key term is now the owner's name. Proof: the app rendered "Hi <name>, quick question.", scribe_v3 transcribed it back as "Hi, <name>. Quick question.", and the clip played once at low volume. Two test dictionaries (needs-you-test-phoneme/alias) remain in the ElevenLabs account: the API answers DELETE with 405.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still accurate in spirit, details superseded. ElevenLabs was replaced by local models (TASK-9). "Ask twice, then artifact" was replaced by ask once plus voicemail (TASK-28). ask/say/done ship in every release (v1.0.0 to v1.6.0, installed 1.6.0). history.json shows agent asks answered by voice on 25 and 26 Nov.
<!-- SECTION:NOTES:END -->
