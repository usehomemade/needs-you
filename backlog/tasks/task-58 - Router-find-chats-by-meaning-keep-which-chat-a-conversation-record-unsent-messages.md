---
id: TASK-58
title: >-
  Router: find chats by meaning, keep 'which chat?' a conversation, record
  unsent messages
status: In Review
assignee: []
created_date: '2026-11-26T12:55:47Z'
labels:
  - hm-1408
dependencies: []
ordinal: 58000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1408

Owner, 26 Nov 2026, after testing 1.2.0+ in Router Debug:

1. Wrong chat. A message about the voice router's "which chat?" behaviour should go to the Needs You chat. Instead it asked about an unrelated chat. Matching is by name only, and the model invents a "named" phrase ("Claude; working on: …"). Chats must be found by what they are about (title, folder, what each is working on), not only by name.
2. "Which chat?" -> "none of them, it's the X chat" -> "Okay, I didn't send it." Saying none and pointing at another chat must find that chat. It must be a conversation: remember the question and the message, ask a follow-up, and confirm when unsure.
3. Messages that were not sent (cancelled, no chat chosen, not found) must still be recorded in the Needs You history.

## History

### 2026-11-26 13:04 UTC (agent)

Plan agreed with the owner:
1. Find chats by meaning: on-device sentence embeddings over each chat's title, folder, tab and "working on" text. The model is asked which chat the message is about. A name counts only if it is a contiguous phrase of his words. Send only when the model and meaning agree, or meaning has a very clear lead; otherwise ask with the 3 closest chats.
2. "Which chat?" is a conversation with NO round limit: it keeps searching until a chat is found, he says stop or cancel, or he presses Esc twice. "None of them" is not a cancel. Clear fit -> "Send it to X?". Silence -> kept unsent and recorded.
3. Every command is recorded in history with its outcome and the clarify turns.
4. Learning: every successful match saves the message's meaning and the chat. Similar later messages get a weighted vote for that chat, by similarity and recency. This replaces the word-keyed routing memory.
5. Router Debug shows meaning scores and learned votes.

### 2026-11-26 13:18 UTC (agent)

Built (uncommitted), installed locally. swift test: 132 tests, 0 failures.
Dry runs: the owner's failing message now goes to the needs-you chat (meaning 0.44 vs 0.27, very clear). A message where the model was wrong and meaning disagreed asks. "banana chat" -> not found. A topic-only message about another chat sends to it.
New: Meaning.swift / MeaningIndex.swift (NLEmbedding sentence vectors per chat part), RouteLearning(Store) (route-matches.json, 500 newest, similarity + 14-day half-life votes), ClarifyConversation (no round limit), history records every outcome, Router Debug shows meaning + votes.
Not verified: the live voice conversation; learning after a real send. Known gap: chat status/prompts are lost on app restart until each chat reports again. Behaviour change to confirm: a single Esc while it speaks now stops the voice and keeps listening (before: cancel).

### 2026-11-26 14:00 UTC (agent)

Released in v1.3.0 (commit 1e0f80e, release run 45833091952, notarized) and installed on the owner's Mac. Moved to In Review: the live voice conversation is still to be checked.
<!-- SECTION:DESCRIPTION:END -->
