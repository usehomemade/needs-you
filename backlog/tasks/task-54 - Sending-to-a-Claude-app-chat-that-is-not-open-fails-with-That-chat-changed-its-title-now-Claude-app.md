---
id: TASK-54
title: >-
  Sending to a Claude app chat that is not open fails with "That chat changed
  its title (now Claude app)"
status: In Review
assignee: []
created_date: '2026-11-26T11:17:24Z'
labels:
  - hm-1397
dependencies: []
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1397

The owner, 26 Nov 12:17 (v1.1.0 / local build): "Hey Claude, what did Houseplant care said?" picked the sidebar chat "Houseplant care for beginners" and then failed: "That chat changed its title (now “Claude app”), so nothing was sent."
Cause: the check before sending looks the target up again by id; a sidebar chat shares its app's bundle id, so it finds the app and compares titles.

## History

### 2026-11-26 12:19 UTC (agent)

Status check (two independent checks): The fix is on main of usehomemade/needs-you in commit 14554c4. Router.verify() now only checks that the app is running for sidebar chats and no longer compares titles. No release has it yet: v1.1.0 is the build that showed the bug, and the Release run for 14554c4 was still in progress. Left to do: 1. Let the release publish a version above 1.1.0. 2. Install it. 3. Say "Hey Claude" to a Claude app sidebar chat that is not open, for example "Houseplant care for beginners", and confirm it sends without the title error. 4. Post that proof here, then move to Done.
<!-- SECTION:DESCRIPTION:END -->
