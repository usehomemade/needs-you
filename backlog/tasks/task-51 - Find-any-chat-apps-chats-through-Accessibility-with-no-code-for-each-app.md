---
id: TASK-51
title: Find any chat app's chats through Accessibility, with no code for each app
status: Done
assignee: []
created_date: '2026-11-26T10:36:40Z'
updated_date: '2026-11-26T20:16:36Z'
labels:
  - hm-1394
dependencies: []
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1394
Related: TASK-45 (HM-1374)

The owner, 26 Nov: "we keep adding app-specific code. isn't there a universal way? the agent discovers these by itself?" → yes.

Goal: replace the Claude-app-only sidebar reader (Pinned/Recents/"rename session") with one generic reader:

* Open chat: window title or titled web area, minus " - <App>".
* Chat list: the longest evenly spaced column of text buttons/rows beside the message field, found from geometry.
* Opening one: AXPress the row, wait for the title to change.
* Unclear shape: the on-device model picks which labels are conversations, cached per app.
* Router Debug shows what was found per app.

## History

### 2026-11-26 10:42 UTC (agent)

Generic reader in (ChatListFinder + AXDelivery.scanApp): no Pinned/Recents/rename-session/Claude-only code. Same rule finds the Claude app's 22 chats and the ChatGPT app's 20 (includes its "Playground" project row). Electron apps build their tree only when asked: the first scan after launch is empty, later ones work. 118/118 tests.
Still app-specific: the list of which apps are chat apps (bundle ids + spoken names). Discovering it automatically would also pick up Slack, Linear and Messages (message field + list) → voice could send to real people. Asked the owner.

### 2026-11-26 10:50 UTC (agent)

Discovery (the owner: "discover them automatically… they should be just ready"): AppDiscovery reads every running app at launch, on app launch/activate and every 5 min; a chat app = message field ≥250 wide below the middle of a chat column of ≥3 (ChatListFinder.isChatLayout). Run on this Mac: Claude app ✓ (22 rows), ChatGPT ✓ (20), 1Password ✗ (search above list), Chrome ✗, Ghostty ✗, Finder ✗. Slack/Messages/Linear had no window open, not checked. 123 tests.

### 2026-11-26 10:58 UTC (agent)

Pushed to main as a871ccd (together with the unpushed HM-1374 commits). Release workflow run 45806237936 is building, signing and notarizing; Done once the release is published and the app updates to it.

### 2026-11-26 11:16 UTC (agent)

Released in Needs You v1.1.0 (tag v1.1.0, commit 8fbd5cb, release run 45807779219 succeeded). Appcast lists 1.1.0 (build 29) with NeedsYou-1.1.0.zip; DMG and zip attached. First run 45806237936 failed: the release compiler timed out type-checking a tmux expression from HM-1374; split up in 8fbd5cb.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. Released in v1.1.0, installed app is v1.6.0. ChatListFinderTests and AXMatchTests pass.
<!-- SECTION:NOTES:END -->
