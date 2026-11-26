---
id: TASK-42
title: Clean text before speaking (paths, URLs, code, markdown)
status: Done
assignee: []
created_date: '2026-11-25T12:31:51Z'
updated_date: '2026-11-26T20:16:35Z'
labels:
  - hm-1370
dependencies: []
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1370
Related: TASK-34 (HM-1358), TASK-41 (HM-1369), TASK-39 (HM-1366)

From the TASK-34 (HM-1358) study (idea 3, from Heard `daemon.py:102` and claude-speak `normalizer.py:352`). The owner, 25 Nov: "clean the text: sure, yes".

Inside the app, before TTS:

* Paths become their last part ("Sounds.swift").
* URLs become their domain.
* Code fences become "code block".
* Markdown symbols, backticks and em dashes are dropped.
* Version numbers and units are read naturally.
* Hashes and long ids are dropped.

The subtitles keep the original text.

## History

### 2026-11-25 12:41 UTC (agent)

Merged to main (8d66677) and installed (`SKIP_MODELS=1 scripts/install.sh`, `needs-you status` Ready).

- `SpeechText.spoken()` in `Sources/NeedsYouShared/SpeechText.swift`, applied in `SpeechIO.speech` (every spoken line: ask, say, done, voicemails, summaries) and in `tts-test`. Subtitles and history keep the original text.
- Rules: paths to last part ("Sources/NeedsYou/Sounds.swift" is said "Sounds dot swift"), URLs to domain, code fences to "a code block", backticks/markdown/tables/emoji dropped, dashes to pauses ("3–5" to "3 to 5"), SHAs/UUIDs/long ids dropped, "v1.2.3" to "version 1.2.3", "~50 ms", "630 MB", "%", "→", "≥" read as words. "and/or", "yes/no", "24/7", "e.g.", "11:02 p.m." stay.
- Tests: `SpeechTextTests` (45 rule cases, 16 real lines from history.json that must stay unchanged). Over all 167 agent lines in history.json only 2 change (a trailing space, "CLAUDE.md" to "CLAUDE dot md").
- Check a line without audio: `needs-you clean-test "<text>" --title speech`.

Needs owner: listen live to the next few asks and say if anything sounds wrong.

### 2026-11-25 18:18 UTC (agent)

Done (two independent checks agreed): speech text cleaning is on origin/main of usehomemade/needs-you, inside commit 64a46e7 "Needs You: initial public release" (the original merge 8d66677 was squashed away). Code is in SpeechText.swift with SpeechTextTests.swift, and SpeechText.spoken() is called in Conductor.swift and LocalSpeech.swift. Running the installed binary with `needs-you clean-test` turned paths, URLs, hashes, versions and units into clean spoken text, and the subtitles kept the original text.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. Re-checked on the installed v1.6.0: `needs-you clean-test "<path, URL, hash, version>" --title speech` speaks "main dot swift", "example dot com", drops the hash and says "version 1.6.0". SpeechTextTests passes. Side finding: clean-test without --title speech runs the transcript cleaner, which turned "main.swift" into "main.Swift" and "example.com" into "example.Com".
<!-- SECTION:NOTES:END -->
