---
id: TASK-66
title: Which chat? An answer pointing at another chat got sent to the offered one
status: To Do
assignee: []
created_date: '2026-11-26T15:58:27Z'
updated_date: '2026-11-26T20:16:38Z'
labels:
  - hm-1425
dependencies: []
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Old id: HM-1425
Related: TASK-68 (HM-1428)

Owner, 26 Nov 2026, on 1.5.0: Needs You asked "needs-you?". He answered "No, the <project> chat in my home folder. It's called <project> general in herdr" (heard as "Now the <Project> Chat … <Project> General Inherder"). It decided send(needs-you) right away, the 2 s countdown was cancelled, and history shows Cancelled.

Causes:

1. ClarifyConversation.next accepts the model's pick when it equals the offered chat, even though the model said it was unclear and his words point elsewhere.
2. Chat descriptions don't include the herdr workspace name (for example "general" and the project name) or the tab label, so "<project> general" matched nothing (meaning 0.53 vs 0.51 vs 0.49).

## History

### 2026-11-26 16:14 UTC (agent)

Fixed in commit bc08335 on main (not pushed), installed locally, 179 tests pass. The model's unsure pick no longer sends; an unknown name gets "I can't find a chat called X"; herdr tab and workspace labels are in chat descriptions; the countdown logs why it cancels. Not verified live yet.

### 2026-11-26 18:19 UTC (agent)

Status check (two independent checks): The fix is on local main only (now 7b6bb68, ahead of origin/main by 3). It is not pushed or released, and not verified live. Left to do: push 7b6bb68 to origin/main and ship a release. Then answer "which chat?" with another chat's herdr name, such as "<project> general". It must go to that chat, and an unknown name must get "I can't find a chat called X". Then comment with the release version and proof, and move to Done. State set to Todo because nobody is working on it.

### 2026-11-26 18:41 UTC (agent)

Released in v1.6.0 (run 45876703935) and installed.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-26 status check: Moved to To Do: a dry run on v1.6.0 fails the "unknown name" case. `needs-you wake-test --transcript "Hey Mac, tell the banana chat that lunch is ready"` routed to a real chat whose title has the word "chat" (label match 0.50, no question asked). The same with "zebra chat" gave "no such chat". The common word "chat" in the spoken name still counts as a match. Fix next: ignore words that every chat name shares when matching a spoken name, then answer with "I can't find a chat called X". The rest of the fix (7b6bb68) is in v1.6.0.
<!-- SECTION:NOTES:END -->
