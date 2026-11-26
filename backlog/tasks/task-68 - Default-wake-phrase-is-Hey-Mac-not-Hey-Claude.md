---
id: TASK-68
title: Default wake phrase is "Hey Mac", not "Hey Claude"
status: Done
assignee: []
created_date: '2026-11-26T16:38:02Z'
updated_date: '2026-11-26T20:16:39Z'
labels:
  - hm-1428
dependencies: []
ordinal: 68000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1428
Related: TASK-66 (HM-1425)

Owner, 26 Nov 2026: the default wake phrase is "Hey Mac". No "Hey Claude" anywhere in the source code, docs, tests, agent instructions or the website.

## History

### 2026-11-26 16:56 UTC (agent)

Done in commit b4b1eb4 (local main, not pushed yet). Installed locally; 186 tests pass.

### 2026-11-26 18:19 UTC (agent)

Status check (two independent checks): The change is committed locally as 544c9b8 (rebased from b4b1eb4) but not pushed. origin/main still says "Hey Claude" in Info.plist, README.md and several Swift files. Left to do: push 544c9b8 and its parent 7b6bb68 (HM-1425) to origin/main, leave out the uncommitted Swift edits that belong to other work, let the release build run, then check that `git grep -i "hey claude" origin/main` is empty and the website says "Hey Mac".

### 2026-11-26 18:41 UTC (agent)

Released in v1.6.0 (run 45876703935) and installed.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Done. In v1.6.0 (544c9b8), installed. `needs-you status` says "Listening for Hey Mac". Dry run "Hey Claude, I'm back" returns "No Hey Mac in what I heard", and "Hey Mac, ..." commands route. `git grep -i "hey claude"` on origin/main outside backlog/ finds nothing. WakeMatcherTests passes.
<!-- SECTION:NOTES:END -->
