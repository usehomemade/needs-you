---
id: TASK-50
title: >-
  Debug window: every reachable chat/app, and a router playground (type a
  command, see where it would go)
status: Done
assignee: []
created_date: '2026-11-26T09:59:47Z'
labels:
  - hm-1389
dependencies: []
ordinal: 50000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1389
Related: TASK-45 (HM-1374)

The owner, 26 Nov ~10:10: "add a debug viewer to see all the registered chats, and apps etc i can check. and a debug for router, so I'll try different commands and see what the router would do."

## History

### 2026-11-26 10:02 UTC (agent)

Built and installed (branch `hm-1383-router`). Window > Router Debug (⌥⌘D):
* Targets: status (Accessibility, on-device model), connected chats with agent/state/pane/hooks, herdr chats not connected, chat apps (running, MCP or not, spoken names). Show Chat per row.
* Router: type a command (wake phrase optional), Return. Shows targets, app command, matcher, topic, model pick + ms, memory, route log, result and message, name scores. Nothing sent.
* Local builds only (the owner: "shouldn't be on the released version"): hidden when the build has an update feed (Updates.configured).

### 2026-11-26 10:10 UTC (agent)

The owner, 26 Nov 11:06: "what did the agent say on learning to bake bread" → asked between unrelated chats, though the Claude app had "Learning to bake bread" open.
Cause: the router knew the Claude app only as "Claude app"; it never read which chat is open.
Fix: AXDelivery.openChatTitle reads the chat open in a chat app (Claude app: the titled web area "Learning to bake bread - Claude"; native apps: the window title). It is the target's detail, counts for the topic and goes to the model. Debug Targets lists chat apps as targets with "Works on:".
Dry run now: → Claude app (topic). 114/114 tests. Installed.

### 2026-11-26 10:32 UTC (agent)

Not-open chats (the owner: "what about not-opened chats?"): the Claude app's sidebar (Pinned + Recents, up to 15) is read via Accessibility; each chat is a router target (kind desktop, appChat = title). Sending clicks that sidebar chat, waits until its title is the open one, then types.
Dry runs: "in the home network chat, ask if the mesh router is cheaper" → Home network setup; "ask the recipes chat whether oat milk is cheaper" → Weekly recipes: oat vs almond milk; followers → Claude app (open chat). Not yet tested live (would switch the owner's open Claude chat). Only while the sidebar is shown; ChatGPT app not covered.

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.
<!-- SECTION:DESCRIPTION:END -->
