---
id: TASK-36
title: >-
  Live subtitles show another script (Hindi-like) at the start when the owner
  speaks Turkish
status: Done
assignee: []
created_date: '2026-11-25T11:30:15Z'
labels:
  - hm-1362
dependencies: []
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1362
Related: TASK-27 (HM-1351), TASK-43 (HM-1372)

The owner (voice, Turkish, 25 Nov ~12:32): the final transcript of his Turkish message was correct, but the live subtitles first showed text in another language and script, "Hindi or something like it".

Likely cause, to check: the first seconds of live subtitles come from a path that isn't limited to his chosen languages (TASK-27 (HM-1351) runs Parakeet, which is English only, for about 3 s, or an unrestricted Whisper language detection on a very short clip). Fix: limit every subtitle and partial pass to the enabled languages, and never show a script that doesn't belong to them.

## History

### 2026-11-25 11:31 UTC (agent)

The owner (voice, 25 Nov ~12:31): subtitles must follow whatever languages he picked, not a hard-coded English + Turkish. Bigger ask: languages shouldn't be fixed at all. If he speaks a language he didn't pick, it should switch to it right away.

Approach:
- Detect over all Whisper languages, with his picked languages as a prior (bonus).
- Show subtitles only once detection is confident, e.g. after about 1.5 to 2 s of speech, with a high top probability and a clear gap to the second.
- Otherwise keep the last confident language.
- The picked list becomes "Languages I usually speak" (preference), plus a switch "Only these languages" for strict mode.
- Measure the false-switch rate on the English eval set, which must stay near zero.

### 2026-11-25 12:51 UTC (agent)

Done on main (merge 2b543dd), installed. Needs owner's live check.

**Cause:** for the first ~3-4 s of a command the subtitles came from Parakeet v2, which only knows English. Turkish came out as English-looking gibberish ("Turchekonushtum Zaman Shuanda and the Abilior Musum"), which reads like romanized Hindi. Whisper only took over once the language check ran (12:29:40, 3.8 s after the wake). The final transcript was right because it always goes through Whisper.

**What changed (his latest spec):**
- Subtitles start at once in the likeliest language: the last one he spoke this session, else his first picked one. Language detection runs alongside from 1.5 s of his words. If it settles on another language, the whole line is re-read in that language and cross-fades in place.
- Detection scores all Whisper languages. Picked ones are weighted 4×. A language counts as found at ≥ 0.8 top probability, ≥ 0.6 ahead of the second, and ≥ 0.9 on its own for a language he did not pick (`LanguagePick`, unit-tested).
- A subtitle is dropped when its script doesn't fit its language (`Script.fits`, e.g. Devanagari while the language is Turkish).
- Settings → Microphones: "Languages I Usually Speak" plus "Only These Languages" (off by default; on = the old strict behaviour).
- Test hook: `needs-you stt-test <audio> --title langpick:wturbo@en/tr` (a final `!` = strict).

**Numbers:**
- Time to the first subtitle word after the wake, English command clips: p50 0.50 s, p90 0.59 s (n=29, final run); p90 1.14 s in an earlier run (n=42). Target was p50 < 1 s, p90 < 1.5 s.
- Turkish, German and French (his "Hey Claude" plus synthetic speech, 12 clips): p50 1.22 s, p90 1.39 s, max 1.52 s. When the assumed language was wrong it switched every time: tr, de and fr each found "clear" at 1.5 s of speech.
- False language switches on the English eval set (147 clips × 2.5 s / 4 s / full = 441 decisions):
  - Picked en+tr: 0 switches to an unpicked language. 1 clip ("Hey Claude, done." over music) went to Turkish, the same clip HM-1351 already flagged.
  - Picked en only: 0 switches.
- Auto-switch with only en+tr picked: German and French clips detected as de / fr, clear at 1.5 s (top ≥ 0.995). With "Only these" on they stay English, as expected. Full transcripts come out in German and French.
- Turkish: found clear from 1.5 s (1.0 s is too short and stays unsure, as designed).

### 2026-11-25 12:59 UTC (agent)

The owner, 25 Nov ~14:00, live test: "when I speak Turkish you understand me, when I speak German you understand me". A full Turkish sentence came through as Turkish. The leftover mixed-languages-in-one-sentence case is tracked in HM-1372.
<!-- SECTION:DESCRIPTION:END -->
