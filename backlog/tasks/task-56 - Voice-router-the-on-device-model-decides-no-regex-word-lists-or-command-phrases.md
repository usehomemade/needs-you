---
id: TASK-56
title: >-
  Voice router: the on-device model decides; no regex, word lists or command
  phrases
status: In Review
assignee: []
created_date: '2026-11-26T11:49:28Z'
labels:
  - hm-1399
dependencies: []
ordinal: 56000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1399

The owner, 26 Nov: "no regex/hardcode/command phrases are wanted. llm should decide what to do."

The on-device model reads every "Hey Claude…" command and decides: which chat, a new chat (in which app or project), a name that matches no chat, and the message. It also reads the answer to "which chat?". Code only checks the model's pick against data (word rarity across your chat names, routing memory) and asks when they disagree. Pressing 1 to 4 stays.

Remove: AppCommand patterns, toChat/tellChat/newChat/thisOne patterns, colon parsing, topicFiller, stopwords, junkLabels, number/yes/no word lists.

## History

### 2026-11-26 12:02 UTC (agent)

Built and installed locally (uncommitted on main).

- The on-device model now reads every command: send, new chat, away, good night, back, voicemails, summary, list chats. IntentJudge checks its pick against data (rare words of chat names, routing memory). A name the model reports counts only with the words he actually said.
- Removed: AppCommand patterns, ChatMatcher route/regex patterns, the colon parsing, PresenceCommand patterns, topicFiller, stopwords, junkLabels, number/yes/no word lists, RouteJudge. Pressing 1 to 4 still works.
- Without a model, only data can send: a topic with two rare words in common, or routing memory. Everything else asks.
- Test fixtures, comments and docs now use made-up chat names (public repo).

Proof: 108 tests pass. Dry runs: trip planner sends to the trip planner chat. "how is the atlas going" asks between the two atlas chats. "banana terminal" says no such chat. "new chat in ChatGPT" opens a new ChatGPT chat. "good night" turns on do not disturb. "list my chats" lists the chats. "how are you doing" asks.

### 2026-11-26 12:12 UTC (agent)

Public history rewritten with the owner's approval. git filter-repo replaced personal chat titles and names in every commit with made-up ones.

- Force-pushed the tags first, then main. main 8fbd5cb → f37c7f1; v1.0.0 → 18445b8, v1.0.1 → a30adf3, v1.1.0 → f37c7f1.
- No new release run (the latest run is still the 11:08 one). Releases 1.0.0–1.1.0 are unchanged; their notes held no personal data.
- Check: `git log origin/main --tags -p` has 0 hits for the old terms. 108 tests pass on the local checkout.
- The local checkout is on the new history and its uncommitted router work is restored. A backup stash of the pre-rewrite state stays local.
- GitHub may keep the old commits reachable by SHA until GC; purging them needs GitHub Support.

### 2026-11-26 12:19 UTC (agent)

Status check (two independent checks): The router change is now committed and pushed to origin/main of usehomemade/needs-you as 14554c4. No release contains it yet. Release run 45817637324 was still in progress, and the latest release is v1.1.0 (f37c7f1).

Left to do:
1. Release run 45817637324 finishes green and publishes a release (1.1.1 or 1.2.0) with 14554c4.
2. Install that release and try a few "Hey Claude" commands.
3. Optional cleanup: `Router.pick` (Router.swift:422-431) is unused and still holds an ordinal word list. The next/skip/stop regex in Conductor.swift:1221-1225 (voicemail reading) may also fall under the no-word-lists rule. Decide on both.

Then move to Done with the release tag.

### 2026-11-26 12:23 UTC (agent)

Released as v1.2.0 (commit 14554c4, run 45817637324 green in 8m51s; DMG notarized). Installed on the owner's Mac at ~/Applications/Needs You.app, version 1.2.0 build 30, running. Waiting on real voice use before Done.
<!-- SECTION:DESCRIPTION:END -->
