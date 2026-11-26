---
id: TASK-25
title: Custom wake phrase (default "Hey Claude")
status: To Do
assignee: []
created_date: '2026-11-24T19:30:25Z'
labels:
  - hm-1349
  - needs-owner
dependencies: []
ordinal: 25000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1349
Related: TASK-27 (HM-1351)

The owner (voice, 24 Nov 20:30): he wants to set the wake phrase himself, with "Hey Claude" as the default, so he can try other phrases (his example: "Hey Baby").

## History

### 2026-11-24 20:17 UTC (agent)

Wake phrase setting is in (commit a5fe8c0 on main, installed, app restarted).

**How to change it:** Settings → Hey Claude → Wake phrase. Type e.g. "Hey Baby", press Return or Use. "Back to Hey Claude" resets. The field warns while you type (under 2 words and 3 syllables, a 1-2 letter last word, common talk like "hey you" / "thank you" / "hey Siri", over 4 words). **Test** listens for 20 s and shows what was heard and "matches" / "no match"; a wake during the test only chimes, nothing is sent.

**Matching**
- "Hey Claude" keeps today's hand-tuned patterns exactly (same regexes, same "Hey Cl…" early wake).
- Other phrases: built from the words. Greetings swap freely (hey/hay/hi/okay; "Pay"/"They"/"A" at a sentence start). Each word is compared by a small phonetic key + edit distance + syllable count, with one mishearing allowed in the last word, and two words heard as one ("Heybaby") count. For "Hey Baby": "Hey Bobby", "hey babies", "Pay baby" wake; "Hey, maybe later", "Hey Bob", "hey bae", "the baby is asleep" do not. "Hey babe" wakes only once your voice is learned.
- Early wake on a partial: the phrase with the first 2-3 letters of its last word ("Hey Ba…"), only when the last word has 4+ letters and your voice is learned.
- The phrase goes to SpeechAnalyzer as a contextual string and into Whisper's prompt.
- "Stop, Claude" always works; with another phrase "Stop, <name>" ("Stop, Baby") works too.
- Training and Learn My Voice lines use the phrase. Evaluate scores each old clip against the phrase it was recorded with.

**Bench** (35 wake + 61 non-wake clips, `voice-test --title wake-latency`):
- Before: 29/35 caught, median 0.72 s after speech end; 0/61 false wakes.
- After: 3 runs, 28/35 at 0.83 s, 28/35 at 0.80 s, 29/35 at 0.73 s; 0/61 false wakes.
- The default phrase runs the same regexes as before, so the spread is run-to-run noise: the same build moved 1 clip and 0.1 s between runs (clip 6 woke in one run at 5.66 s and missed in another).

Unit tests: `swift test` (matcher table, incl. "hey, close that" never waking for "Hey Claude").

**For you to try live:** phrases with a 2-syllable name of 4+ letters work best ("Hey Baby", "Hey Jarvis", "Okay Computer"). Avoid short names ("Hey Bob") and phrases said on TV.
<!-- SECTION:DESCRIPTION:END -->
