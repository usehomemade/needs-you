---
id: TASK-64
title: 'Thinking shimmer: the text gets cropped between shimmer loops'
status: Done
assignee: []
created_date: '2026-11-26T14:53:07Z'
updated_date: '2026-11-26T21:57:51Z'
labels:
  - hm-1416
dependencies: []
ordinal: 46.875
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1416

Owner, 26 Nov 2026 (by voice): the shimmer on "Thinking" in the pill is liked, but between loops the text gets cropped, then shimmers again. Remove the cropping.

## History

### 2026-11-26 15:06 UTC (agent)

Fixed in commit 49b024a on main (not pushed yet). Installed as a local build. 164 tests pass.

### 2026-11-26 15:23 UTC (agent)

Released in v1.5.0 (run 45847016132) and installed.

### 2026-11-26 18:18 UTC (agent)

Done (two independent checks agreed): commit 49b024a fixes the Thinking shimmer blanking part of the word between sweeps. It is on origin/main of the needs-you repo and shipped in release v1.5.0 (latest, published 2026-11-26). The text now uses a LinearGradient foregroundStyle with moving end points, so every letter is drawn in every frame. No test or screen recording covers it yet.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Back to In Review: no test or recording proves it, and the note above says so. Fix 49b024a is in v1.5.0 and the installed v1.6.0. Owner check: watch the pill while it says Thinking and confirm no letters blank out between sweeps.

2026-11-26: the owner reviewed it and moved it to Done.
<!-- SECTION:NOTES:END -->
