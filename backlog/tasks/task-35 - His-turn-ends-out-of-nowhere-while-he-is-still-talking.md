---
id: TASK-35
title: His turn ends out of nowhere while he is still talking
status: Done
assignee: []
created_date: '2026-11-25T11:22:52Z'
updated_date: '2026-11-26T20:08:01Z'
labels:
  - hm-1360
dependencies: []
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1360
Related: TASK-39 (HM-1366)

The owner (voice, 25 Nov 12:21): "it stops sometimes like out of nowhere even though I keep talking."

Example from today, 11:21 UTC: his message arrived as only "I think I like." The rest ("...the minimal and Apple style...") came as a separate message.

## History

### 2026-11-25 11:28 UTC (agent)

Second case, 25 Nov 11:27 UTC: his voice message ended at "right now when I try to." He confirmed he was still talking: "I actually spoke and you listened, so that might be a bug."

### 2026-11-25 12:51 UTC (agent)

Fixed on main (merge 2b543dd), installed, app running. Needs owner's live check.

**Cause (from the wake debug log, no audio was saved):**
- 12:21:29 "Hey Claude, I think I like" was a wake command, not an answer. Silero heard no speech after the wake (debug: `quiet=2.0s` at −35 dB, speaker check "0.0 s speech"), so the "nothing said after the wake" limit (2.5 s) ended it at 2.5 s while he was mid-sentence.
- 12:28:06 "...because right now when I try to." Speech stopped, and after 1.5 s Smart Turn said "finished" even though the sentence ended on "to".
- History (last 200): 4 clear cut-offs in 2 days, each followed within a minute by him repeating or continuing: 25 Nov 11:21 and 11:28, 24 Nov 19:42 "Also add a setting to pause.", 23 Nov 20:35 "Okay, I'm gonna pause in the middle." (cut off, he says so in the next turn).
- Bench repro: a 2 s thinking pause right after "Hey Claude, this one:" ended the turn every time (old build).

**Fix:**
1. When a pause would end the turn (Smart Turn says done, or the pause hits the limit), the last 8 s are re-read (Parakeet, ~60 ms; capped at 0.8 s). If the thought is left open, the turn gets 2.5 s more. "Open" means it ends on a filler, a joining word or a preposition ("and", "um", "like", "to", "I think", "I like"), on ",", "…" or ":", or only the chat name has been said so far. `TurnText.trailsOff` has unit tests. This covers commands and ask answers.
2. The "nothing said after the wake" limit went from 2.5 s to 4 s. Before ending, the recognizer reads what came after the wake phrase. If it hears words, the turn stays open even when Silero missed them.
3. The debug log now says why each turn ended ("Smart Turn 0.98 after 1.5 s pause", "pause kept open, the thought is not finished: Merge it into", ...).

**Numbers (silent `wake-latency:cmd` bench, his eval command clips, settings 1.5 s / 3 s):**
- Finished commands, time from end of speech to end of turn: median 2.05 s before, 2.02 s after. 0 early cuts before and after.
- Mid-sentence pause test ("Hey Claude, this one: merge it into … next and promote it"), pauses of 2.5, 3 and 4 s: all 3 kept open, full command delivered.
- Thinking pause of 2 to 2.5 s right after "this one:": cut before. After: kept open when the transcript is only the chat name.
- One caveat: when the cut lands where the words read as a finished command ("this one, stop."), the turn still ends. That is by design.
- Two bench runs lost batches because another agent reinstalled the app mid-run, so the after numbers cover 30 to 42 of the 51 woken clips.

### 2026-11-25 12:59 UTC (agent)

The owner, 25 Nov ~14:00, live test by voice: "when I pause you wait for me, it's cool, it is all cool." Verified.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: TurnText.trailsOff ships in v1.0.0 and later (TurnTextTests). Live wake debug log on 26 Nov shows "pause kept open, the thought is not finished" during real commands.
<!-- SECTION:NOTES:END -->
