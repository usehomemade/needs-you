---
id: TASK-28
title: '"do not disturb" by voice, with voicemails when the owner is back'
status: To Do
assignee: []
created_date: '2026-11-24T19:43:09Z'
labels:
  - hm-1352
  - needs-owner
dependencies: []
ordinal: 28000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1352
Related: TASK-31 (HM-1355)

The owner (voice, 24 Nov 20:50): "add a setting to pause all voice activity". Then, in detail:

* He can pause by voice: "Hey Claude, I'm going to take a shower" or "good night" turns on do-not-disturb. There's also a switch in the menu bar and Settings.
* While it's on, the app enforces it. No agent can speak, make sounds or open the mic, even one that forgot. `needs-you ask/say` returns at once with a clear status ("The owner is busy, left as a voicemail"), so the agent goes on with other work.
* Everything agents wanted to say is stored as a voicemail with time, project/chat and text.
* "Hey Claude, I'm back" or "Hey Claude, good morning" turns it off. Needs You then reads the voicemails aloud in order ("Hey <name>, it's 2 a.m. I worked on X, but I need your input on Y"), and he can answer each one, which goes back to that agent's conversation.
* "What did you work on last night?" gives a spoken summary of the voicemails and finished work.
* "Good night" mode stays on until he says good morning or turns it off. It has no timer and nothing can bypass it.

## History

### 2026-11-24 19:51 UTC (agent)

The owner (voice, 24 Nov 20:58): when an agent asks something and he doesn't answer, don't repeat it a second time. Ask once, then put it straight into voicemail. That replaces today's "two tries, then artifact" in `needs-you ask`.

### 2026-11-24 20:52 UTC (agent)

Do not disturb with voicemails is in (commit 2914d8f on main; the app now runs main including the island merge).

**Turn it on:** "Hey Claude, good night", "I'm going to take a shower", "do not disturb", "be right back", or the Do Not Disturb switch in the menu bar / Settings. The menu bar icon turns into a moon. There is no timer, and it stays on after a restart.

**While it is on:** `ask`, `say` and `done "<words>"` return at once with `status: "voicemail"` (exit 2) and "The owner is busy (do not disturb), left as a voicemail…". Nothing is spoken, no sound plays, the mic stays closed. Asks that were already waiting in the queue check again when their turn comes. Each voicemail keeps the time, folder, herdr pane, title and text.

**Turn it off:** "Hey Claude, I'm back" or "Good morning". It greets you ("Good morning, <name>"), then reads the unheard voicemails in order ("At 2 a.m., from homemade: …"). After each one you have 8 s to answer, and the answer is typed into that agent's chat (its herdr pane, else the one chat in its folder). Silence or "next" moves on; "stop" or "that's all" keeps the rest for later.
- "What did you work on last night?" gives a spoken summary per chat.
- "Good morning, what did you work on last night?" gives the summary, then the voicemails.
- "Play my voicemails" / "any messages?" reads the unheard ones; the menu bar and Settings also have Play Voicemails.

**Ask once:** `ask` no longer asks twice or publishes an artifact. With no answer it keeps the question as a voicemail (`status: "voicemail"`, exit 2). `--once` is unchanged (`no_answer`, no voicemail). CLI help, README and AGENTS.md are updated.

**Tests, all silent:**
- `swift test`: presence phrases, including "this one: write a good night message" still going to the chat.
- `wake-test --transcript` dry runs for each phrase.
- `voice-test --title dnd:selftest`: muted ask and say through the real path. Under do not disturb both returned `voicemail` in 1 ms; an unanswered ask without it returned `voicemail` after one try (1 agent turn); the stored voicemails, spoken lines and summary were checked, then cleaned up.

**Wake bench** on the merged build: 29/35 caught, median 0.73 s (before today: 29/35, 0.72 s); 0/61 false wakes.

**Needs you:**
- Your `~/.claude/CLAUDE.md` Needs You block still says "Exit 2: he did not answer twice; an artifact … is published". Copy the new line from AGENTS.md.
- Not yet live-tested by voice: good night → an agent asks → good morning → answer a voicemail.

### 2026-11-25 00:24 UTC (agent)

Waiting on the owner: say "Hey Claude, good night", have an agent run needs-you ask, then say "good morning" and answer the voicemail to confirm it reaches that chat. Also delete the old Needs You block in ~/.claude/CLAUDE.md (needs-you.md already has the new text). Do not disturb with voicemails and ask-once are built, merged to main (2914d8f) and installed. The live voice test has not been done yet.
<!-- SECTION:DESCRIPTION:END -->
