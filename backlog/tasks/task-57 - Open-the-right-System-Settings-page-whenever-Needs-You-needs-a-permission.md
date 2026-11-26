---
id: TASK-57
title: Open the right System Settings page whenever Needs You needs a permission
status: Done
assignee: []
created_date: '2026-11-26T12:25:25Z'
labels:
  - hm-1405
dependencies: []
ordinal: 57000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1405

The owner, 26 Nov 2026: after updating to 1.2.0, the app said Accessibility needs him but did not open the settings. "it should auto open this settings page for me. anytime it needs something, open the correct settings page for me"

Every missing permission (Accessibility, Microphone, Speech Recognition, Automation, Input Monitoring, Screen Recording if used, Notifications) opens its own System Settings page when the app needs it, once per need, not in a loop.

## History

### 2026-11-26 12:33 UTC (agent)

Built and installed locally (uncommitted). A missing permission opens its System Settings page, at most once per 10 minutes, and the island says which switch to turn on. Settings has a new Permissions pane: Accessibility, Microphone and Speech Recognition, each with a live check and an Open button. 110 tests pass. Open item: on macOS 27 the Accessibility link lands on "Device Control and Data Access"; the owner needs to confirm the switch is there. Local builds are still signed with Apple Development, so grants reset between local and released builds.

### 2026-11-26 12:36 UTC (agent)

Signing: local builds now sign with the Needs You Developer ID certificate (F5F5EF29…), the same one CI uses. It was imported from the team's secret store MACOS_CERT_P12. bundle.sh pins it and fails if it is missing; AGENTS.md has the rule. The installed local build's designated requirement now matches 1.2.0 (team OU 34LRG4TQRP), so grants carry across local and released builds. Removed at the owner's request: the old Developer ID identity whose key was labelled "another app" (7588372F…). Also removed, by mistake: the Apple Development identity (65E05212…). Uncommitted.

### 2026-11-26 14:00 UTC (agent)

Released in v1.3.0 (commit 1e0f80e, run 45833091952) and installed. In Review until checked in real use.

### 2026-11-26 18:18 UTC (agent)

Waiting on the owner: Turn off Accessibility for Needs You (v1.3.0 or later), send a voice message so it has to type, and check that System Settings opens once on a page with the Needs You switch. The auto-open code has shipped since v1.3.0 (commit 1e0f80e, also in v1.5.0), but nobody has confirmed it in real use, and the macOS 27 Accessibility link may land on the wrong page.
<!-- SECTION:DESCRIPTION:END -->
