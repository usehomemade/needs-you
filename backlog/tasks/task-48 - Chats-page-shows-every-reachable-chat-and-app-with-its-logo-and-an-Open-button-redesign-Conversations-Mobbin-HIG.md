---
id: TASK-48
title: >-
  Chats page shows every reachable chat and app with its logo and an Open
  button; redesign Conversations (Mobbin/HIG)
status: Done
assignee: []
created_date: '2026-11-26T08:34:39Z'
updated_date: '2026-11-26T20:16:36Z'
labels:
  - hm-1384
dependencies: []
ordinal: 48000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1384
Related: TASK-45 (HM-1374)

The owner, 26 Nov 09:33, with a screenshot of the main window.

* Chats page: show every place voice can reach (connected terminal chats, Claude app, ChatGPT, Cursor…) with the app's own icon, and a way to open/jump to the chat or terminal.
* Redesign the Conversations page using Mobbin references and Apple's HIG (sosumi).

## History

### 2026-11-26 08:49 UTC (agent)

The owner, 26 Nov 09:49: redesign the whole main window too (sidebar with Conversations/Voicemails/Chats/Projects, list, empty detail). Started.

### 2026-11-26 08:57 UTC (agent)

Built and installed (branch `hm-1383-router`, not committed). Direction: three-column inbox where each row leads with who it came from (Quo, Plain, Front on Mobbin).

* Conversation rows: agent's app icon + project folder as the bold line; the title shows only when it isn't the first words of the preview; outcome kept.
* Projects: only real folders, merged ("Needs You" = "needs-you"), with counts. Chat titles no longer appear there.
* Chats: Claude/Codex/Cursor logo with the terminal app as a small badge, a Show Chat button per row and in the toolbar (focuses the herdr/tmux pane, then the app). New "Chat Apps" section (Claude app, ChatGPT) with Open.
* New conversations record their agent; older ones show a plain bubble icon.

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. Released in v1.1.0, installed app is v1.6.0. ChatsTests passes.
<!-- SECTION:NOTES:END -->
