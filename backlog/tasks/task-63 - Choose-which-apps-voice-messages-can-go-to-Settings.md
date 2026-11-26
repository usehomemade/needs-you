---
id: TASK-63
title: Choose which apps voice messages can go to (Settings)
status: Done
assignee: []
created_date: '2026-11-26T14:53:07Z'
updated_date: '2026-11-26T20:16:38Z'
labels:
  - hm-1415
dependencies: []
ordinal: 63000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1415

Owner, 26 Nov 2026 (by voice): Needs You tried to send messages to Slack. Users should be able to turn each detected chat app on or off (for example: only Ghostty, Terminal and herdr, or only Slack). Disabled apps are never offered or sent to.

## History

### 2026-11-26 15:06 UTC (agent)

Fixed in commit 66f5400 on main (not pushed yet). Installed as a local build. 164 tests pass.

### 2026-11-26 15:23 UTC (agent)

Released in v1.5.0 (run 45847016132) and installed.

### 2026-11-26 18:18 UTC (agent)

Done (two independent checks agreed): commit 66f5400 in the needs-you repo adds the Settings, Apps switch for herdr, terminals and chat apps. It is on origin/main and in the published release v1.5.0 (release run 45847016132 succeeded). Router.swift filters disabled apps out of the target lists and refuses sends to them with "turned off in Settings, Apps". ChatAppSwitchesTests covers the rule. Not tested live in the running app.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. 66f5400 in v1.5.0, installed v1.6.0. ChatAppSwitchesTests passes in the 204-test run.
<!-- SECTION:NOTES:END -->
