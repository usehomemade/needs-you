---
id: TASK-43
title: >-
  One sentence mixing Turkish, German and English comes out garbled or
  translated
status: Backlog
assignee: []
created_date: '2026-11-25T12:59:45Z'
labels:
  - hm-1372
dependencies: []
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1372
Related: TASK-36 (HM-1362)

The owner, 25 Nov ~14:00 (voice): one language per message works (Turkish, German, English). But when one sentence mixes Turkish, German and English, the transcript comes out as one language (once it came out as English, as if translated). He wants each part kept in the language he spoke it in, in both the subtitles and the transcript.

He also said it's rare ("no one's gonna switch languages so often"), so it's not urgent.

Likely cause: Whisper picks one language per segment. The fix idea is to detect the language per chunk, split at pauses, and transcribe each chunk in its own language.

## History

### 2026-11-25 18:18 UTC (agent)

Status check (two independent checks): Nothing has shipped. WhisperSTT.swift still picks one language for the whole utterance. The per-sentence switching in VoiceRouting only affects spoken replies. Left to do: split speech at pauses, detect each chunk's language, transcribe each chunk in its own language, and join the parts for subtitles and transcript. Test with one Turkish, German and English sentence. Low priority, stays in Backlog.
<!-- SECTION:DESCRIPTION:END -->
