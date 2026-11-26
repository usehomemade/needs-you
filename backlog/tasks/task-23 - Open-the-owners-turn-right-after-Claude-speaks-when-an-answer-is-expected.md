---
id: TASK-23
title: Open the owner's turn right after Claude speaks when an answer is expected
status: Done
assignee: []
created_date: '2026-11-24T19:28:11Z'
updated_date: '2026-11-26T20:07:59Z'
labels:
  - hm-1347
dependencies: []
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1347

The owner (voice, 24 Nov 20:27): it should feel like a conversation, not "Hey Claude" every time. When Claude finishes speaking and expects an answer (a question, a choice), start listening to him right away without the wake word. When Claude has nothing to ask, end the turn and go back to waiting for "Hey Claude".

Covers both the CLI path (`needs-you say` listening by default when the reply asks something) and the in-app Hey Claude conversations.

## History

### 2026-11-24 19:31 UTC (agent)

Works today with no code change: when the agent's reply asks something, it uses `needs-you ask`/`say` (listens right after speaking), otherwise `say --no-listen`/`done`. Proof: voice conversation 20261124-202815-4014. The agent asked, the mic opened without the wake word, and the owner answered twice ("Yeah, exactly", then the next requests). The owner confirmed this is the behaviour he wants.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 check: Still works. history.json has asks answered by voice on 25 and 26 Nov without a wake phrase.
<!-- SECTION:NOTES:END -->
