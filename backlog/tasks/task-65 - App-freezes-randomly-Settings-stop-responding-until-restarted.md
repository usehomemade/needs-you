---
id: TASK-65
title: App freezes randomly (Settings stop responding) until restarted
status: Done
assignee: []
created_date: '2026-11-26T14:57:10Z'
updated_date: '2026-11-26T20:16:38Z'
labels:
  - hm-1418
dependencies: []
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1418

Owner, 26 Nov 2026 (by voice): Needs You sometimes stops responding, and even Settings no longer respond, usually after it speaks a reply or sends something. Restarting fixes it. Possibly a memory or CPU leak. Running 1.4.0 after 4 minutes: main thread idle, 4% CPU, 1.7 GB resident. A diagnostic report from today (bug_type 309, a local 1.0 build) is at 13:37.

## History

### 2026-11-26 15:23 UTC (agent)

Released in v1.5.0 (run 45847016132) and installed. Checked before release: 4 sends into an idle throwaway herdr pane typed in (about 3.6 s each), and 3 sends into a pane flooding output returned "Not typed: not sure which Ghostty window" in about 3.7 s with the app responsive. No watchdog stall lines. Agent instructions now say a question must listen (ask), never --no-listen.

### 2026-11-26 18:20 UTC (agent)

Done (two independent checks agreed): The freeze fix b78cce7 (Accessibility reads off the main thread, 1 s timeout, Router output read while running, main-thread watchdog) and the instructions fix e6e134d are both in Needs You v1.5.0 on origin/main. The installed app has run about 4 hours since then with 0 "watchdog:" lines in audio.log across 2000+ log lines. RSS is 122 MB, far below the 1.7 GB reported. A separate SIGABRT crash at 18:04 (AppKit constraint update) is not this freeze and needs its own ticket.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Kept Done. audio.log still has no "watchdog:" stall lines through 20:10 UTC on v1.6.0. StallTests passes. The separate crash report from 26 Nov 18:04 is not this freeze.
<!-- SECTION:NOTES:END -->
