---
id: TASK-47
title: >-
  On-device model routes every voice command (new chat in an app, "use ChatGPT
  to ask…", topic → chat)
status: Done
assignee: []
created_date: '2026-11-26T08:34:38Z'
labels:
  - hm-1383
dependencies: []
ordinal: 47000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1383
Related: TASK-45 (HM-1374), TASK-53 (HM-1396), TASK-52 (HM-1395), TASK-49 (HM-1385)

The owner, 26 Nov 09:33. He wants to say things like:

* "Hey Claude, create a new chat on Claude desktop, ask what's the weather like"
* "Hey Claude, use ChatGPT to ask how my business is doing"
* "Hey Claude, how is the homemade linter going" → the connected herdr Claude Code chat working on the linter, with no name or colon.

The on-device Apple model (FoundationModels) should be the router: it reads what he said plus every reachable chat and app, and returns one intent (send to a chat, new chat in an app, new chat in a project folder) plus the message to send. The agent on the other end picks it up.

What works today (checked in code, 26 Nov):

* New chats only open as a herdr tab running claude CLI. "New chat on Claude desktop" is not supported; the Claude app and ChatGPT only get typed into the chat already open there.
* "use ChatGPT to ask …" does not parse as a name. The model is consulted only when the regex matcher is unsure, and when it disagrees with the chat in front Needs You asks "which chat?". The whole sentence including "use ChatGPT to ask" would be sent.
* "how is the homemade linter going" goes to the chat used last unless the model and routing memory agree on another, otherwise it asks.

### Agent notes
* Router: Sources/NeedsYou/Router.swift (parseSmart), ModelRouter.swift (Pick only), ChatMatcher.swift, RouteJudge.
* Apps: Router.chatApps (Claude app, ChatGPT), AXDelivery types into them.
* New chats in apps: open the app, Cmd+N (or its New chat menu item via AX), wait for the empty-session check (AXDelivery.desktopShowsNewSession), paste.

## History

### 2026-11-26 08:39 UTC (agent)

Built in worktree `a worktree (needs-you-hm1383)` (branch `hm-1383-router`, not committed yet). 107/107 unit tests pass, including new AppCommandTests and TopicTests.

What changed:
* "new chat on Claude desktop, ask …", "use ChatGPT to ask …", "ask ChatGPT …", "open ChatGPT and start a new chat …" → new chat in that app (opens the app if needed, presses its New Chat menu item or Cmd+N, waits for an empty chat, pastes, Return). Apps without the Needs You MCP get no voice line and stay in front.
* On-device model now returns chat + newChat + message. A model pick that agrees with the message's topic words (ChatMatcher.topic) sends without asking ("how is the homemade linter going").
* `needs-you wake-test --transcript "…"` now dry-runs the live router (matcher + model + memory) over real targets and returns the route log.

Waiting on the owner: installing the build restarts his running app; the auto-mode check blocked `scripts/install.sh`. Not verified live yet.

### 2026-11-26 08:42 UTC (agent)

Installed (the owner ran install.sh). Dry runs on the live router, nothing sent:
* "create new chat on claude desktop, ask whats the weather like" → app_new_chat, Claude app, "whats the weather like."
* "use chatgpt to ask how my business doing" → app_new_chat, ChatGPT, "how my business doing."
* "how does the homemade linter going" → only 2 chats are registered right now and no linter chat among them; it picked the home-folder chat (model and topic agree).
* Added "start a ChatGPT conversation about …" phrasing (unit-tested, not yet installed).

Not yet tested: a real send (opens a new chat in the app and types into it).

### 2026-11-26 09:10 UTC (agent)

The owner, 26 Nov 10:00: "send a text message to atlas terminal" went to the home-folder chat. Cause: unconnected herdr chats were not targets once any chat registered, and a no-name message fell back to the chat used last.

New rule (the owner: "router should not send to any chat that it finds"; a clearly matching recent chat should not ask):
* Named and clear → send. "to the X terminal/chat" counts as a name.
* Topic clearly points to one chat → send (model or memory must not disagree).
* Ties, unclear, no name → ask. The chat used last is never a fallback.
* A name that matches nothing → says "I can't find a chat called X. Connect it, or say new chat in X." Nothing sent.
* Unconnected herdr chats are targets again.

Installed. Dry runs: atlas → asks between the two atlas chats; "how is the trip planning going" → trip planner chat; "banana terminal" → can't find; "ask homemade lint …" → asks (no linter chat is open now). 113/113 tests.

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.

### 2026-11-26 11:45 UTC (agent)

Router: hardcoded word lists and app names removed (uncommitted on main, installed locally).

- Chat-name words ("claude", "code", "codex", "request"…) now weigh 1 / the number of chats that contain them, computed from the chat names. Used in the name match, the topic match and the "which chat?" answer.
- Removed: genericWords, refuses(), chatNamed(), "claude/code/codex" in stopwords and junkLabels, the Router.chatApps list (Claude app, ChatGPT aliases), ChatGPT examples in the model prompt.
- Chat apps come only from layout discovery; apps it has found are remembered so a closed one can still be opened.
- The "which chat?" answer is matched against every chat, so "none of them, the printer one" works.
- Sidebar cap of 15 removed.

Proof: 122 tests pass. Dry runs: trip planner → Weekend trip planner; router costs → Home network chat (before topic change); banana → no such chat; printer setup help → Printer setup help (11:36, Claude window open). With the Claude window closed (11:45) it asks instead of guessing.

Explainer: [private preview link removed]
<!-- SECTION:DESCRIPTION:END -->
